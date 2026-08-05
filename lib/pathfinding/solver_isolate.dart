/// Uruchamianie solverów poza wątkiem UI.
///
/// Wyznaczenie ścieżki na pełnym polu 40x150 zajmuje kilkaset milisekund, a
/// przy pustym polu nawet ponad pół sekundy -- dość, żeby zaciąć animacje.
/// Dlatego liczy się to w osobnym izolacie i tylko na żądanie, nie przy każdej
/// nowej minie z radia.
library;

import 'dart:isolate';

import 'package:latlong2/latlong.dart';

import 'field_grid.dart';
import 'grid_path.dart';
import 'grid_solver.dart';

/// Siatka plus ścieżka -- jedno wywołanie, bo i tak zawsze idą razem.
class GridPlan {
  const GridPlan({required this.mapped, required this.solution});

  final MappedField mapped;
  final GridSolution solution;
}

/// Buduje siatkę z narożników i min, a potem wyznacza ścieżkę.
///
/// Oba kroki w jednym izolacie: maskowanie komórek też potrafi kosztować
/// kilkanaście milisekund, a rozdzielanie ich na dwa przeskoki między izolatami
/// kosztowałoby więcej niż oszczędza.
Future<GridPlan> planPathInBackground({
  required List<LatLng> corners,
  required List<LatLng> mines,
  List<ScanRegion> scans = const [],
  LatLng? observer,
  bool officialGrid = true,
  bool fixCorners = true,
  ScoreParams params = const ScoreParams(),
  SolverConfig cfg = const SolverConfig(),
}) => Isolate.run(() {
  final mapped = mapField(
    corners: corners,
    mines: mines,
    scans: scans,
    observer: observer,
    grid: officialGrid ? officialGridSize : null,
    fixCorners: fixCorners,
  );
  return GridPlan(
    mapped: mapped,
    solution: solveGrid(mapped.field, params: params, cfg: cfg),
  );
});
