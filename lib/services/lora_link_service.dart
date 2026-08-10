import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:usb_serial/usb_serial.dart';

import '../models/mission_message.dart';
import 'global_log.dart';
import 'lora_frame.dart';
import 'mission_transport.dart';

const _tag = 'link';

class LoraLinkService implements MissionTransport {
  LoraLinkService({
    this.pollInterval = const Duration(milliseconds: 200),
    this.transactionTimeout = const Duration(milliseconds: 250),
    this.maxAttempts = 4,
  });

  final Duration pollInterval;
  final Duration transactionTimeout;
  final int maxAttempts;

  @override
  TransportKind get kind => TransportKind.lora;

  UsbPort? _port;
  UsbDevice? _device;
  StreamSubscription<Uint8List>? _rxSub;
  StreamSubscription<UsbEvent>? _usbSub;
  Timer? _pollTimer;
  bool _closing = false;
  int _txCounter = 0;

  /// Consecutive failed reads/writes. Unplugging the board does not reliably
  /// close `inputStream`, so every I/O just keeps failing: without this the
  /// link stays "connected" for ever, polling a port that is gone and writing a
  /// log line for each attempt.
  int _ioFailures = 0;

  /// Failures in a row that mean the board is gone rather than busy. Poll
  /// interval is 200 ms, so this is under a second of retrying.
  static const int _ioFailureLimit = 4;

  final _parser = LoraFrameParser();
  final _queue = <_Transaction>[];
  _Transaction? _current;

  final _stateCtl = StreamController<LinkState>.broadcast();
  final _statusCtl = StreamController<String>.broadcast();
  final _missionCtl = StreamController<IncomingMission>.broadcast();

  @override
  Stream<LinkState> get stateStream => _stateCtl.stream;
  @override
  Stream<String> get statusStream => _statusCtl.stream;
  @override
  Stream<IncomingMission> get missionStream => _missionCtl.stream;

  LinkState _state = LinkState.disconnected;
  @override
  LinkState get state => _state;
  @override
  bool get isConnected => _state == LinkState.connected;

  int? groundNodeId;

  void _setState(LinkState s, String message) {
    _state = s;
    logTrace(_tag, 'state=${s.name} "$message"');
    if (!_stateCtl.isClosed) _stateCtl.add(s);
    if (!_statusCtl.isClosed) _statusCtl.add(message);
  }

  Future<List<UsbDevice>> listDevices() async {
    final devices = await UsbSerial.listDevices();
    logTrace(_tag, 'listDevices -> ${devices.length}: '
        '${devices.map((d) => d.deviceName).join(", ")}');
    return devices;
  }

