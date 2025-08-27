import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_esp_android_communication/models/message.dart';
import 'package:latlong2/latlong.dart';
import 'package:usb_serial/usb_serial.dart';

import 'global_log.dart';

class PointWithAuthor {
  late int author; //from NodeId
  late LatLng point;

  PointWithAuthor(this.author, this.point);
}

class SerialService {
  UsbPort? _port;
  UsbDevice? _device;

  final _statusCtl = StreamController<String>.broadcast();
  final _rawCtl = StreamController<String>.broadcast();
  final _logsCtl = StreamController<String>.broadcast();
  final _pointCtl = StreamController<PointWithAuthor>.broadcast();
  final _msgCtl = StreamController<Message>.broadcast();

  late Uint8List _buf = Uint8List(0);

  Stream<String> get statusStream => _statusCtl.stream;
  Stream<String> get rawStream => _rawCtl.stream;
  Stream<PointWithAuthor> get pointStream => _pointCtl.stream;
  Stream<String> get logStream => _logsCtl.stream;
  Stream<Message> get messageStream => _msgCtl.stream;

  void _status(String s) => _statusCtl.add(s);

  Future<List<UsbDevice>> listDevices() async => UsbSerial.listDevices();

  Future<void> connect(UsbDevice device, {int baud = 115200}) async {
    logWarn("Connecting to: ${device.deviceName}");
    await disconnect();
    _device = device;
    try {
      _port = await device.create();
      if (_port == null) {
        _status('Failed to create port');
        return;
      }
      final ok = await _port!.open();
      if (!ok) {
        _status('Failed to open port');
        return;
      }

      await _port!.setDTR(true);
      await _port!.setRTS(true);
      await _port!.setPortParameters(
        baud,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      _status('Connected: ${_device?.deviceName ?? 'Unknown'} @ $baud bps');
      logInfo('Connected to ${_device?.productName ?? _device?.deviceName ?? 'device'}');

      _listen();
    } catch (e) {
      _status('Failed to connect: $e');
      logError('Error: $e');
    }
  }

  (List<Uint8List>, Uint8List) _trySplit(Uint8List data) {
    List<Uint8List> messageQueue = [];
    Uint8List currentMessage = data.sublist(0);
    while (currentMessage.contains(0x0A)) {
      int index = currentMessage.indexOf(0x0A);
      Uint8List msg = currentMessage.sublist(0, index);
      if (index < currentMessage.length-1) {
        currentMessage = currentMessage.sublist(index+1, currentMessage.length);
      } else {
        currentMessage = Uint8List(0);
      }
      messageQueue.add(msg);
    }
    return (messageQueue, currentMessage);
  }


  // try {
  //   rx = Message.parse(data, endian: Endian.big);
  //   logRx("Received ${rx.ack ? "ACK for" : ""} $rx");
  //   if (rx.command.byte == Command.telemetry.byte) {
  //     _pointCtl.add(PointWithAuthor(rx.node, rx.points.first));
  //   }
  // } on Exception catch (e) {
  //   logError(e.toString());
  //   logRx("Raw: ${msg.toString()}");
  //   logInfo("utf8 representation: ${utf8.decode(msg)}");
  // }

  (Exception? e, Message? rx) tryParse (Uint8List data) {
    Message rx;
    try {
      rx = Message.parse(data, endian: Endian.big);
      return (null, rx);
    } on Exception catch (e) {
      return (e, null);
    }
  }

  void _listen() {
    _port!.inputStream?.listen((Uint8List data) {
      List<int> bufList = _buf.toList();
      bufList.addAll(data);
      _buf = Uint8List.fromList(bufList);
      logInfo("Raw buf: $_buf");

      var messageQueueAndLeftover = _trySplit(_buf);
      List<Uint8List> messageQueue = messageQueueAndLeftover.$1;
      _buf = messageQueueAndLeftover.$2;
      logInfo("MQ: $messageQueue");
      if (messageQueue.isEmpty) return;


      // TODO: the following code is shit. Please rewrite.
      Uint8List msg = messageQueue[0].sublist(0);
      if (msg.first == 0x5B) {
        try {
          logRx(utf8.decode(msg));
        } on Exception catch(e) {
          logError("Couldn't decode log as UTF8: $e");logInfo("Raw: ${msg.toString()}");
        }
        messageQueue.removeAt(0);
        if (messageQueue.isEmpty) return;
        msg = messageQueue[0].sublist(0);
      }
      var errMsg = tryParse(msg);
      if (!Message.isValidMessageHeader(msg)) {
        logError("${errMsg.$1}");
        logInfo("Raw: $msg");
        messageQueue.removeAt(0);
        if (messageQueue.isEmpty) return;
        msg = messageQueue[0].sublist(0);
      }
      while (true) { //holy fucking shit
        errMsg = tryParse(msg);
        if (errMsg.$2 != null) {
          final rx = errMsg.$2!;
          logRx("Received ${rx.ack ? "ACK for" : ""} $rx");
          if (rx.command.byte == Command.telemetry.byte) {
            _pointCtl.add(PointWithAuthor(rx.node, rx.points.first));
          }
          messageQueue.removeAt(0);
          if (messageQueue.isEmpty) return;
          msg = messageQueue[0].sublist(0);
        } else if (messageQueue.length > 1) {
          messageQueue.removeAt(0);
          msg = Uint8List.fromList([...msg, ...messageQueue[0]]);
        } else {
          _buf = Uint8List.fromList([...msg, ..._buf]);
          return;
        }
      }
      // end of shit code
    }, onError: (e) {
      logError('Serial error: $e');
      _status('Serial error');
    }, onDone: () {
      logInfo('Serial stream closed');
      _status('Disconnected');
    });
  }

  Future<void> send(Uint8List bytes) async {
    if (_port == null) {
      logWarn('Send failed: not connected');
      return;
    }
    final tx = Message.parse(bytes);
    _msgCtl.add(tx);
    logSnt(tx.hex);
    await _port!.write(Uint8List.fromList([...bytes, 0x0A]));
  }

  Future<void> disconnect() async {
    try {
      await _port?.close();
      logInfo("Disconnected ${_device?.deviceName}");
    } catch (_) {}
    _port = null;
    _device = null;
    _status('Disconnected');
  }
}
