import 'dart:async';
import 'dart:convert';
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

  void _listen() {
    _port!.inputStream?.listen((Uint8List data) {
      // if (_buf.isNotEmpty) {
      //   logInfo("Buffer len: ${_buf.length}b, first byte: "
      //       "${_buf.first.toRadixString(16).padLeft(2, '0')}, last: ${_buf.last.toRadixString(16).padLeft(2, '0')}");
      // }
      // logInfo("Data len: ${data.length}b, first byte: "
      //    "${data.first.toRadixString(16).padLeft(2, '0')}, last: ${data.last.toRadixString(16).padLeft(2, '0')}");
      List<int> bufList = _buf.toList();
      bufList.addAll(data);
      _buf = Uint8List.fromList(bufList);
      //logRx("buf len: ${_buf.length}");
      logInfo("Raw buf: $_buf");
      List<Uint8List> messageQueue = [];
      while (_buf.contains(0x0A)) {
        int index = _buf.indexOf(0x0A);
        logInfo("Found line feed at index: $index");
        Uint8List msg = _buf.sublist(0, index);
        if (index < _buf.length-1) {
          _buf = _buf.sublist(index+1, _buf.length);
        } else {
          _buf = Uint8List(0);
        }
        messageQueue.add(msg);
      }
      logInfo("MQ: $messageQueue");
      if (messageQueue.isEmpty) return;

      for (Uint8List msg in messageQueue) {
        if (msg.first == 0x5B) {
          try {
            logRx(utf8.decode(msg));
          } on Exception catch(e) {
            logError("Couldn't decode log as UTF8: $e");logInfo("Raw: ${msg.toString()}");
          }
        } else {
          try {
            final rx = Message.parse(msg, endian: Endian.big);
            logRx("Received ${rx.ack ? "ACK for" : ""} $rx");
            if (rx.command.byte == Command.telemetry.byte) {
              _pointCtl.add(PointWithAuthor(rx.node, rx.points.first));
            }
          } on Exception catch (e) {
            logError(e.toString());
            logRx("Raw: ${msg.toString()}");
            logInfo("utf8 representation: ${utf8.decode(msg)}");
          }
        }
      }
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