  Future<bool> connect(UsbDevice device, {int baud = 115200}) async {
    await disconnect();
    _closing = false;
    _device = device;
    _setState(LinkState.connecting, 'Connecting to ${device.deviceName}…');
    logTrace(_tag, 'connect vid=${device.vid} pid=${device.pid} '
        'name=${device.deviceName} baud=$baud');

    try {
      final port = await device.create();
      if (port == null) {
        _setState(LinkState.disconnected, 'Failed to create port');
        return false;
      }
      if (!await port.open()) {
        _setState(LinkState.disconnected, 'Failed to open port');
        return false;
      }

      await port.setDTR(true);
      await port.setRTS(true);
      await port.setPortParameters(
        baud,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );
      logTrace(_tag, 'port open 8N1 dtr=1 rts=1');

      _port = port;
      _parser.reset();
      _rxSub = port.inputStream?.listen(
        _onBytes,
        onError: (Object e) {
          logError('Serial error: $e', _tag);
          _setState(LinkState.disconnected, 'Serial error');
        },
        onDone: () {
          if (!_closing) _setState(LinkState.disconnected, 'Serial stream closed');
        },
      );

      _usbSub = UsbSerial.usbEventStream?.listen((event) {
        if (event.event != UsbEvent.ACTION_USB_DETACHED) return;
        final gone = event.device;
        if (gone != null && gone.deviceId != _device?.deviceId) return;
        logWarn('USB device detached', _tag);
        unawaited(disconnect());
      });

      _ioFailures = 0;
      _setState(LinkState.connected,
          'Connected: ${device.productName ?? device.deviceName} @ $baud bps');
      logInfo('Connected to ${device.productName ?? device.deviceName}', _tag);

      unawaited(_readConfig());
      _schedulePoll(Duration.zero);
      return true;
    } catch (e) {
      logError('Connect failed: $e', _tag);
      _setState(LinkState.disconnected, 'Failed to connect: $e');
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    _pollTimer?.cancel();
    _pollTimer = null;

    final pending = [?_current, ..._queue];
    if (pending.isNotEmpty) {
      logTrace(_tag, 'cancelling ${pending.length} pending transaction(s)');
    }
    for (final tx in pending) {
      tx.cancel(const _LinkClosedException());
    }
    _queue.clear();
    _current = null;

    await _rxSub?.cancel();
    _rxSub = null;
    await _usbSub?.cancel();
    _usbSub = null;
    try {
      await _port?.close();
    } catch (_) {}
    _port = null;
    groundNodeId = null;

    if (_device != null) logInfo('Disconnected ${_device!.deviceName}', _tag);
    _device = null;
    _setState(LinkState.disconnected, 'Disconnected');
  }

  @override
  Future<bool> sendMission(int dest, MissionMessage message) async {
    if (!isConnected) {
      logWarn('Send failed: not connected', _tag);
      return false;
    }
    final LoraFrame frame;
    try {
      frame = LoraFrame.sendmsg(dest, message.encodeBytes());
    } on Exception catch (e) {
      logError('Could not encode ${message.type}: $e', _tag);
      return false;
    }

    logSnt('→ ${describeDest(dest)}  ${message.encode()}', _tag);
    try {
      final reply = await _enqueue(frame);
      final ok = reply != null && reply.type == LoraFrameType.ack;
      logTrace(_tag, 'sendMission ${message.type} q=${message.seq} '
          'dest=$dest accepted=$ok');
      return ok;
    } on Exception catch (e) {
      logError('Send of ${message.type} failed: $e', _tag);
      return false;
    }
  }

  Future<void> _readConfig() async {
    try {
      final reply = await _enqueue(LoraFrame.request(LoraFrameType.getconf));
      if (reply == null || reply.type != LoraFrameType.getconf) return;
      _writeRaw(LoraFrame.request(LoraFrameType.ack));

      final text = utf8.decode(reply.payload, allowMalformed: true);
      logInfo('Ground ESP config: ${sanitizeForLog(text)}', _tag);
      for (final pair in text.split(RegExp(r'\s+'))) {
        final kv = pair.split('=');
        if (kv.length == 2 && kv[0] == 'CMDB_ID') {
          groundNodeId = int.tryParse(kv[1]);
        }
      }
    } on Exception catch (e) {
      logWarn('Could not read ground ESP config: $e', _tag);
    }
  }

  void _schedulePoll(Duration delay) {
    _pollTimer?.cancel();
    if (!isConnected) return;
    _pollTimer = Timer(delay, _poll);
  }

  Future<void> _poll() async {
    if (!isConnected) return;
    try {
      final reply = await _enqueue(LoraFrame.request(LoraFrameType.getmsg));
      if (reply == null) {
        logTrace(_tag, 'poll timed out');
        _schedulePoll(pollInterval);
        return;
      }

      if (reply.type == LoraFrameType.getmsg) {
        _writeRaw(LoraFrame.request(LoraFrameType.ack)); // board resends until ACKed
        _handlePayload(reply.id, reply.payload);
        _schedulePoll(Duration.zero);
      } else {
        _schedulePoll(pollInterval);
      }
    } on _LinkClosedException {
      logTrace(_tag, 'poll aborted: link closed');
    } on Exception catch (e) {
      if (_noteIoFailure('Poll failed: $e')) _schedulePoll(pollInterval);
    }
  }

  /// Record one failed transfer. Returns false once the board is presumed gone,
  /// at which point the caller must stop retrying.
  ///
  /// Only the first failure of a run is logged. A detached board fails every
  /// 200 ms poll, and a log line per attempt buries whatever came before it.
  bool _noteIoFailure(String what) {
    _ioFailures++;
    if (_ioFailures == 1) logError(what, _tag);
    if (_ioFailures < _ioFailureLimit) return true;

    logError('$_ioFailures transfers failed in a row - treating the board as '
        'disconnected', _tag);
    unawaited(disconnect());
    return false;
  }

  @visibleForTesting
  bool noteIoFailureForTest(String what) => _noteIoFailure(what);

  @visibleForTesting
  int get ioFailuresForTest => _ioFailures;

  void _handlePayload(int from, Uint8List payload) {
    final text = utf8.decode(payload, allowMalformed: true);
    try {
      final message = MissionMessage.decode(text);
      logRx('← ${describeDest(from)}  $text', _tag);
      if (!_missionCtl.isClosed) _missionCtl.add(IncomingMission(from, message));
    } on UnsupportedMessageTypeException catch (e) {
      logWarn('Unsupported message from node $from: ${e.messageType}', _tag);
    } on MissionMessageException catch (e) {
      logError('Bad payload from node $from: ${e.message}', _tag);
      logTrace(_tag, 'raw payload: ${sanitizeForLog(text, maxLength: 0)}');
    }
  }

  Future<LoraFrame?> _enqueue(LoraFrame request) {
    final tx = _Transaction(request, ++_txCounter);
    _queue.add(tx);
    _pump();
    return tx.completer.future;
  }

  void _pump() {
    if (_current != null || _queue.isEmpty || _port == null) return;
    _current = _queue.removeAt(0);
    _attempt();
  }

  void _attempt() {
    final tx = _current;
    if (tx == null) return;

    tx.attempts++;
    if (tx.attempts > 1) {
      logTrace(_tag, 'tx#${tx.id} ${tx.request.type.name} attempt '
          '${tx.attempts}/$maxAttempts');
    }
    _writeRaw(tx.request);
    tx.timer = Timer(transactionTimeout, () {
      if (!identical(_current, tx)) return;
      if (tx.attempts >= maxAttempts) {
        logWarn('No reply to ${tx.request.type.name} after ${tx.attempts} attempts',
            _tag);
        _finish(null);
      } else {
        logTrace(_tag, 'tx#${tx.id} timeout, retrying');
        _attempt();
      }
    });
  }

  void _finish(LoraFrame? reply) {
    final tx = _current;
    if (tx == null) return;
    _current = null;
    tx.complete(reply);
    _pump();
  }

  void _writeRaw(LoraFrame frame) {
    final port = _port;
    if (port == null) return;
    final bytes = frame.encode();
    unawaited(() async {
      try {
        await port.write(bytes);
      } catch (e) {
        _noteIoFailure('Write failed: $e');
      }
    }());
  }

  void _onBytes(Uint8List data) {
    _ioFailures = 0;        // bytes arriving is the board answering for itself
    final result = _parser.feed(data);

    if (result.noise.isNotEmpty) {
      final text = utf8.decode(result.noise, allowMalformed: true).trim();
      if (printableRatio(result.noise) >= 0.9 && text.isNotEmpty) {
        logInfo('ESP: ${sanitizeForLog(text, maxLength: 0)}', _tag);
      } else {
        logTrace(_tag, 'unframed ${result.noise.length}B: ${_hex(result.noise)}');
      }
    }

    for (final frame in result.frames) {
      if (!_isIdlePollReply(frame)) logTrace(_tag, 'RX $frame');
      final tx = _current;
      if (tx != null && tx.accepts(frame)) {
        tx.timer?.cancel();
        _finish(frame);
      } else {
        logWarn('Unsolicited frame: $frame', _tag);
      }
    }
  }

  /// A GETMSG answered by a bare ACK on the first try means "radio queue empty".
  /// That is the steady state while idle, so it is not worth a log line.
  bool _isIdlePollReply(LoraFrame frame) =>
      frame.type == LoraFrameType.ack &&
      _current?.request.type == LoraFrameType.getmsg &&
      (_current?.attempts ?? 0) <= 1;

  static String _hex(Uint8List b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  @override
  String describeDest(int id) =>
      id == kBroadcastAddress ? 'all drones' : 'node $id';

  @override
  Future<void> dispose() async {
    await disconnect();
    await _stateCtl.close();
    await _statusCtl.close();
    await _missionCtl.close();
  }
}

class _LinkClosedException implements Exception {
  const _LinkClosedException();
  @override
  String toString() => 'Link closed';
}

class _Transaction {
  _Transaction(this.request, this.id);

  final LoraFrame request;
  final int id;
  final Completer<LoraFrame?> completer = Completer<LoraFrame?>();
  int attempts = 0;
  Timer? timer;

  bool accepts(LoraFrame reply) => switch (request.type) {
        LoraFrameType.getmsg =>
          reply.type == LoraFrameType.getmsg || reply.type == LoraFrameType.ack,
        LoraFrameType.getconf =>
          reply.type == LoraFrameType.getconf || reply.type == LoraFrameType.ack,
        LoraFrameType.sendmsg => reply.type == LoraFrameType.ack,
        LoraFrameType.ack => false,
      };

  void complete(LoraFrame? reply) {
    timer?.cancel();
    if (!completer.isCompleted) completer.complete(reply);
  }

  void cancel(Object error) {
    timer?.cancel();
    if (!completer.isCompleted) completer.completeError(error);
  }
}
