/// Model pola minowego: wierzchołki, miny, wybór boku startowego.
library;

import 'config.dart';
import 'geometry.dart';

/// Bok pola, od którego zaczyna się przejście.
///
/// Dla wielokąta o n wierzchołkach bok i to odcinek (v[i], v[i+1]).
/// Nazwy kierunkowe wybierają bok najbardziej wysunięty w danym kierunku.
enum Side {
  south('south'),
  north('north'),
  west('west'),
  east('east');

  const Side(this.wire);

  final String wire;

  Side get opposite => switch (this) {
    Side.south => Side.north,
    Side.north => Side.south,
    Side.west => Side.east,
    Side.east => Side.west,
  };

  static Side fromWire(String s) {
    final wanted = s.toLowerCase();
    for (final v in Side.values) {
      if (v.wire == wanted) return v;
    }
    throw ArgumentError('nieznany bok: $s');
  }
}

/// Pole minowe w lokalnym układzie płaskim XY (metry).
class Minefield {
  /// - [polygon]: wierzchołki pola, orientacja CCW, bez powtórzonego pierwszego,
  /// - [mines]: pozycje min,
  /// - [startSide]: indeks boku wejściowego,
  /// - [goalSide]: indeks boku wyjściowego,
  /// - [frame]: układ lokalny, jeśli pole powstało ze współrzędnych GPS.
  Minefield(
    this.polygon,
    this.mines,
    this.startSide,
    this.goalSide, {
    this.frame,
    Map<int, String>? labels,
  }) : labels = labels ?? <int, String>{} {
    if (polygon.length < 3) {
      throw ArgumentError('pole musi mieć co najmniej 3 wierzchołki');
    }
    final n = polygon.length;
    if (startSide < 0 || startSide >= n) {
      throw ArgumentError('startSide poza zakresem 0..${n - 1}');
    }
    if (goalSide < 0 || goalSide >= n) {
      throw ArgumentError('goalSide poza zakresem 0..${n - 1}');
    }
    if (startSide == goalSide) {
      throw ArgumentError(
        'bok startowy i docelowy nie mogą być tym samym bokiem',
      );
    }
  }

  /// Buduje pole z gotowych współrzędnych metrycznych.
  ///
  /// [startSide] i [goalSide] przyjmują indeks boku (`int`), [Side] albo nazwę
  /// kierunku (`String`). `goalSide == null` wybiera bok przeciwległy.
  factory Minefield.fromXy(
    List<Vec> polygon,
    List<Vec> mines, [
    Object startSide = 0,
    Object? goalSide,
  ]) {
    final poly = asCcw(polygon);
    final start = _resolveSide(poly, startSide);
    final goal = goalSide == null
        ? _oppositeSideIndex(poly, start)
        : _resolveSide(poly, goalSide);
    return Minefield(poly, List<Vec>.from(mines), start, goal);
  }

  /// Buduje pole ze współrzędnych GPS (lat, lon).
  ///
  /// Układ lokalny zaczepiony w środku ciężkości wierzchołków pola.
  factory Minefield.fromLatLon(
    List<LatLon> polygonLatLon,
    List<LatLon> minesLatLon, [
    Object startSide = 0,
    Object? goalSide,
  ]) {
    final frame = LocalFrame.fromPoints(polygonLatLon);
    final poly = asCcw(frame.manyToXy(polygonLatLon));
    final mines = frame.manyToXy(minesLatLon);
    final start = _resolveSide(poly, startSide);
    final goal = goalSide == null
        ? _oppositeSideIndex(poly, start)
        : _resolveSide(poly, goalSide);
    return Minefield(poly, mines, start, goal, frame: frame);
  }

  final List<Vec> polygon;
  final List<Vec> mines;
  final int startSide;
  final int goalSide;
  final LocalFrame? frame;
  final Map<int, String> labels;

  static int _resolveSide(List<Vec> poly, Object side) {
    if (side is int) return side;
    final resolved = side is String ? Side.fromWire(side) : side;
    if (resolved is! Side) {
      throw ArgumentError(
        'bok: oczekiwano int, Side albo String, dostano $side',
      );
    }
    return _directionalSideIndex(poly, resolved);
  }

  /// Bok, którego środek jest najbardziej wysunięty w danym kierunku.
  static int _directionalSideIndex(List<Vec> poly, Side side) {
    final n = poly.length;
    final key = switch (side) {
      Side.south => (Vec m) => m.y,
      Side.north => (Vec m) => -m.y,
      Side.west => (Vec m) => m.x,
      Side.east => (Vec m) => -m.x,
    };
    var bestI = 0;
    var bestV = double.infinity;
    for (var i = 0; i < n; i++) {
      final a = poly[i];
      final b = poly[(i + 1) % n];
      final v = key(Vec((a.x + b.x) / 2.0, (a.y + b.y) / 2.0));
      if (v < bestV) {
        bestI = i;
        bestV = v;
      }
    }
    return bestI;
  }

  /// Bok najdalszy od boku startowego (mierzone środkami).
  static int _oppositeSideIndex(List<Vec> poly, int start) {
    final n = poly.length;
    final a = poly[start];
    final b = poly[(start + 1) % n];
    final smid = Vec((a.x + b.x) / 2.0, (a.y + b.y) / 2.0);
    var bestI = (start + n ~/ 2) % n;
    var bestD = -1.0;
    for (var i = 0; i < n; i++) {
      if (i == start) continue;
      final c = poly[i];
      final d = poly[(i + 1) % n];
      final mid = Vec((c.x + d.x) / 2.0, (c.y + d.y) / 2.0);
      final dd = dist(smid, mid);
      if (dd > bestD) {
        bestI = i;
        bestD = dd;
      }
    }
    return bestI;
  }

  int get nSides => polygon.length;

  Segment side(int index) {
    final n = polygon.length;
    return (polygon[index % n], polygon[(index + 1) % n]);
  }

  Segment get startEdge => side(startSide);

  Segment get goalEdge => side(goalSide);

  bool contains(Vec p) => pointInPolygon(p, polygon);

  ({double minX, double minY, double maxX, double maxY}) bounds() {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final p in polygon) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }

  /// Wirtualne miny rozsypane po ścianach ograniczających korytarz.
  ///
  /// Boki równoległe do kierunku przejścia (czyli wszystkie poza startowym i
  /// docelowym) domykają korytarz. Dzięki temu algorytm zostaje czysto
  /// punktowy -- triangulacja nie wie nic o wielokącie.
  List<Vec> wallMines(VoronoiConfig cfg) {
    final pts = <Vec>[];
    for (var i = 0; i < nSides; i++) {
      if (!cfg.sealAllSides && (i == startSide || i == goalSide)) continue;
      final (a, b) = side(i);
      pts.addAll(sampleSegment(a, b, cfg.wallMineSpacing));
      pts.add(b);
    }
    return pts;
  }
}
