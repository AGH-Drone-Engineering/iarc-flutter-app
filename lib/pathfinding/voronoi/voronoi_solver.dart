/// Solver: Delaunay -> graf Woronoja -> bottleneck Dijkstra -> wygładzanie.
///
/// Bottleneck Dijkstra maksymalizuje minimalny odstęp od miny na całej ścieżce
/// (maximin), zamiast minimalizować długość. Wśród ścieżek o tym samym odstępie
/// preferowana jest krótsza -- to drugie kryterium w kluczu kolejki.
library;

import 'dart:math' as math;

import 'config.dart';
import 'delaunay.dart';
import 'geometry.dart';
import 'minefield.dart';

/// Wynik wyznaczania ścieżki.
class VoronoiSolution {
  VoronoiSolution({
    this.found = false,
    this.clearance = 0.0,
    List<Vec>? rawPath,
    List<Vec>? path,
    this.smoothedClearance = 0.0,
    this.length = 0.0,
    this.reason = '',
    List<Vec>? obstacles,
    this.nRealMines = 0,
    List<Vec>? voronoiVertices,
    List<(int, int)>? voronoiEdges,
    List<Triangle>? triangles,
    List<int>? entryVertices,
    List<int>? exitVertices,
    Map<String, double>? timingsMs,
  }) : rawPath = rawPath ?? <Vec>[],
       path = path ?? <Vec>[],
       obstacles = obstacles ?? <Vec>[],
       voronoiVertices = voronoiVertices ?? <Vec>[],
       voronoiEdges = voronoiEdges ?? <(int, int)>[],
       triangles = triangles ?? <Triangle>[],
       entryVertices = entryVertices ?? <int>[],
       exitVertices = exitVertices ?? <int>[],
       timingsMs = timingsMs ?? <String, double>{};

  bool found;

  /// Odstęp w najwęższym miejscu ścieżki (od środka najbliższej miny).
  double clearance;

  /// Ścieżka po krawędziach Woronoja -- optymalna, zygzakowata.
  List<Vec> rawPath;

  /// Ścieżka po wygładzeniu -- do wyświetlenia.
  List<Vec> path;

  double smoothedClearance;
  double length;
  String reason;

  // diagnostyka / wizualizacja

  /// Miny realne + wirtualne miny ścian (generatory Woronoja).
  final List<Vec> obstacles;
  final int nRealMines;
  final List<Vec> voronoiVertices;
  final List<(int, int)> voronoiEdges;
  final List<Triangle> triangles;
  final List<int> entryVertices;
  final List<int> exitVertices;
  final Map<String, double> timingsMs;

  double get isSafeFor => clearance;

  /// Czy najwęższe miejsce mieści wymagany odstęp z konfiguracji.
  bool safe(VoronoiConfig cfg) => found && clearance >= cfg.requiredClearance;
}

