import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_esp_android_communication/pathfinding/voronoi/config.dart';
import 'package:flutter_esp_android_communication/pathfinding/voronoi/delaunay.dart';
import 'package:flutter_esp_android_communication/pathfinding/voronoi/geometry.dart';
import 'package:flutter_esp_android_communication/pathfinding/voronoi/minefield.dart';
import 'package:flutter_esp_android_communication/pathfinding/voronoi/voronoi_solver.dart';

/// Faktyczny minimalny odstęp od min, próbkowany gęsto (kontrola solvera).
double denseClearance(
  List<Vec> path,
  List<Vec> obstacles, {
  double step = 0.25,
}) {
  var worst = double.infinity;
  for (var i = 0; i < path.length - 1; i++) {
    final a = path[i];
    final b = path[i + 1];
    final seg = math.sqrt(
      (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y),
    );
    final n = math.max(2, (seg / step).toInt());
    for (var k = 0; k <= n; k++) {
      final t = k / n;
      final p = Vec(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
      for (final o in obstacles) {
        final d = math.sqrt(
          (p.x - o.x) * (p.x - o.x) + (p.y - o.y) * (p.y - o.y),
        );
        if (d < worst) worst = d;
      }
    }
  }
  return worst;
}

List<Vec> rectangle(double width, double height) => [
  const Vec(0.0, 0.0),
  Vec(width, 0.0),
  Vec(width, height),
  Vec(0.0, height),
];

/// Dart throwing z malejącym odstępem -- odpowiednik rozkładu "poisson".
List<Vec> generateMines(
  List<Vec> polygon,
  int count, {
  required int seed,
  double minSpacing = 0.0,
  double edgeMargin = 0.0,
}) {
  if (count <= 0) return [];
  final rng = math.Random(seed);
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = -double.infinity;
  var maxY = -double.infinity;
  for (final p in polygon) {
    minX = math.min(minX, p.x);
    minY = math.min(minY, p.y);
    maxX = math.max(maxX, p.x);
    maxY = math.max(maxY, p.y);
  }

  bool ok(Vec p) {
    if (!pointInPolygon(p, polygon)) return false;
    if (edgeMargin > 0 && distanceToPolygonBoundary(p, polygon) < edgeMargin) {
      return false;
    }
    return true;
  }

  bool accepts(Vec p, List<Vec> placed, double spacing) {
    final s2 = spacing * spacing;
    for (final q in placed) {
      if ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) < s2) {
        return false;
      }
    }
    return true;
  }

  final floor = math.max(minSpacing, 1e-6);
  var spacing = floor;
  final placed = <Vec>[];
  var stagnation = 0;
  while (placed.length < count) {
    final p = Vec(
      minX + rng.nextDouble() * (maxX - minX),
      minY + rng.nextDouble() * (maxY - minY),
    );
    if (ok(p) && accepts(p, placed, spacing)) {
      placed.add(p);
      stagnation = 0;
      continue;
    }
    stagnation += 1;
    if (stagnation > 400) {
      if (spacing <= floor * 0.35 || spacing < 1e-3) break;
      spacing *= 0.8;
      stagnation = 0;
    }
  }
  return placed;
}

Minefield makeField({int seed = 42, int mines = 150}) {
  final poly = rectangle(500.0, 300.0);
  final pts = generateMines(
    poly,
    mines,
    seed: seed,
    minSpacing: 12.0,
    edgeMargin: 5.0,
  );
  return Minefield.fromXy(poly, pts, 'south');
}

