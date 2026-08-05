/// Geometria pomocnicza: projekcja GPS -> lokalne XY, testy wielokąta.
///
/// Projekcja: lokalna płaska aproksymacja wokół środka obszaru. Dla pola
/// wielkości kilkuset metrów błąd jest rzędu centymetrów, więc UTM jest zbędny.
///
/// Czysty Dart -- bez zależności od Fluttera i pakietów zewnętrznych.
library;

import 'dart:math' as math;

const double _mPerDegLat = 110540.0;
const double _mPerDegLon = 111320.0;

/// Punkt w lokalnym układzie płaskim XY (metry).
class Vec {
  const Vec(this.x, this.y);

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is Vec && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec($x, $y)';
}

/// Współrzędne geograficzne w stopniach.
typedef LatLon = ({double lat, double lon});

/// Odcinek zadany parą końców.
typedef Segment = (Vec, Vec);

/// Płaski układ lokalny zaczepiony w (lat0, lon0).
class LocalFrame {
  const LocalFrame(this.lat0, this.lon0);

  /// Układ zaczepiony w środku ciężkości podanych punktów (lat, lon).
  factory LocalFrame.fromPoints(List<LatLon> latlon) {
    if (latlon.isEmpty) {
      throw ArgumentError('brak punktów do wyznaczenia układu lokalnego');
    }
    var lat = 0.0;
    var lon = 0.0;
    for (final p in latlon) {
      lat += p.lat;
      lon += p.lon;
    }
    return LocalFrame(lat / latlon.length, lon / latlon.length);
  }

  final double lat0;
  final double lon0;

  double get _cosLat0 => math.cos(lat0 * math.pi / 180.0);

  Vec toXy(double lat, double lon) =>
      Vec((lon - lon0) * _mPerDegLon * _cosLat0, (lat - lat0) * _mPerDegLat);

  LatLon toLatLon(double x, double y) =>
      (lat: y / _mPerDegLat + lat0, lon: x / (_mPerDegLon * _cosLat0) + lon0);

  List<Vec> manyToXy(List<LatLon> latlon) => [
    for (final p in latlon) toXy(p.lat, p.lon),
  ];

  List<LatLon> manyToLatLon(List<Vec> xy) => [
    for (final p in xy) toLatLon(p.x, p.y),
  ];

  @override
  bool operator ==(Object other) =>
      other is LocalFrame && other.lat0 == lat0 && other.lon0 == lon0;

  @override
  int get hashCode => Object.hash(lat0, lon0);
}

double _hypot(double dx, double dy) => math.sqrt(dx * dx + dy * dy);

double dist(Vec a, Vec b) => _hypot(a.x - b.x, a.y - b.y);

/// Pole ze znakiem (dodatnie dla orientacji przeciwnej do ruchu zegara).
double signedArea(List<Vec> poly) {
  var s = 0.0;
  final n = poly.length;
  for (var i = 0; i < n; i++) {
    final p1 = poly[i];
    final p2 = poly[(i + 1) % n];
    s += p1.x * p2.y - p2.x * p1.y;
  }
  return s / 2.0;
}

/// Zwraca wielokąt w orientacji przeciwnej do ruchu wskazówek zegara.
List<Vec> asCcw(List<Vec> poly) {
  final pts = List<Vec>.from(poly);
  return signedArea(pts) >= 0 ? pts : pts.reversed.toList();
}

/// Ray casting. Punkty na brzegu mogą wypaść w którąkolwiek stronę.
bool pointInPolygon(Vec p, List<Vec> poly) {
  var inside = false;
  final n = poly.length;
  for (var i = 0; i < n; i++) {
    final p1 = poly[i];
    final p2 = poly[(i + 1) % n];
    if ((p1.y > p.y) != (p2.y > p.y)) {
      final t = (p.y - p1.y) / (p2.y - p1.y);
      if (p.x < p1.x + t * (p2.x - p1.x)) inside = !inside;
    }
  }
  return inside;
}

