/// Triangulacja Delaunaya -- bez zależności zewnętrznych.
///
/// Algorytm Bowyera-Watsona z super-trójkątem. Dla 200-800 punktów (miny +
/// wirtualne miny na ścianach) to milisekundy. Jeśli potrzebna jest wydajność
/// O(n log n), podmień na port Delaunatora -- interfejs [triangulate] zostaje
/// ten sam.
library;

import 'geometry.dart';

/// Trójkąt jako trójka indeksów w liście punktów.
typedef Triangle = (int, int, int);

/// Wynik [voronoiEdges]: wierzchołki, krawędzie, clearance i generatory.
typedef VoronoiGraph = ({
  List<Vec> vertices,
  List<(int, int)> edges,
  List<double> clearance,
  List<(int, int)> generators,
});

/// Czy p leży wewnątrz okręgu opisanego na abc (abc zorientowane CCW).
bool _inCircumcircle(Vec p, Vec a, Vec b, Vec c) {
  final ax = a.x - p.x;
  final ay = a.y - p.y;
  final bx = b.x - p.x;
  final by = b.y - p.y;
  final cx = c.x - p.x;
  final cy = c.y - p.y;
  final det =
      (ax * ax + ay * ay) * (bx * cy - cx * by) -
      (bx * bx + by * by) * (ax * cy - cx * ay) +
      (cx * cx + cy * cy) * (ax * by - bx * ay);
  return det > 1e-12;
}

Triangle _ccw(List<Vec> pts, Triangle t) {
  final (i, j, k) = t;
  final a = pts[i];
  final b = pts[j];
  final c = pts[k];
  final cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  return cross > 0 ? t : (i, k, j);
}

(int, int) _key(Vec p, double inv) =>
    ((p.x * inv).round(), (p.y * inv).round());

/// Usuwa duplikaty (kluczowe -- powtórzone miny psują triangulację).
List<Vec> _dedup(List<Vec> points, [double eps = 1e-9]) {
  final seen = <(int, int)>{};
  final unique = <Vec>[];
  final inv = 1.0 / eps;
  for (final p in points) {
    if (seen.add(_key(p, inv))) unique.add(p);
  }
  return unique;
}

/// Zwraca listę trójkątów (indeksy w [points]), każdy w orientacji CCW.
///
/// Punkty zduplikowane są ignorowane; zwracane indeksy wskazują na oryginalną
/// listę [points].
List<Triangle> triangulate(List<Vec> points) {
  if (points.length < 3) return [];

  final unique = _dedup(points);
  if (unique.length < 3) return [];

  var minx = double.infinity;
  var maxx = -double.infinity;
  var miny = double.infinity;
  var maxy = -double.infinity;
  for (final p in unique) {
    if (p.x < minx) minx = p.x;
    if (p.x > maxx) maxx = p.x;
    if (p.y < miny) miny = p.y;
    if (p.y > maxy) maxy = p.y;
  }
  final dx = (maxx - minx) > 1e-6 ? maxx - minx : 1e-6;
  final dy = (maxy - miny) > 1e-6 ? maxy - miny : 1e-6;
  final cx = (minx + maxx) / 2.0;
  final cy = (miny + maxy) / 2.0;
  final span = (dx > dy ? dx : dy) * 1000.0;

  final work = List<Vec>.from(unique);
  final n = unique.length;
  work.add(Vec(cx - span, cy - span));
  work.add(Vec(cx + span, cy - span));
  work.add(Vec(cx, cy + span));

  var triangles = <Triangle>[_ccw(work, (n, n + 1, n + 2))];

  for (var idx = 0; idx < n; idx++) {
    final p = work[idx];
    final bad = <Triangle>[];
    for (final t in triangles) {
      if (_inCircumcircle(p, work[t.$1], work[t.$2], work[t.$3])) bad.add(t);
    }

    final edgeCount = <(int, int), int>{};
    for (final (i, j, k) in bad) {
      for (final e in [(i, j), (j, k), (k, i)]) {
        final key = e.$1 < e.$2 ? e : (e.$2, e.$1);
        edgeCount[key] = (edgeCount[key] ?? 0) + 1;
      }
    }

    final badSet = bad.toSet();
    triangles = [
      for (final t in triangles)
        if (!badSet.contains(t)) t,
    ];

    edgeCount.forEach((edge, count) {
      if (count == 1) triangles.add(_ccw(work, (edge.$1, edge.$2, idx)));
    });
  }

  final remap = _buildRemap(points, unique);
  final result = <Triangle>[];
  for (final t in triangles) {
    if (t.$1 >= n || t.$2 >= n || t.$3 >= n) continue;
    result.add((remap[t.$1], remap[t.$2], remap[t.$3]));
  }
  return result;
}

/// Mapuje indeks w [unique] -> pierwszy odpowiadający indeks w [original].
List<int> _buildRemap(
  List<Vec> original,
  List<Vec> unique, [
  double eps = 1e-9,
]) {
  final inv = 1.0 / eps;
  final lookup = <(int, int), int>{};
  for (var i = 0; i < original.length; i++) {
    lookup.putIfAbsent(_key(original[i], inv), () => i);
  }
  return [for (final p in unique) lookup[_key(p, inv)]!];
}

/// Graf Woronoja wyprowadzony wprost z triangulacji.
///
/// Zwraca (wierzchołki, krawędzie, clearance wierzchołków, generatory), gdzie:
///   - wierzchołek Woronoja = circumcenter trójkąta Delaunaya,
///   - krawędź = para circumcenterów trójkątów dzielących krawędź Delaunaya,
///   - clearance wierzchołka = promień okręgu opisanego (odległość do
///     najbliższego generatora, czyli do najbliższej miny),
///   - generators[i] = para min rozdzielana krawędzią i (indeksy w [points]).
///     Krawędź leży na symetralnej tej pary, więc jej clearance da się policzyć
///     dokładnie, bez sprawdzania wszystkich min.
VoronoiGraph voronoiEdges(List<Vec> points, List<Triangle> triangles) {
  final vertices = <Vec>[];
  final clearance = <double>[];

  final vertexOfTri = <int, int>{};
  for (var ti = 0; ti < triangles.length; ti++) {
    final (i, j, k) = triangles[ti];
    final cc = circumcenter(points[i], points[j], points[k]);
    if (cc == null) continue;
    vertexOfTri[ti] = vertices.length;
    vertices.add(cc);
    clearance.add(dist(cc, points[i]));
  }

  final edgeTris = <(int, int), List<int>>{};
  for (var ti = 0; ti < triangles.length; ti++) {
    final (i, j, k) = triangles[ti];
    for (final e in [(i, j), (j, k), (k, i)]) {
      final key = e.$1 < e.$2 ? e : (e.$2, e.$1);
      edgeTris.putIfAbsent(key, () => <int>[]).add(ti);
    }
  }

  final edges = <(int, int)>[];
  final generators = <(int, int)>[];
  edgeTris.forEach((generatorPair, tris) {
    // krawędź brzegowa -- promień Woronoja idzie w nieskończoność
    if (tris.length != 2) return;
    final v1 = vertexOfTri[tris[0]];
    final v2 = vertexOfTri[tris[1]];
    if (v1 == null || v2 == null || v1 == v2) return;
    edges.add((v1, v2));
    generators.add(generatorPair);
  });

  return (
    vertices: vertices,
    edges: edges,
    clearance: clearance,
    generators: generators,
  );
}
