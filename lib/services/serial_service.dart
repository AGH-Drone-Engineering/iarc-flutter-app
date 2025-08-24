import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:usb_serial/usb_serial.dart';

import '../state/app_state.dart';
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

  AppState? app;

  void attachApp(AppState state) {
    app = state;
  }

  void _log(LogLevels level, String msg) {
    if (app != null) {
      addLog(level, msg);
    }
  }

  void _status(String s) => _statusCtl.add(s);

  Future<List<UsbDevice>> listDevices() async => UsbSerial.listDevices();

  Future<void> connect(UsbDevice device, {int baud = 115200}) async {
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
      _log(LogLevels.info, 'Connected to ${_device?.productName ?? _device?.deviceName ?? 'device'}');

      _listen();
    } catch (e) {
      _status('Failed to connect: $e');
      _log(LogLevels.error, 'Error: $e');
    }
  }

  void _listen() {
    String buffer = '';
    _port!.inputStream?.listen((Uint8List data) {
      final chunk = utf8.decode(data, allowMalformed: true);
      buffer += chunk;
      // Split by newline. Keep remainder in buffer.
      final parts = buffer.split(RegExp(r'\r?\n'));
      buffer = parts.removeLast();
      for (final line in parts) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        _rawCtl.add(trimmed);
        _parseMaybePoint(trimmed);
      }
    }, onError: (e) {
      _log(LogLevels.error, 'Serial error: $e');
      _status('Serial error');
    }, onDone: () {
      _log(LogLevels.info, 'Serial stream closed');
      _status('Disconnected');
    });
  }

  void _parseMaybePoint(String line) {
    try {
      if (line.startsWith('{')) {
        final m = jsonDecode(line);
        final latVal = m['lat'] ?? m['latitude'];
        final lonVal = m['lon'] ?? m['lng'] ?? m['longitude'];
        final lat = latVal is num ? latVal.toDouble() : double.tryParse('$latVal');
        final lon = lonVal is num ? lonVal.toDouble() : double.tryParse('$lonVal');
        if (lat != null && lon != null) {
          _pointCtl.add(LatLng(lat, lon));
          return;
        }
      }
    } catch (_) {
      // fall through to CSV try
    }

    final csv = line.split(',');
    if (csv.length >= 2) {
      final lat = double.tryParse(csv[0].trim());
      final lon = double.tryParse(csv[1].trim());
      if (lat != null && lon != null) {
        _pointCtl.add(LatLng(lat, lon));
      }
    }
  }

  Future<void> sendText(String s) async {
    if (_port == null) {
      _log(LogLevels.warn, 'Send failed: not connected');
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode(s));
    await _port!.write(bytes);
    _log(LogLevels.received, '> $s');
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
