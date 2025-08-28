// lib/state/app_state.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_esp_android_communication/models/Drone.dart';
import 'package:flutter_esp_android_communication/services/global_log.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import '../services/serial_service.dart';

class AppState extends ChangeNotifier {
  final SerialService serial = SerialService();

  static const _kCornersKey = 'corners_v1';
  static const _kSinglePointKey = 'single_point_v1';
  static const _kRotateWithCompassKey = 'rotate_with_compass_v1'; // NEW

  SharedPreferences? _prefs;
  Future<SharedPreferences> _ensurePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  final List<LatLng?> corners = List<LatLng?>.filled(4, null, growable: false);

  LatLng? singlePoint;

  Map<int, Drone> droneMap = Drone.registeredDronesMap;

  bool rotateWithCompass = true;

  String connectionStatus = 'No device connected';
  String lastRaw = '';
  LatLng? userLocation;
  double? headingDegrees;
  Message? lastSent;
  Message? lastReceived;

  Future<void> init() async {
    serial.statusStream.listen((s) {
      connectionStatus = s;
      notifyListeners();
    });
    serial.rawStream.listen((line) {
      lastRaw = line;
      notifyListeners();
    });
    serial.pointStream.listen((p) {
      try {
        droneMap[p.author]?.points.add(p.point);
        droneMap[p.author]?.lastSeen = DateTime.now();
      } catch (_) {
        logError("Unknown drone id: ${p.author}");
      }
      notifyListeners();
    });
    serial.messageStream.listen((msg) {
      lastSent = msg;
      notifyListeners();
    });

    await Future.wait([_loadCorners(), _loadSinglePoint(), _loadRotateWithCompass()]);
  }


  Future<void> _loadRotateWithCompass() async {
    final p = await _ensurePrefs();
    rotateWithCompass = p.getBool(_kRotateWithCompassKey) ?? true;
    notifyListeners();
  }

  Future<void> _saveRotateWithCompass() async {
    final p = await _ensurePrefs();
    await p.setBool(_kRotateWithCompassKey, rotateWithCompass);
  }

