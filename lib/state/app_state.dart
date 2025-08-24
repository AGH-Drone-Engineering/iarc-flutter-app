import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/global_log.dart';
import '../services/serial_service.dart';

class AppState extends ChangeNotifier {
  final SerialService serial = SerialService();

  static const _kCornersKey = 'corners_v1';

  SharedPreferences? _prefs;
  Future<SharedPreferences> _ensurePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  // Four corners (nullable until provided)
  final List<LatLng?> corners = List<LatLng?>.filled(4, null, growable: false);

  // ESP points received from serial
  final List<LatLng> espPoints = [LatLng(34.6991111, -86.61030555555556)];

  String connectionStatus = 'No device connected';

  // Last raw line
  String lastRaw = '';

  // Optional telemetry
  LatLng? userLocation;
  double? headingDegrees;

  void init() {
    serial.statusStream.listen((s) {
      connectionStatus = s;
      notifyListeners();
    });
    serial.rawStream.listen((line) {
      lastRaw = line;
      notifyListeners();
    });
    serial.pointStream.listen((p) {
      espPoints.add(p);
      notifyListeners();
    });
  }

  Future<void> _loadCorners() async {
    final prefs = await _ensurePrefs();
    final s = prefs.getString(_kCornersKey);
    if (s == null || s.isEmpty) return;
    try {
      final data = jsonDecode(s);
      if (data is List && data.length == 4) {
        for (var i = 0; i < 4; i++) {
          final e = data[i];
          if (e is List && e.length >= 2) {
            final lat = (e[0] as num).toDouble();
            final lon = (e[1] as num).toDouble();
            corners[i] = LatLng(lat, lon);
          } else {
            corners[i] = null;
          }
        }
        notifyListeners();
      }
    } catch (_) {
      // ignore malformed data
    }
  }

  Future<void> _saveCorners() async {
    final prefs = await _ensurePrefs();
    final list = corners
        .map((c) => c == null ? null : [c.latitude, c.longitude])
        .toList();
    await prefs.setString(_kCornersKey, jsonEncode(list));
  }

  void setCorner(int index, LatLng? value) {
    if (index < 0 || index > 3) return;
    corners[index] = value;
    notifyListeners();
  }

  void clearCorners() {
    for (var i = 0; i < 4; i++) {
      corners[i] = null;
    }
    notifyListeners();
  }

  List<LatLng> get filledCorners => corners.whereType<LatLng>().toList();

  bool get hasFourCorners => corners.every((c) => c != null);

  Future<void> sendCornersToEsp() async {
    final poly = corners
        .map((c) => c == null ? null : [c.latitude, c.longitude])
        .toList();
    final payload = jsonEncode({
      'type': 'polygon',
      'points': poly,
    });
    await serial.sendText('$payload\n');
  }
}
