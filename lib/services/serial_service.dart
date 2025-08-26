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
      if (data.isEmpty) return;
      if (data.length > 10) {
        logRx(utf8.decode(data));
        return;
      } else {
        logRx(data.toString());
        try {
          final rx = Message.parse(data);
          logRx("${rx.ack ? "ACK for" : ""}(${nodeIdToName[rx.node]}) $rx");
          if (rx.command.byte == Command.telemetry.byte) {
            _pointCtl.add(PointWithAuthor(rx.node, rx.points.first));
          }
        } on Exception catch (e) {
          logError(e.toString());
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
    await _port!.write(bytes);
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