/// Wyznacza najbezpieczniejsze przejście przez pole minowe.
VoronoiSolution solve(Minefield field, [VoronoiConfig? config]) {
  final cfg = config ?? VoronoiConfig();
  final t = <String, double>{};
  final clock = Stopwatch()..start();
  double since(int from) => (clock.elapsedMicroseconds - from) / 1000.0;

  // 1. generatory: miny realne + wirtualne miny na ścianach
  var t0 = clock.elapsedMicroseconds;
  final wall = field.wallMines(cfg);
  final obstacles = <Vec>[...field.mines, ...wall];
  final nReal = field.mines.length;
  t['walls'] = since(t0);

  if (obstacles.length < 3) {
    return _trivialSolution(field, cfg, obstacles, nReal);
  }

  // 2. triangulacja Delaunaya
  t0 = clock.elapsedMicroseconds;
  final triangles = triangulate(obstacles);
  t['delaunay'] = since(t0);
  if (triangles.isEmpty) {
    return _trivialSolution(field, cfg, obstacles, nReal);
  }

  // 3. graf Woronoja gratis z triangulacji
  t0 = clock.elapsedMicroseconds;
  final graph = voronoiEdges(obstacles, triangles);
  final vertices = graph.vertices;
  final clearance = graph.clearance;
  t['voronoi'] = since(t0);

  // 4. przytnij do pola
  t0 = clock.elapsedMicroseconds;
  final inside = [for (final v in vertices) field.contains(v)];
  final adjacency = List<List<(int, double)>>.generate(
    vertices.length,
    (_) => <(int, double)>[],
  );
  for (var i = 0; i < graph.edges.length; i++) {
    final (a, b) = graph.edges[i];
    final (ga, gb) = graph.generators[i];
    if (cfg.clipToField) {
      if (!(inside[a] && inside[b])) continue;
      if (!segmentInPolygon(vertices[a], vertices[b], field.polygon)) continue;
    }
    final w = _edgeClearance(
      vertices[a],
      vertices[b],
      obstacles[ga],
      obstacles[gb],
    );
    adjacency[a].add((b, w));
    adjacency[b].add((a, w));
  }
  t['graph'] = since(t0);

  // 5. portale wejścia / wyjścia
  final entry = _portalVertices(field, cfg, vertices, inside, field.startEdge);
  final exit = _portalVertices(field, cfg, vertices, inside, field.goalEdge);

  final partial = VoronoiSolution(
    found: false,
    clearance: 0.0,
    obstacles: obstacles,
    nRealMines: nReal,
    voronoiVertices: vertices,
    voronoiEdges: graph.edges,
    triangles: triangles,
    entryVertices: entry,
    exitVertices: exit,
    timingsMs: t,
  );
  if (entry.isEmpty || exit.isEmpty) {
    partial.reason =
        'brak wierzchołków Woronoja przy krawędzi '
        '${entry.isEmpty ? 'wejściowej' : 'wyjściowej'} '
        '-- zmniejsz wallMineSpacing lub sprawdź geometrię pola';
    return partial;
  }

  // 6. bottleneck Dijkstra ze super-źródła do super-ujścia
  t0 = clock.elapsedMicroseconds;
  final (best, prev) = _bottleneckDijkstra(
    adjacency,
    vertices,
    clearance,
    entry,
    exit.toSet(),
    field,
    obstacles,
  );
  t['dijkstra'] = since(t0);

  final chosen = _bestExit(best, exit, vertices, field, obstacles);
  if (chosen == null) {
    partial.reason =
        'nie istnieje ścieżka po krawędziach Woronoja między krawędzią '
        'wejściową a wyjściową (pole rozdzielone przez miny lub ściany)';
    return partial;
  }

  final (end, bottleneck) = chosen;
  var raw = _reconstruct(prev, end, vertices);
  raw = _attachEndpoints(raw, field);

  // 7. wygładzanie do wyświetlenia
  t0 = clock.elapsedMicroseconds;
  final smooth = _smooth(raw, obstacles, field, cfg, bottleneck);
  t['smoothing'] = since(t0);

  partial.found = true;
  partial.clearance = bottleneck;
  partial.rawPath = raw;
  partial.path = smooth;
  partial.smoothedClearance = _pathClearance(smooth, obstacles);
  partial.length = polylineLength(smooth);
  partial.reason = bottleneck >= cfg.requiredClearance
      ? 'ok'
      : 'najwęższe miejsce ${bottleneck.toStringAsFixed(2)} m < wymagane '
            '${cfg.requiredClearance.toStringAsFixed(2)} m -- przejście '
            'istnieje, ale jest poniżej progu bezpieczeństwa';
  return partial;
}

/// Najmniejszy odstęp od miny na całej krawędzi Woronoja ab.
///
/// Krawędź leży na symetralnej pary min (genA, genB) i to one są najbliższe w
/// każdym jej punkcie, więc wystarczy odległość obu od odcinka. Liczone
/// dokładnie -- odległość punktu od odcinka jest wypukła, minimum wypada w
/// końcu lub w rzucie prostopadłym.
///
/// Branie samych końców (promieni okręgów opisanych) zawyżałoby wynik: przy
/// krawędzi przyciętej do pola najwęższe miejsce potrafi wypaść w środku.
double _edgeClearance(Vec a, Vec b, Vec genA, Vec genB) => math.min(
  pointSegmentDistance(genA, a, b),
  pointSegmentDistance(genB, a, b),
);

// --------------------------------------------------------------------- portale