void main() {
  group('zgodność bottlenecku', () {
    for (final seed in [1, 7, 42, 99, 2024]) {
      test('raportowany clearance nie zawyża faktycznego (seed $seed)', () {
        final f = makeField(seed: seed);
        final sol = solve(
          f,
          VoronoiConfig(bodyClearance: 2.0, wallMineSpacing: 8.0),
        );
        expect(sol.found, isTrue);

        final actual = denseClearance(sol.rawPath, sol.obstacles);
        expect(
          sol.clearance,
          lessThanOrEqualTo(actual + 0.05),
          reason:
              'raportowano ${sol.clearance.toStringAsFixed(2)} m, '
              'a faktycznie ${actual.toStringAsFixed(2)} m',
        );
      });
    }

    for (final seed in [1, 42, 2024]) {
      test('wygładzanie trzyma próg clearance (seed $seed)', () {
        final cfg = VoronoiConfig(
          bodyClearance: 2.0,
          wallMineSpacing: 8.0,
          smoothingClearanceRatio: 0.9,
        );
        final f = makeField(seed: seed);
        final sol = solve(f, cfg);
        expect(sol.found, isTrue);

        final actual = denseClearance(sol.path, sol.obstacles);
        final floor = sol.clearance * cfg.smoothingClearanceRatio;
        expect(
          actual,
          greaterThanOrEqualTo(floor - 0.05),
          reason:
              'po wygładzeniu ${actual.toStringAsFixed(2)} m '
              '< próg ${floor.toStringAsFixed(2)} m',
        );
      });
    }

    test('wygładzanie skraca ścieżkę względem zygzaka po Woronoju', () {
      final f = makeField();
      final sol = solve(
        f,
        VoronoiConfig(bodyClearance: 2.0, wallMineSpacing: 8.0),
      );
      expect(sol.found, isTrue);
      expect(
        polylineLength(sol.path),
        lessThanOrEqualTo(polylineLength(sol.rawPath) + 1e-6),
      );
    });

    test('ścieżka zostaje w polu', () {
      final f = makeField();
      final sol = solve(
        f,
        VoronoiConfig(bodyClearance: 2.0, wallMineSpacing: 8.0),
      );
      expect(sol.found, isTrue);
      for (final p in sol.path.sublist(1, sol.path.length - 1)) {
        expect(
          pointInPolygon(p, f.polygon),
          isTrue,
          reason: 'punkt $p poza polem',
        );
      }
    });

    test('ścieżka łączy krawędź startową z docelową', () {
      final f = makeField();
      final sol = solve(
        f,
        VoronoiConfig(bodyClearance: 2.0, wallMineSpacing: 8.0),
      );
      expect(sol.found, isTrue);
      final (sa, sb) = f.startEdge;
      final (ga, gb) = f.goalEdge;
      expect(pointSegmentDistance(sol.path.first, sa, sb), lessThan(1e-6));
      expect(pointSegmentDistance(sol.path.last, ga, gb), lessThan(1e-6));
    });

    test('smoothedClearance zgadza się z gęstym próbkowaniem', () {
      final f = makeField();
      final sol = solve(
        f,
        VoronoiConfig(bodyClearance: 2.0, wallMineSpacing: 8.0),
      );
      expect(sol.found, isTrue);
      final actual = denseClearance(sol.path, sol.obstacles);
      expect(sol.smoothedClearance, lessThanOrEqualTo(actual + 0.05));
    });
  });

  group('Delaunay', () {
    test('warunek pustego okręgu opisanego', () {
      final rng = math.Random(11);
      final pts = [
        for (var i = 0; i < 60; i++)
          Vec(rng.nextDouble() * 100.0, rng.nextDouble() * 100.0),
      ];
      final tris = triangulate(pts);
      expect(tris, isNotEmpty);

      for (final (i, j, k) in tris) {
        final cc = circumcenter(pts[i], pts[j], pts[k]);
        expect(cc, isNotNull);
        final r = dist(cc!, pts[i]);
        for (var m = 0; m < pts.length; m++) {
          if (m == i || m == j || m == k) continue;
          expect(
            dist(cc, pts[m]),
            greaterThanOrEqualTo(r - 1e-6),
            reason: 'punkt $m w okręgu trójkąta ($i, $j, $k)',
          );
        }
      }
    });

    test('duplikaty punktów są ignorowane', () {
      final pts = [
        const Vec(0.0, 0.0),
        const Vec(10.0, 0.0),
        const Vec(5.0, 8.0),
        const Vec(10.0, 0.0),
        const Vec(0.0, 0.0),
      ];
      expect(triangulate(pts).length, 1);
    });

    test('wejście zdegenerowane', () {
      expect(triangulate([]), isEmpty);
      expect(triangulate([const Vec(0.0, 0.0), const Vec(1.0, 1.0)]), isEmpty);

      final collinear = [for (var i = 0; i < 5; i++) Vec(i.toDouble(), 0.0)];
      for (final (i, j, k) in triangulate(collinear)) {
        final a = collinear[i];
        final b = collinear[j];
        final c = collinear[k];
        final area = ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
            .abs();
        expect(area, lessThan(1e-9));
      }
    });

    test('clearance wierzchołka = odległość do najbliższego generatora', () {
      final rng = math.Random(5);
      final pts = [
        for (var i = 0; i < 40; i++)
          Vec(rng.nextDouble() * 100.0, rng.nextDouble() * 100.0),
      ];
      final graph = voronoiEdges(pts, triangulate(pts));
      for (var i = 0; i < graph.vertices.length; i++) {
        var nearest = double.infinity;
        for (final p in pts) {
          nearest = math.min(nearest, dist(graph.vertices[i], p));
        }
        expect(graph.clearance[i], closeTo(nearest, 1e-6));
      }
    });

    test('generatory krawędzi są równo oddalone od jej końców', () {
      final rng = math.Random(17);
      final pts = [
        for (var i = 0; i < 30; i++)
          Vec(rng.nextDouble() * 100.0, rng.nextDouble() * 100.0),
      ];
      final graph = voronoiEdges(pts, triangulate(pts));
      expect(graph.edges.length, graph.generators.length);
      for (var i = 0; i < graph.edges.length; i++) {
        final (a, b) = graph.edges[i];
        final (ga, gb) = graph.generators[i];
        for (final v in [graph.vertices[a], graph.vertices[b]]) {
          expect(dist(v, pts[ga]), closeTo(dist(v, pts[gb]), 1e-6));
        }
      }
    });
  });

  group('brak przejścia', () {
    test('gęsta zapora: przejście poniżej wymaganego odstępu', () {
      final poly = [
        const Vec(0.0, 0.0),
        const Vec(200.0, 0.0),
        const Vec(200.0, 100.0),
        const Vec(0.0, 100.0),
      ];
      final mines = [for (var y = 2; y < 99; y += 4) Vec(100.0, y.toDouble())];
      final f = Minefield.fromXy(poly, mines, 'west');
      final cfg = VoronoiConfig(bodyClearance: 10.0, wallMineSpacing: 5.0);
      final sol = solve(f, cfg);
      expect(
        sol.found,
        isTrue,
        reason: 'po krawędziach Woronoja da się przejść',
      );
      expect(
        sol.safe(cfg),
        isFalse,
        reason:
            'odstęp ${sol.clearance.toStringAsFixed(2)} m nie powinien '
            'spełniać progu 10 m',
      );
    });

    test('blastRadius podnosi próg, nie zmienia geometrii', () {
      final f = makeField();
      final a = solve(
        f,
        VoronoiConfig(
          blastRadius: 0.0,
          bodyClearance: 2.0,
          wallMineSpacing: 8.0,
        ),
      );
      final b = solve(
        f,
        VoronoiConfig(
          blastRadius: 30.0,
          bodyClearance: 2.0,
          wallMineSpacing: 8.0,
        ),
      );
      expect(a.clearance, closeTo(b.clearance, 1e-9));
      expect(
        a.safe(VoronoiConfig(blastRadius: 0.0, bodyClearance: 2.0)),
        isTrue,
      );
      expect(
        b.safe(VoronoiConfig(blastRadius: 30.0, bodyClearance: 2.0)),
        isFalse,
      );
    });

    test('puste pole daje prostą', () {
      final poly = rectangle(100.0, 100.0);
      final f = Minefield.fromXy(poly, const [], 'south');
      final sol = solve(f, VoronoiConfig(wallMineSpacing: 200.0));
      expect(sol.found, isTrue);
    });

    test('za mało generatorów: prosta przez środki krawędzi', () {
      final poly = const [Vec(0.0, 0.0), Vec(100.0, 0.0), Vec(50.0, 100.0)];
      final f = Minefield.fromXy(poly, const []);
      final sol = solve(f, VoronoiConfig(wallMineSpacing: 1e9));
      expect(sol.found, isTrue);
      expect(sol.path.length, 2);
      expect(sol.path.first, const Vec(50.0, 0.0));
      expect(sol.reason, contains('za mało przeszkód'));
      expect(sol.timingsMs, isEmpty);
    });
  });

  group('konfiguracja pola', () {
    test('wybór boku po kierunku', () {
      final poly = rectangle(500.0, 300.0);
      final south = Minefield.fromXy(poly, const [], 'south');
      expect(south.startEdge.$1.y, 0.0);
      expect(south.startEdge.$2.y, 0.0);
      final west = Minefield.fromXy(poly, const [], 'west');
      expect(west.startEdge.$1.x, 0.0);
      expect(west.startEdge.$2.x, 0.0);
      expect(south.goalEdge.$1.y, 300.0);
    });

    test('Side.opposite', () {
      expect(Side.south.opposite, Side.north);
      expect(Side.east.opposite, Side.west);
      expect(Side.fromWire('WEST'), Side.west);
      expect(() => Side.fromWire('gdzieś'), throwsArgumentError);
    });

    test('bok startowy i docelowy muszą się różnić', () {
      final poly = rectangle(100.0, 100.0);
      expect(() => Minefield.fromXy(poly, const [], 0, 0), throwsArgumentError);
    });

    test('wielokąt jest normalizowany do CCW', () {
      final cw = rectangle(100.0, 100.0).reversed.toList();
      final f = Minefield.fromXy(cw, const [], 'south');
      expect(signedArea(f.polygon), greaterThan(0));
      final b = f.bounds();
      expect(b.minX, 0.0);
      expect(b.maxX, 100.0);
      expect(b.minY, 0.0);
      expect(b.maxY, 100.0);
    });

    test('wirtualne miny obsypują tylko boki poza startem i celem', () {
      final poly = rectangle(100.0, 100.0);
      final f = Minefield.fromXy(poly, const [], 'south');
      final wall = f.wallMines(VoronoiConfig(wallMineSpacing: 10.0));
      expect(wall, isNotEmpty);
      final (sa, sb) = f.startEdge;
      for (final p in wall) {
        expect(
          pointSegmentDistance(p, sa, sb) > 1e-9 ||
              p == sa ||
              p == sb ||
              (p.x == 0.0 || p.x == 100.0),
          isTrue,
        );
      }
      final sealed = f.wallMines(
        VoronoiConfig(wallMineSpacing: 10.0, sealAllSides: true),
      );
      expect(sealed.length, greaterThan(wall.length));
    });
  });

  group('VoronoiConfig', () {
    test('walidacja', () {
      expect(() => VoronoiConfig(blastRadius: -1.0), throwsArgumentError);
      expect(() => VoronoiConfig(bodyClearance: -1.0), throwsArgumentError);
      expect(() => VoronoiConfig(wallMineSpacing: 0.0), throwsArgumentError);
      expect(() => VoronoiConfig(smoothing: 'magia'), throwsArgumentError);
      expect(
        () => VoronoiConfig(smoothingClearanceRatio: 1.5),
        throwsArgumentError,
      );
      expect(
        () => VoronoiConfig(smoothingClearanceRatio: 0.0),
        throwsArgumentError,
      );
    });

    test('requiredClearance sumuje blastRadius i bodyClearance', () {
      expect(
        VoronoiConfig(blastRadius: 5.0, bodyClearance: 2.0).requiredClearance,
        7.0,
      );
    });

    test('smoothing "none" zostawia ścieżkę surową', () {
      final f = makeField();
      final sol = solve(
        f,
        VoronoiConfig(
          bodyClearance: 2.0,
          wallMineSpacing: 8.0,
          smoothing: 'none',
        ),
      );
      expect(sol.found, isTrue);
      expect(sol.path, sol.rawPath);
    });
  });

  group('projekcja', () {
    test('roundtrip lat/lon', () {
      const frame = LocalFrame(50.06, 19.94); // Kraków
      for (final p in const [
        (lat: 50.06, lon: 19.94),
        (lat: 50.065, lon: 19.95),
        (lat: 50.055, lon: 19.93),
      ]) {
        final xy = frame.toXy(p.lat, p.lon);
        final back = frame.toLatLon(xy.x, xy.y);
        expect(back.lat, closeTo(p.lat, 1e-9));
        expect(back.lon, closeTo(p.lon, 1e-9));
      }
    });

    test('skala jest metryczna', () {
      const frame = LocalFrame(50.0, 20.0);
      final xy = frame.toXy(50.0 + 1000.0 / 110540.0, 20.0);
      expect(xy.y, closeTo(1000.0, 0.5));
    });

    test('pole z GPS: solver działa, ścieżkę da się wyeksportować', () {
      const polyLatLon = <LatLon>[
        (lat: 50.0600, lon: 19.9400),
        (lat: 50.0600, lon: 19.9470),
        (lat: 50.0640, lon: 19.9470),
        (lat: 50.0640, lon: 19.9400),
      ];
      final frame = LocalFrame.fromPoints(polyLatLon);
      final minesXy = generateMines(
        frame.manyToXy(polyLatLon),
        60,
        seed: 3,
        minSpacing: 15.0,
        edgeMargin: 5.0,
      );
      final f = Minefield.fromLatLon(
        polyLatLon,
        frame.manyToLatLon(minesXy),
        'south',
      );
      final sol = solve(
        f,
        VoronoiConfig(bodyClearance: 2.0, wallMineSpacing: 8.0),
      );
      expect(sol.found, isTrue);
      expect(f.frame, isNotNull);

      final back = f.frame!.manyToLatLon(sol.path);
      for (final p in back) {
        expect(p.lat, inExclusiveRange(49.9, 50.2));
        expect(p.lon, inExclusiveRange(19.8, 20.1));
      }
    });

    test('pusta lista punktów nie ma układu lokalnego', () {
      expect(() => LocalFrame.fromPoints(const []), throwsArgumentError);
    });
  });

  group('geometria', () {
    test('signedArea i asCcw', () {
      final ccw = rectangle(10.0, 4.0);
      expect(signedArea(ccw), closeTo(40.0, 1e-9));
      expect(signedArea(ccw.reversed.toList()), closeTo(-40.0, 1e-9));
      expect(asCcw(ccw.reversed.toList()), ccw);
    });

    test('pointSegmentDistance liczy rzut i końce', () {
      const a = Vec(0.0, 0.0);
      const b = Vec(10.0, 0.0);
      expect(
        pointSegmentDistance(const Vec(5.0, 3.0), a, b),
        closeTo(3.0, 1e-9),
      );
      expect(
        pointSegmentDistance(const Vec(-4.0, 0.0), a, b),
        closeTo(4.0, 1e-9),
      );
      expect(
        pointSegmentDistance(const Vec(1.0, 1.0), a, a),
        closeTo(math.sqrt2, 1e-9),
      );
    });

    test('sampleSegment kończy się przed punktem b', () {
      final pts = sampleSegment(const Vec(0.0, 0.0), const Vec(10.0, 0.0), 3.0);
      expect(pts.length, 4);
      expect(pts.first, const Vec(0.0, 0.0));
      expect(pts.last.x, closeTo(7.5, 1e-9));
      expect(sampleSegment(const Vec(1.0, 1.0), const Vec(1.0, 1.0), 3.0), [
        const Vec(1.0, 1.0),
      ]);
    });

    test('segmentInPolygon odrzuca wyjście poza wielokąt', () {
      final poly = [
        const Vec(0.0, 0.0),
        const Vec(10.0, 0.0),
        const Vec(10.0, 10.0),
        const Vec(5.0, 4.0),
        const Vec(0.0, 10.0),
      ];
      expect(
        segmentInPolygon(const Vec(1.0, 1.0), const Vec(9.0, 1.0), poly),
        isTrue,
      );
      expect(
        segmentInPolygon(const Vec(1.0, 9.0), const Vec(9.0, 9.0), poly),
        isFalse,
      );
    });

    test('segmentsIntersect obsługuje przypadki współliniowe', () {
      expect(
        segmentsIntersect(
          const Vec(0.0, 0.0),
          const Vec(10.0, 0.0),
          const Vec(5.0, -5.0),
          const Vec(5.0, 5.0),
        ),
        isTrue,
      );
      expect(
        segmentsIntersect(
          const Vec(0.0, 0.0),
          const Vec(10.0, 0.0),
          const Vec(5.0, 0.0),
          const Vec(15.0, 0.0),
        ),
        isTrue,
      );
      expect(
        segmentsIntersect(
          const Vec(0.0, 0.0),
          const Vec(1.0, 0.0),
          const Vec(2.0, 0.0),
          const Vec(3.0, 0.0),
        ),
        isFalse,
      );
    });

    test('polylineLength', () {
      expect(
        polylineLength(const [Vec(0.0, 0.0), Vec(3.0, 4.0), Vec(3.0, 8.0)]),
        closeTo(9.0, 1e-9),
      );
      expect(polylineLength(const [Vec(0.0, 0.0)]), 0.0);
    });
  });
}
