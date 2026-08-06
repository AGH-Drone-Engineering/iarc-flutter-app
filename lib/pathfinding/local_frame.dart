/// Projekcja GPS -> lokalne XY i pomocnicza geometria wielokąta.
///
/// Port `minefield_path/geometry.py`. Projekcja to lokalna płaska aproksymacja
/// wokół środka obszaru -- bez UTM-a. Dla pola wielkości kilkuset metrów błąd
/// jest rzędu centymetrów.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const double _metersPerDegLat = 110540.0;
const double _metersPerDegLon = 111320.0;

/// Punkt oddalony o `meters` od `from` wzdłuż azymutu `bearingDegrees`
/// (0 = północ, rośnie na wschód).
///
/// Ta sama płaska aproksymacja co [LocalFrame] i ten sam zakres stosowalności:
/// dobra do kilkuset metrów, czyli znacznie więcej niż jeden krok demo.
LatLng offsetLatLng(LatLng from, double bearingDegrees, double meters) {
  final rad = bearingDegrees * math.pi / 180.0;
  final north = meters * math.cos(rad);
  final east = meters * math.sin(rad);
  final lonScale = _metersPerDegLon * math.cos(from.latitude * math.pi / 180.0);
  return LatLng(
    from.latitude + north / _metersPerDegLat,
    from.longitude + east / lonScale,
  );
}

/// Punkt w lokalnym układzie metrycznym.
class Vec2 {
  const Vec2(this.x, this.y);

  final double x;
  final double y;

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator *(double k) => Vec2(x * k, y * k);

  double get length => math.sqrt(x * x + y * y);

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => '(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// Płaski układ lokalny zaczepiony w (lat0, lon0).
class LocalFrame {
  const LocalFrame(this.lat0, this.lon0);

  /// Układ zaczepiony w środku ciężkości podanych punktów.
  factory LocalFrame.fromPoints(List<LatLng> points) {
    if (points.isEmpty) {
      throw ArgumentError('brak punktów do wyznaczenia układu lokalnego');
    }
    var lat = 0.0;
    var lon = 0.0;
    for (final p in points) {
      lat += p.latitude;
      lon += p.longitude;
    }
    return LocalFrame(lat / points.length, lon / points.length);
  }

  final double lat0;
  final double lon0;

  double get _lonScale => _metersPerDegLon * math.cos(lat0 * math.pi / 180.0);

  Vec2 toXy(LatLng p) => Vec2(
    (p.longitude - lon0) * _lonScale,
    (p.latitude - lat0) * _metersPerDegLat,
  );

  LatLng toLatLng(Vec2 v) =>
      LatLng(v.y / _metersPerDegLat + lat0, v.x / _lonScale + lon0);

  List<Vec2> manyToXy(List<LatLng> points) => [for (final p in points) toXy(p)];

  List<LatLng> manyToLatLng(List<Vec2> points) => [
    for (final v in points) toLatLng(v),
  ];
}

double distanceBetween(Vec2 a, Vec2 b) => (a - b).length;

/// Pole ze znakiem, dodatnie dla orientacji przeciwnej do ruchu zegara.
double signedArea(List<Vec2> polygon) {
  var sum = 0.0;
  for (var i = 0; i < polygon.length; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % polygon.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum / 2.0;
}

List<Vec2> asCcw(List<Vec2> polygon) =>
    signedArea(polygon) < 0 ? polygon.reversed.toList() : List.of(polygon);

/// Test przynależności punktu przez ray casting.
///
/// Punkty dokładnie na brzegu mogą wypaść w którąkolwiek stronę.
bool pointInPolygon(Vec2 p, List<Vec2> polygon) {
  var inside = false;
  final n = polygon.length;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final a = polygon[i];
    final b = polygon[j];
    if ((a.y > p.y) != (b.y > p.y) &&
        p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

double pointSegmentDistance(Vec2 p, Vec2 a, Vec2 b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0.0) return distanceBetween(p, a);
  var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  return distanceBetween(p, Vec2(a.x + t * dx, a.y + t * dy));
}

int _orientation(Vec2 a, Vec2 b, Vec2 c) {
  final v = (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y);
  if (v.abs() < 1e-12) return 0;
  return v > 0 ? 1 : -1;
}

bool _onSegment(Vec2 a, Vec2 b, Vec2 c) =>
    b.x <= math.max(a.x, c.x) &&
    b.x >= math.min(a.x, c.x) &&
    b.y <= math.max(a.y, c.y) &&
    b.y >= math.min(a.y, c.y);

bool segmentsIntersect(Vec2 p1, Vec2 p2, Vec2 p3, Vec2 p4) {
  final o1 = _orientation(p1, p2, p3);
  final o2 = _orientation(p1, p2, p4);
  final o3 = _orientation(p3, p4, p1);
  final o4 = _orientation(p3, p4, p2);

  if (o1 != o2 && o3 != o4) return true;
  if (o1 == 0 && _onSegment(p1, p3, p2)) return true;
  if (o2 == 0 && _onSegment(p1, p4, p2)) return true;
  if (o3 == 0 && _onSegment(p3, p1, p4)) return true;
  if (o4 == 0 && _onSegment(p3, p2, p4)) return true;
  return false;
}
