/// Pokrycie skanem: co znaczy „przeskanowane" i co z tego wynika dla ścieżki.
///
/// Sedno: „nie ma tu miny" i „nikt tu nie patrzył" to dwie różne rzeczy.
/// Komórka jest znana dopiero przy pełnym pokryciu albo gdy znaleziono w niej
/// minę; reszta jest nieprzejezdna, ale *nie* wchodzi do B.
library;

import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/pathfinding/field_grid.dart';
import 'package:flutter_esp_android_communication/pathfinding/grid_path.dart';
import 'package:flutter_esp_android_communication/pathfinding/grid_solver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const base = LatLng(50.0629750, 19.9157000);

/// Małe pole, żeby dało się o nim myśleć: 10 x 20 komórek po 2 stopy.
MappedField build({
  List<ScanRegion> scans = const [],
  List<LatLng> mines = const [],
}) {
  const width = 10 * cellMeters;
  const depth = 20 * cellMeters;
  final metersPerDegLat = 110540.0;
  final metersPerDegLon = 111320.0 * 0.6414; // cos(50.06 stopnia)

  LatLng at(double u, double v) => LatLng(
    base.latitude + v / metersPerDegLat,
    base.longitude + u / metersPerDegLon,
  );

  return mapField(
    corners: [at(0, 0), at(width, 0), at(width, depth), at(0, depth)],
    mines: mines,
    scans: scans,
    observer: at(width / 2, -5),
    grid: (10, 20),
  );
}

ScanRegion wholeField() {
  final probe = build();
  return ScanRegion(probe.polygon[0], probe.polygon[2]);
}

