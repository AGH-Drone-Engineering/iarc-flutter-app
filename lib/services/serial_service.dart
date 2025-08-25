import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:usb_serial/usb_serial.dart';

import 'global_log.dart';

class SerialService {
  UsbPort? _port;
  UsbDevice? _device;

  final _statusCtl = StreamController<String>.broadcast();
  final _rawCtl = StreamController<String>.broadcast();
  final _logsCtl = StreamController<String>.broadcast();
  final _pointCtl = StreamController<LatLng>.broadcast();

  Stream<String> get statusStream => _statusCtl.stream;
  Stream<String> get rawStream => _rawCtl.stream;
  Stream<LatLng> get pointStream => _pointCtl.stream;
  Stream<String> get logStream => _logsCtl.stream;

  void _status(String s) => _statusCtl.add(s);

  Future<List<UsbDevice>> listDevices() async => UsbSerial.listDevices();

  Future<void> connect(UsbDevice device, {int baud = 9600}) async {
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
    String buffer = '';
    _port!.inputStream?.listen((Uint8List data) {
      final chunk = utf8.decode(data, allowMalformed: true);
      buffer += chunk;
      if (buffer.isEmpty) return;
      final parts = buffer.split(RegExp(r'\r?\n'));
      buffer = parts.removeLast();
      for (final line in parts) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        logRx(trimmed);
      }
    }, onError: (e) {
      logError('Serial error: $e');
      _status('Serial error');
    }, onDone: () {
      logInfo('Serial stream closed');
      _status('Disconnected');
    });
  }

  Future<void> sendText(String s) async {
    if (_port == null) {
      logWarn('Send failed: not connected');
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode(s));
    await _port!.write(bytes);
    logSnt('> $s');
  }

  Future<void> disconnect() async {
    try {
      await _port?.close();
    } catch (_) {}
    _port = null;
    _device = null;
    _status('Disconnected');
  }
}