  void setRotateWithCompass(bool v) {
    rotateWithCompass = v;
    _saveRotateWithCompass();
    notifyListeners();
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
            corners[i] = LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble());
          } else {
            corners[i] = null;
          }
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _saveCorners() async {
    final prefs = await _ensurePrefs();
    final list =
    corners.map((c) => c == null ? null : [c.latitude, c.longitude]).toList();
    await prefs.setString(_kCornersKey, jsonEncode(list));
  }

  Future<void> _loadSinglePoint() async {
    final prefs = await _ensurePrefs();
    final s = prefs.getString(_kSinglePointKey);
    if (s == null || s.isEmpty) return;
    try {
      final data = jsonDecode(s);
      if (data is List && data.length >= 2) {
        singlePoint = LatLng((data[0] as num).toDouble(), (data[1] as num).toDouble());
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _saveSinglePoint() async {
    final prefs = await _ensurePrefs();
    if (singlePoint == null) {
      await prefs.remove(_kSinglePointKey);
    } else {
      await prefs.setString(
        _kSinglePointKey,
        jsonEncode([singlePoint!.latitude, singlePoint!.longitude]),
      );
    }
  }

  // ---------- Mutators ----------
  void setCorner(int index, LatLng? value) {
    if (index < 0 || index > 3) return;
    corners[index] = value;
    _saveCorners();
    notifyListeners();
  }

  void clearCorners() {
    for (var i = 0; i < 4; i++) {
      corners[i] = null;
    }
    _saveCorners();
    notifyListeners();
  }

  void setSinglePoint(LatLng? value) {
    singlePoint = value;
    _saveSinglePoint();
    notifyListeners();
  }

  void clearSinglePoint() {
    singlePoint = null;
    _saveSinglePoint();
    notifyListeners();
  }

  List<LatLng> get filledCorners => corners.whereType<LatLng>().toList();
  bool get hasFourCorners => corners.every((c) => c != null);

  List<LatLng> get orderedCorners {
    final pts = filledCorners;
    if (pts.length != 4) return pts;

    final perms = <List<int>>[];
    void gen(List<int> curr, List<int> rem) {
      if (rem.isEmpty) {
        perms.add(List<int>.from(curr));
        return;
      }
      for (var i = 0; i < rem.length; i++) {
        final next = List<int>.from(rem)..removeAt(i);
        gen(List<int>.from(curr)..add(rem[i]), next);
      }
    }
    gen([], [0, 1, 2, 3]);

    double polygonArea(List<LatLng> p) {
      double a = 0.0;
      for (int i = 0; i < p.length; i++) {
        final j = (i + 1) % p.length;
        a += p[i].longitude * p[j].latitude - p[j].longitude * p[i].latitude;
      }
      return a / 2.0;
    }

    bool onSeg(LatLng a, LatLng b, LatLng c) {
      return (c.longitude <= (a.longitude > b.longitude ? a.longitude : b.longitude) &&
          c.longitude >= (a.longitude < b.longitude ? a.longitude : b.longitude) &&
          c.latitude  <= (a.latitude  > b.latitude  ? a.latitude  : b.latitude)  &&
          c.latitude  >= (a.latitude  < b.latitude  ? a.latitude  : b.latitude)) &&
          ( (b.longitude - a.longitude) * (c.latitude - a.latitude) -
              (b.latitude  - a.latitude)  * (c.longitude - a.longitude) ).abs() < 1e-12;
    }

    int orient(LatLng a, LatLng b, LatLng c) {
      final val = (b.latitude - a.latitude) * (c.longitude - b.longitude) -
          (b.longitude - a.longitude) * (c.latitude - b.latitude);
      if (val.abs() < 1e-12) return 0;
      return val > 0 ? 1 : 2; // 1: clockwise, 2: counterclockwise
    }

    bool segIntersect(LatLng p1, LatLng q1, LatLng p2, LatLng q2) {
      final o1 = orient(p1, q1, p2);
      final o2 = orient(p1, q1, q2);
      final o3 = orient(p2, q2, p1);
      final o4 = orient(p2, q2, q1);

      if (o1 != o2 && o3 != o4) return true; // general case

      // collinear special cases
      if (o1 == 0 && onSeg(p1, q1, p2)) return true;
      if (o2 == 0 && onSeg(p1, q1, q2)) return true;
      if (o3 == 0 && onSeg(p2, q2, p1)) return true;
      if (o4 == 0 && onSeg(p2, q2, q1)) return true;

      return false;
    }

    bool simpleQuad(List<LatLng> p) {
      // For 4 vertices, only non-adjacent pairs can cross:
      // edges (0-1) with (2-3) and (1-2) with (3-0)
      final a = p[0], b = p[1], c = p[2], d = p[3];
      if (segIntersect(a, b, c, d)) return false;
      if (segIntersect(b, c, d, a)) return false;
      return true;
    }

    List<LatLng>? best;
    double bestAbsArea = -1;

    for (final idx in perms) {
      var poly = [pts[idx[0]], pts[idx[1]], pts[idx[2]], pts[idx[3]]];
      if (simpleQuad(poly)) {
        var area = polygonArea(poly);
        // Normalize orientation to CCW (positive area)
        if (area < 0) {
          poly = poly.reversed.toList();
          area = -area;
        }
        if (area > bestAbsArea) {
          best = poly;
          bestAbsArea = area;
        }
      }
    }

    return best ?? pts;
  }

  Future<void> sendCornersToEsp() async {
    final pts = orderedCorners;
    if (pts.length != 4) return;
    final tx = MessageBuilder.crdSnd(dest: Drone.broadcast, corners: pts);
    await serial.send(tx);
  }
}