/// Odległość punktu od odcinka ab.
double pointSegmentDistance(Vec p, Vec a, Vec b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0.0) return _hypot(p.x - a.x, p.y - a.y);
  var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  return _hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

double distanceToPolygonBoundary(Vec p, List<Vec> poly) {
  final n = poly.length;
  var best = double.infinity;
  for (var i = 0; i < n; i++) {
    final d = pointSegmentDistance(p, poly[i], poly[(i + 1) % n]);
    if (d < best) best = d;
  }
  return best;
}

/// Punkty rozsypane po odcinku ab co ~spacing metrów, bez punktu b.
List<Vec> sampleSegment(Vec a, Vec b, double spacing) {
  final length = dist(a, b);
  if (length == 0.0) return [a];
  final steps = math.max(1, (length / spacing).ceil());
  return [
    for (var i = 0; i < steps; i++)
      Vec(a.x + (b.x - a.x) * i / steps, a.y + (b.y - a.y) * i / steps),
  ];
}

/// Środek okręgu opisanego. `null` dla trójkąta zdegenerowanego.
Vec? circumcenter(Vec a, Vec b, Vec c) {
  final d = 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
  if (d.abs() < 1e-12) return null;
  final a2 = a.x * a.x + a.y * a.y;
  final b2 = b.x * b.x + b.y * b.y;
  final c2 = c.x * c.x + c.y * c.y;
  final ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d;
  final uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d;
  return Vec(ux, uy);
}

int _orient(Vec a, Vec b, Vec c) {
  final v = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  if (v > 1e-12) return 1;
  if (v < -1e-12) return -1;
  return 0;
}

bool _onSegment(Vec a, Vec b, Vec c) =>
    math.min(a.x, b.x) - 1e-12 <= c.x &&
    c.x <= math.max(a.x, b.x) + 1e-12 &&
    math.min(a.y, b.y) - 1e-12 <= c.y &&
    c.y <= math.max(a.y, b.y) + 1e-12;

/// Czy odcinki p1p2 i p3p4 się przecinają (z przypadkami współliniowymi).
bool segmentsIntersect(Vec p1, Vec p2, Vec p3, Vec p4) {
  final o1 = _orient(p1, p2, p3);
  final o2 = _orient(p1, p2, p4);
  final o3 = _orient(p3, p4, p1);
  final o4 = _orient(p3, p4, p2);
  if (o1 != o2 && o3 != o4) return true;
  if (o1 == 0 && _onSegment(p1, p2, p3)) return true;
  if (o2 == 0 && _onSegment(p1, p2, p4)) return true;
  if (o3 == 0 && _onSegment(p3, p4, p1)) return true;
  if (o4 == 0 && _onSegment(p3, p4, p2)) return true;
  return false;
}

/// Czy odcinek ab leży w całości wewnątrz wielokąta (wypukłego lub nie).
bool segmentInPolygon(Vec a, Vec b, List<Vec> poly) {
  final mid = Vec((a.x + b.x) / 2.0, (a.y + b.y) / 2.0);
  if (!pointInPolygon(mid, poly)) return false;
  final n = poly.length;
  for (var i = 0; i < n; i++) {
    final e1 = poly[i];
    final e2 = poly[(i + 1) % n];
    if (segmentsIntersect(a, b, e1, e2)) {
      if (_touchesOnlyAtEndpoint(a, b, e1, e2)) continue;
      return false;
    }
  }
  return true;
}

bool _touchesOnlyAtEndpoint(Vec a, Vec b, Vec e1, Vec e2) {
  for (final endpoint in [a, b]) {
    if (pointSegmentDistance(endpoint, e1, e2) < 1e-9) return true;
  }
  return false;
}

double polylineLength(List<Vec> pts) {
  var total = 0.0;
  for (var i = 0; i < pts.length - 1; i++) {
    total += dist(pts[i], pts[i + 1]);
  }
  return total;
}