void main() {
  group('komunikat SCAN', () {
    test('koduje się i wraca bez zmian', () {
      const message = ScanMessage(
        seq: 15,
        cornerA: LatLng(50.0629750, 19.9157000),
        cornerB: LatLng(50.0631570, 19.9158820),
      );
      final decoded = MissionMessage.decode(message.encode());
      expect(decoded, isA<ScanMessage>());
      final scan = decoded as ScanMessage;
      expect(scan.cornerA.latitude, closeTo(50.0629750, 1e-9));
      expect(scan.cornerB.longitude, closeTo(19.9158820, 1e-9));
      expect(scan.seq, 15);
    });

    test('mieści się w limicie 248 bajtów LoRa', () {
      const message = ScanMessage(
        seq: 65535,
        cornerA: LatLng(-50.0629750, -19.9157000),
        cornerB: LatLng(50.0631570, 19.9158820),
      );
      expect(message.encode().length, lessThan(248));
    });

    test('odrzuca narożnik, który nie jest parą [lat,lon]', () {
      expect(
        () =>
            MissionMessage.decode('{"v":1,"q":1,"t":"SCAN","a":[1],"b":[2,3]}'),
        throwsA(isA<MissionMessageException>()),
      );
    });
  });

  group('pokrycie komórek', () {
    test('bez żadnego SCAN pokrycie jest nieznane, nie zerowe', () {
      final mapped = build();
      expect(mapped.hasCoverage, isFalse);
      expect(mapped.field.unscanned, isEmpty);
    });

    test('skan całego pola czyni wszystkie komórki znanymi', () {
      final mapped = build(scans: [wholeField()]);
      expect(mapped.hasCoverage, isTrue);
      expect(mapped.field.unscanned, isEmpty);
      expect(mapped.scannedFraction, closeTo(1.0, 1e-9));
    });

    test('komórka pokryta częściowo nie liczy się jako znana', () {
      final probe = build();
      final half = ScanRegion(
        probe.polygon[0],
        probe.mapping.cellCenter(const Cell(9, 9)),
      );
      final mapped = build(scans: [half]);

      final partial = <Cell>[];
      for (var y = 0; y < 20; y++) {
        for (var x = 0; x < 10; x++) {
          final f = mapped.coverageOf(Cell(x, y));
          if (f > 0.0 && f < 1.0) partial.add(Cell(x, y));
        }
      }
      expect(
        partial,
        isNotEmpty,
        reason: 'brak komórek częściowych do sprawdzenia',
      );
      for (final cell in partial) {
        expect(mapped.field.unscanned, contains(cell));
      }
      expect(mapped.scannedFraction, greaterThan(0.0));
      expect(mapped.scannedFraction, lessThan(1.0));
    });

    test('nakładające się prostokąty sumują się, a nie zliczają dwa razy', () {
      final whole = wholeField();
      final once = build(scans: [whole]);
      final twice = build(scans: [whole, whole, whole]);
      expect(twice.scannedFraction, closeTo(once.scannedFraction, 1e-12));
      expect(twice.field.unscanned, once.field.unscanned);
    });

    test('komórka z miną jest znana, choćby jej nie pokrył żaden skan', () {
      final probe = build();
      final mine = probe.mapping.cellCenter(const Cell(5, 10));
      final corner = ScanRegion(probe.polygon[0], probe.polygon[0]);

      final mapped = build(scans: [corner], mines: [mine]);
      expect(mapped.field.mines, contains(const Cell(5, 10)));
      expect(mapped.field.unscanned, isNot(contains(const Cell(5, 10))));
    });
  });

  group('wpływ na ścieżkę', () {
    test('częściowe pokrycie tłumaczy, czego brakuje', () {
      final solution = solveGrid(
        GridField(
          cols: 10,
          rows: 20,
          unscanned: {for (var x = 0; x < 10; x++) Cell(x, 9)},
        ),
      );
      expect(solution.found, isFalse);
      expect(solution.reason, contains('% pola jeszcze'));
    });

    test('nieprzeskanowany teren blokuje ścieżkę', () {
      final mapped = build();
      final blocked = GridField(
        cols: mapped.field.cols,
        rows: mapped.field.rows,
        unscanned: {for (var y = 0; y < 20; y++) Cell(4, y)},
      );
      expect(blocked.blocked(), contains(const Cell(4, 3)));

      final solution = solveGrid(blocked);
      expect(solution.found, isTrue);
      expect(solution.path!.cells().any((c) => c.x == 4), isFalse);
    });

    test('bez żadnego skanu nie ma po czym poprowadzić ścieżki', () {
      final all = <Cell>{
        for (var y = 0; y < 20; y++)
          for (var x = 0; x < 10; x++) Cell(x, y),
      };
      final solution = solveGrid(GridField(cols: 10, rows: 20, unscanned: all));
      expect(solution.found, isFalse);
      expect(solution.reason, contains('nic nie zostało przeskanowane'));
    });

    test('nieznane komórki nie wchodzą do B, tylko raportują się osobno', () {
      final field = GridField(
        cols: 10,
        rows: 20,
        mines: {const Cell(7, 10)},
        unscanned: {for (var y = 0; y < 20; y++) Cell(8, y)},
      );
      final result = scoreGridPath(
        field,
        GridPath.parse('S,5,3\nU,20\n'),
        const ScoreParams(mineInflation: 0),
      );

      expect(result.valid, isTrue);
      expect(result.missed, 1, reason: 'mina w (7,10) jest potwierdzona');
      expect(
        result.unscannedInZone,
        20,
        reason: 'cała kolumna 8 jest nieznana',
      );
      expect(
        result.value,
        closeTo(150000.0 * 14.0 / (2 * 40.0), 1e-9),
        reason: 'nieznane komórki nie mogą zmieniać wyniku',
      );
    });

    test('ścieżka wiodąca przez nieznany teren jest odrzucana', () {
      final field = GridField(
        cols: 10,
        rows: 20,
        unscanned: {const Cell(5, 7)},
      );
      final result = scoreGridPath(field, GridPath.parse('S,5,0\nU,20\n'));
      expect(result.valid, isFalse);
      expect(result.reason, contains('nieprzeskanowany'));
    });
  });
}