/// Wierzchołki Woronoja nadające się na wejście/wyjście przez daną krawędź.
///
/// Kandydat musi leżeć w polu i być najbliższy tej krawędzi (bliżej niż
/// którejkolwiek innej), co odsiewa wierzchołki przy ścianach bocznych.
List<int> _portalVertices(
  Minefield field,
  VoronoiConfig cfg,
  List<Vec> vertices,
  List<bool> inside,
  Segment edge,
) {
  final (a, b) = edge;
  final others = <Segment>[
    for (var i = 0; i < field.nSides; i++)
      if (field.side(i) != edge) field.side(i),
  ];
  final result = <int>[];
  for (var i = 0; i < vertices.length; i++) {
    if (!inside[i]) continue;
    final v = vertices[i];
    final dEdge = pointSegmentDistance(v, a, b);
    if (others.isNotEmpty) {
      var nearest = double.infinity;
      for (final (c, d) in others) {
        final dd = pointSegmentDistance(v, c, d);
        if (dd < nearest) nearest = dd;
      }
      if (dEdge > nearest + cfg.portalMargin) continue;
    }
    result.add(i);
  }
  if (result.isNotEmpty) return result;

  // awaryjnie: najbliższy wierzchołek wewnętrzny
  var best = -1;
  var bestD = double.infinity;
  for (var i = 0; i < inside.length; i++) {
    if (!inside[i]) continue;
    final d = pointSegmentDistance(vertices[i], a, b);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best < 0 ? <int>[] : <int>[best];
}

// ------------------------------------------------------------------- Dijkstra

/// Maksymalizuje minimalny odstęp; remisy rozstrzyga krótsza ścieżka.
///
/// Odcinek zjazdowy (brzeg pola -> pierwszy wierzchołek Woronoja) wchodzi do
/// bottlenecku źródła. Bez tego Dijkstra raportowałaby odstęp korytarza, a
/// ścieżka i tak przechodziłaby ciasno obok miny przy samym wejściu.
///
/// Zwraca (best[v] = (bottleneck, długość), prev).
(Map<int, (double, double)>, Map<int, int>) _bottleneckDijkstra(
  List<List<(int, double)>> adjacency,
  List<Vec> vertices,
  List<double> clearance,
  List<int> sources,
  Set<int> targets,
  Minefield field,
  List<Vec> obstacles,
) {
  // klucz kolejki: (-bottleneck, długość) -> najpierw najbezpieczniejsze
  final best = <int, (double, double)>{};
  final prev = <int, int>{};
  final heap = _MinHeap();

  final (a, b) = field.startEdge;
  for (final s in sources) {
    final entryPoint = _projectOnSegment(vertices[s], a, b);
    final approachClr = _segmentClearance(entryPoint, vertices[s], obstacles);
    final c = math.min(clearance[s], approachClr);
    final approach = dist(entryPoint, vertices[s]);
    final cur = best[s];
    if (cur != null && (cur.$1 > c || (cur.$1 == c && cur.$2 <= approach))) {
      continue;
    }
    best[s] = (c, approach);
    heap.push((-c, approach, s));
  }

  while (heap.isNotEmpty) {
    final (negC, length, v) = heap.pop();
    final c = -negC;
    final cur = best[v];
    if ((cur?.$1 ?? -1.0) > c) continue;
    if (cur != (c, length)) continue;
    if (targets.contains(v)) continue; // cel osiągnięty tą etykietą

    for (final (u, w) in adjacency[v]) {
      final nc = math.min(c, w);
      final nl = length + dist(vertices[v], vertices[u]);
      final other = best[u];
      if (other == null ||
          nc > other.$1 + 1e-12 ||
          ((nc - other.$1).abs() <= 1e-12 && nl < other.$2 - 1e-9)) {
        best[u] = (nc, nl);
        prev[u] = v;
        heap.push((-nc, nl, u));
      }
    }
  }
  return (best, prev);
}

/// Wybiera wyjście po domknięciu odcinka zjazdowego na krawędź docelową.
///
/// Zwraca (indeks wierzchołka, bottleneck całej ścieżki wraz z oboma zjazdami).
(int, double)? _bestExit(
  Map<int, (double, double)> best,
  List<int> exits,
  List<Vec> vertices,
  Minefield field,
  List<Vec> obstacles,
) {
  final (a, b) = field.goalEdge;
  var chosen = -1;
  var bestTotal = 0.0;
  var bestLength = 0.0;
  for (final v in exits) {
    final label = best[v];
    if (label == null) continue;
    final (bottleneck, length) = label;
    final exitPoint = _projectOnSegment(vertices[v], a, b);
    final exitClr = _segmentClearance(exitPoint, vertices[v], obstacles);
    final total = math.min(bottleneck, exitClr);
    final totalLength = length + dist(vertices[v], exitPoint);
    if (chosen < 0 ||
        total > bestTotal ||
        (total == bestTotal && totalLength < bestLength)) {
      chosen = v;
      bestTotal = total;
      bestLength = totalLength;
    }
  }
  return chosen < 0 ? null : (chosen, bestTotal);
}

List<Vec> _reconstruct(Map<int, int> prev, int end, List<Vec> vertices) {
  final chain = <int>[end];
  final seen = <int>{end};
  while (prev.containsKey(chain.last)) {
    final p = prev[chain.last]!;
    if (seen.contains(p)) break;
    chain.add(p);
    seen.add(p);
  }
  return [for (final i in chain.reversed) vertices[i]];
}

/// Dokleja rzut pierwszego/ostatniego punktu na krawędź startową/docelową.
List<Vec> _attachEndpoints(List<Vec> path, Minefield field) {
  if (path.isEmpty) return path;
  final (sa, sb) = field.startEdge;
  final (ga, gb) = field.goalEdge;
  final start = _projectOnSegment(path.first, sa, sb);
  final goal = _projectOnSegment(path.last, ga, gb);
  final out = List<Vec>.from(path);
  if (dist(start, out.first) > 1e-6) out.insert(0, start);
  if (dist(goal, out.last) > 1e-6) out.add(goal);
  return out;
}

Vec _projectOnSegment(Vec p, Vec a, Vec b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0.0) return a;
  var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  return Vec(a.x + t * dx, a.y + t * dy);
}

