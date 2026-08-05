/// Zgodność portu Dart z referencyjną implementacją w Pythonie.
///
/// Referencja (`minefield_path/`) jest sprawdzona przeglądem zupełnym na małych
/// polach; tutaj tylko pilnujemy, żeby port nie odjechał. Dane generuje
/// `minefield_path/tools/gen_dart_fixtures.py`.
///
/// Dwa rodzaje przypadków, bo mają różną moc:
///
/// * `scoring` -- pole plus konkretna ścieżka. Wynik jest jednoznaczny, więc
///   sprawdzamy każdą składową.
/// * `solving` -- samo pole. Optimum bywa osiągane przez kilka różnych ścieżek,
///   więc porównujemy *wartość* wyniku, a nie przebieg. Inaczej test pilnowałby
///   rozstrzygania remisów, a nie jakości solvera.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_esp_android_communication/pathfinding/grid_path.dart';
import 'package:flutter_esp_android_communication/pathfinding/grid_solver.dart';
import 'package:flutter_test/flutter_test.dart';

Set<Cell> _cells(dynamic raw) => {
  for (final pair in (raw as List)) Cell(pair[0] as int, pair[1] as int),
};

GridField _field(Map<String, dynamic> spec) => GridField(
  cols: spec['cols'] as int,
  rows: spec['rows'] as int,
  mines: _cells(spec['mines']),
  outside: _cells(spec['outside']),
);

ScoreParams _params(Map<String, dynamic> spec) => ScoreParams(
  scanMinutes: ((spec['scanMinutes'] ?? 0) as num).toDouble(),
  overweightOz: ((spec['overweightOz'] ?? 0) as num).toDouble(),
  shape: GreenZoneShape.byName(spec['zone'] as String),
  mineInflation: spec['mineInflation'] as int,
);

void main() {
  final file = File('test/fixtures/grid_fixtures.json');
  final fixtures = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  group('wynik zgodny z referencją', () {
    for (final raw in fixtures['scoring'] as List) {
      final spec = raw as Map<String, dynamic>;
      final expected = spec['expected'] as Map<String, dynamic>;

      test(spec['name'] as String, () {
        final result = scoreGridPath(
          _field(spec),
          GridPath.parse(spec['pathTxt'] as String),
          _params(spec),
        );

        expect(result.valid, expected['valid'] as bool);
        expect(result.steps, expected['steps'] as int);
        expect(result.green, expected['green'] as int);
        expect(result.missed, expected['missed'] as int);
        expect(result.minesOnPath, expected['minesOnPath'] as int);
        expect(result.lengthFt, closeTo(expected['lengthFt'] as num, 1e-9));
        expect(result.widthFt, closeTo(expected['widthFt'] as num, 1e-9));
        expect(result.value, closeTo(expected['value'] as num, 1e-6));
        expect(result.zoneCells, _cells(expected['zoneCells']));
      });
    }
  });

  group('solver zgodny z referencją', () {
    for (final raw in fixtures['solving'] as List) {
      final spec = raw as Map<String, dynamic>;
      final expected = spec['expected'] as Map<String, dynamic>;

      test(spec['name'] as String, () {
        final field = _field(spec);
        final params = _params(spec);
        final solution = solveGrid(
          field,
          params: params,
          cfg: SolverConfig(
            maxGreen: spec['maxGreen'] as int,
            maxLateral: spec['maxLateral'] as int,
            refine: spec['refine'] as bool,
          ),
        );

        expect(solution.found, expected['found'] as bool, reason: solution.reason);
        if (!solution.found) return;

        expect(
          solution.result!.value,
          closeTo(expected['value'] as num, 1e-6),
          reason:
              'Dart ${solution.path!.toText().replaceAll('\n', ' ')} vs '
              'Python ${(expected['pathTxt'] as String).replaceAll('\n', ' ')}',
        );

        final rescored = scoreGridPath(field, solution.path!, params);
        expect(rescored.value, closeTo(solution.result!.value, 1e-9));
        expect(rescored.valid, isTrue);
        expect(rescored.minesOnPath, 0);
        expect(rescored.steps, solution.path!.cells().length);
      });
    }
  });

  group('kotwice wprost z spec.txt', () {
    test('S,0,0 + U,150 przechodzi całe pole w 150 krokach', () {
      final result = scoreGridPath(
        GridField.official(),
        GridPath.parse('S,0,0\nU,150\n'),
        const ScoreParams(mineInflation: 0),
      );
      expect(result.steps, 150);
      expect(result.lengthFt, 300.0);
      expect(result.widthFt, 2.0);
      expect(result.valid, isTrue);
    });

    test('S,20,2 daje W = 10 stóp', () {
      final result = scoreGridPath(
        GridField.official(),
        GridPath.parse('S,20,2\nU,150\n'),
        const ScoreParams(mineInflation: 0),
      );
      expect(result.widthFt, 10.0);
    });

    test('path.txt zapisuje się z powrotem bez zmian', () {
      const text = 'S,27,2\nU,9\nL,1\nU,5\nR,4\nD,3\n';
      expect(GridPath.parse(text).toText(), text);
    });
  });
}