// ----------------------------------------------------------------- wygładzanie

/// Minimalny odstęp od min wzdłuż odcinka ab -- dokładnie.
///
/// Liczone jako min po minach z odległości mina-odcinek, a nie przez
/// próbkowanie punktów na odcinku. Próbkowanie przepuszczało wąskie miejsca
/// wypadające między próbkami, przez co kontrola wygładzania zawyżała wynik.
/// Koszt ten sam rząd, a wynik nie zależy od gęstości próbek.
double _segmentClearance(Vec a, Vec b, List<Vec> obstacles) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final len2 = dx * dx + dy * dy;
  var worst = double.infinity;
  if (len2 == 0.0) {
    for (final o in obstacles) {
      final d = (o.x - a.x) * (o.x - a.x) + (o.y - a.y) * (o.y - a.y);
      if (d < worst) worst = d;
    }
    return worst == double.infinity ? double.infinity : math.sqrt(worst);
  }

  for (final o in obstacles) {
    var t = ((o.x - a.x) * dx + (o.y - a.y) * dy) / len2;
    if (t < 0.0) {
      t = 0.0;
    } else if (t > 1.0) {
      t = 1.0;
    }
    final cx = a.x + t * dx - o.x;
    final cy = a.y + t * dy - o.y;
    final d = cx * cx + cy * cy;
    if (d < worst) worst = d;
  }
  return worst == double.infinity ? double.infinity : math.sqrt(worst);
}

double _pathClearance(List<Vec> path, List<Vec> obstacles) {
  if (path.length < 2) return 0.0;
  var worst = double.infinity;
  for (var i = 0; i < path.length - 1; i++) {
    final c = _segmentClearance(path[i], path[i + 1], obstacles);
    if (c < worst) worst = c;
  }
  return worst;
}

/// Wygładza ścieżkę pod wyświetlanie, pilnując progu clearance.
///
/// Ścieżka po krawędziach Woronoja jest optymalna, ale zygzakuje. Skracanie
/// odcinków usuwa zygzaki, Chaikin zaokrągla narożniki. Oba kroki są
/// odrzucane, jeśli obniżyłyby clearance poniżej progu.
List<Vec> _smooth(
  List<Vec> raw,
  List<Vec> obstacles,
  Minefield field,
  VoronoiConfig cfg,
  double rawClearance,
) {
  if (cfg.smoothing == 'none' || raw.length < 3) return List<Vec>.from(raw);

  final floor = rawClearance * cfg.smoothingClearanceRatio;
  var out = List<Vec>.from(raw);

  if (cfg.smoothing.contains('shortcut')) {
    out = _shortcut(out, obstacles, field, cfg, floor);
  }
  if (cfg.smoothing.contains('chaikin')) {
    out = _chaikin(out, obstacles, field, cfg, floor);
  }
  return out;
}

/// Zachłanne skracanie: pomiń punkty pośrednie, jeśli skrót jest bezpieczny.
List<Vec> _shortcut(
  List<Vec> path,
  List<Vec> obstacles,
  Minefield field,
  VoronoiConfig cfg,
  double floor,
) {
  if (path.length < 3) return List<Vec>.from(path);
  final out = <Vec>[path.first];
  final n = path.length;
  var i = 0;
  while (i < n - 1) {
    var bestJ = i + 1;
    for (var j = n - 1; j > i + 1; j--) {
      final a = path[i];
      final b = path[j];
      if (_segmentClearance(a, b, obstacles) < floor) continue;
      if (cfg.clipToField && !segmentInPolygon(a, b, field.polygon)) continue;
      bestJ = j;
      break;
    }
    out.add(path[bestJ]);
    i = bestJ;
  }
  return out;
}

/// Chaikin z kontrolą clearance; końce ścieżki zostają nieruchome.
List<Vec> _chaikin(
  List<Vec> path,
  List<Vec> obstacles,
  Minefield field,
  VoronoiConfig cfg,
  double floor,
) {
  var current = List<Vec>.from(path);
  for (var iter = 0; iter < cfg.chaikinIterations; iter++) {
    if (current.length < 3) break;
    final candidate = <Vec>[current.first];
    for (var i = 0; i < current.length - 1; i++) {
      final a = current[i];
      final b = current[i + 1];
      candidate.add(Vec(0.75 * a.x + 0.25 * b.x, 0.75 * a.y + 0.25 * b.y));
      candidate.add(Vec(0.25 * a.x + 0.75 * b.x, 0.25 * a.y + 0.75 * b.y));
    }
    candidate.add(current.last);

    if (_pathClearance(candidate, obstacles) < floor) break;
    if (cfg.clipToField && !_insideField(candidate, field)) break;
    current = candidate;
  }
  return current;
}

/// Czy wszystkie punkty pośrednie leżą w polu (końce siedzą na brzegu).
bool _insideField(List<Vec> path, Minefield field) {
  for (var i = 1; i < path.length - 1; i++) {
    if (!field.contains(path[i])) return false;
  }
  return true;
}

// ------------------------------------------------------------------- fallback

/// Za mało generatorów na triangulację -- prosta przez środki krawędzi.
VoronoiSolution _trivialSolution(
  Minefield field,
  VoronoiConfig cfg,
  List<Vec> obstacles,
  int nReal,
) {
  final (a, b) = field.startEdge;
  final (c, d) = field.goalEdge;
  final start = Vec((a.x + b.x) / 2.0, (a.y + b.y) / 2.0);
  final goal = Vec((c.x + d.x) / 2.0, (c.y + d.y) / 2.0);
  final path = <Vec>[start, goal];
  final clr = obstacles.isNotEmpty
      ? _segmentClearance(start, goal, obstacles)
      : double.infinity;
  return VoronoiSolution(
    found: true,
    clearance: clr,
    rawPath: path,
    path: path,
    smoothedClearance: clr,
    length: dist(start, goal),
    reason: 'za mało przeszkód na triangulację -- ścieżka prosta',
    obstacles: obstacles,
    nRealMines: nReal,
  );
}

/// Kopiec binarny na etykiety (-bottleneck, długość, wierzchołek),
/// porównywane leksykograficznie -- odpowiednik krotek w `heapq`.
class _MinHeap {
  final List<(double, double, int)> _items = [];

  bool get isNotEmpty => _items.isNotEmpty;

  void push((double, double, int) e) {
    _items.add(e);
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (!_less(_items[i], _items[parent])) break;
      _swap(i, parent);
      i = parent;
    }
  }

  (double, double, int) pop() {
    final top = _items.first;
    final last = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = last;
      var i = 0;
      final n = _items.length;
      while (true) {
        final l = 2 * i + 1;
        final r = l + 1;
        var smallest = i;
        if (l < n && _less(_items[l], _items[smallest])) smallest = l;
        if (r < n && _less(_items[r], _items[smallest])) smallest = r;
        if (smallest == i) break;
        _swap(i, smallest);
        i = smallest;
      }
    }
    return top;
  }

  void _swap(int i, int j) {
    final tmp = _items[i];
    _items[i] = _items[j];
    _items[j] = tmp;
  }

  static bool _less((double, double, int) a, (double, double, int) b) {
    if (a.$1 != b.$1) return a.$1 < b.$1;
    if (a.$2 != b.$2) return a.$2 < b.$2;
    return a.$3 < b.$3;
  }
}
