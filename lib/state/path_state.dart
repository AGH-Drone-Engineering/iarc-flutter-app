import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../pathfinding/field_grid.dart';
import '../pathfinding/grid_path.dart';
import '../pathfinding/grid_solver.dart';
import '../pathfinding/scenarios.dart';
import '../pathfinding/solver_isolate.dart';
import 'app_state.dart';

/// Skąd brać pole i miny.
enum PathSource {
  /// Narożniki i miny zebrane przez drony.
  live,

  /// Wbudowany scenariusz -- do obejrzenia solvera bez lotu.
  scenario,
}

/// Stan zakładki wyznaczania ścieżki.
///
/// Liczenie *nie* rusza automatycznie przy każdej nowej minie z radia: pełne
/// pole 40x150 zajmuje kilkaset milisekund, więc przeliczanie w tle przy
/// każdym pakiecie zacinałoby mapę. Zamiast tego wynik jest oznaczany jako
/// nieaktualny, a operator naciska przycisk.
class PathState extends ChangeNotifier {
  PathState(this._app) {
    _app.addListener(_onAppChanged);
  }

  final AppState _app;

  PathSource _source = PathSource.scenario;
  Scenario _scenario = builtInScenarios.first;
  double _scanMinutes = 0.0;
  double _overweightOz = 0.0;
  int _maxGreen = maxGreenSquares;
  int _mineInflation = 1;
  GreenZoneShape _shape = GreenZoneShape.manhattan;
  bool? _officialGridOverride;

  bool _computing = false;
  bool _stale = true;
  MappedField? _mapped;
  GridSolution? _solution;
  String? _error;
  int _elapsedMs = 0;

  PathSource get source => _source;
  Scenario get scenario => _scenario;
  double get scanMinutes => _scanMinutes;
  double get overweightOz => _overweightOz;
  int get maxGreen => _maxGreen;
  int get mineInflation => _mineInflation;
  GreenZoneShape get shape => _shape;
  /// Czy pokryć pole wymuszoną siatką 40 x 150, czy komórkami 2x2 stopy.
  ///
  /// Domyślnie AUTOMATYCZNIE, z wymiarów pola ([fieldMatchesOfficial]): pole
  /// zawodowe dostaje 40 x 150, bo tylko taka siatka daje `path.txt` zgodny ze
  /// scorerem; pole testowe wzięte z losowych współrzędnych dostaje prawdziwe
  /// kwadraty 2x2 stopy, bo wymuszona siatka rozciągnęłaby komórkę do cienkiego
  /// prostokąta i widok przestałby cokolwiek znaczyć.
  ///
  /// Operator może to nadpisać w obie strony ([setOfficialGrid]).
  bool get officialGrid =>
      _officialGridOverride ?? fieldMatchesOfficial(corners);

  /// Czy tryb siatki wybrał się sam, czy został narzucony.
  bool get officialGridIsAuto => _officialGridOverride == null;

  /// Czy `path.txt` z tej siatki da się oddać sędziom.
  ///
  /// Tylko siatka 40 x 150 jest siatką scorera. W trybie kwadratów ścieżka może
  /// mieć więcej niż 40 kolumn albo inną liczbę wierszy, więc plik jest do
  /// debugowania, nie do oddania - i UI musi to mówić, zamiast pozwolić komuś
  /// odkryć to przy sędziowskim stole.
  bool get pathTxtIsSubmittable => officialGrid;

  bool get computing => _computing;

  /// Czy wejście zmieniło się od ostatniego liczenia.
  bool get stale => _stale;

  MappedField? get mapped => _mapped;
  GridSolution? get solution => _solution;
  String? get error => _error;
  int get elapsedMs => _elapsedMs;

  Score? get score => _solution?.result;
  GridPath? get path => _solution?.path;

  List<LatLng> get corners =>
      _source == PathSource.scenario ? _scenario.corners : _app.orderedCorners;

  List<LatLng> get mines => _source == PathSource.scenario
      ? _scenario.mines
      : [for (final m in _app.mines) m.position];

  /// Prostokąty skanu. Scenariusze nie mają skanów -- pole jest tam z definicji
  /// w pełni rozpoznane, bo miny są znane z góry.
  List<ScanRegion> get scans =>
      _source == PathSource.scenario ? const [] : _app.scans;

  LatLng? get observer =>
      _source == PathSource.scenario ? _scenario.observer : _app.userLocation;

  /// Czy jest z czego liczyć.
  bool get ready => corners.length >= 3;

  ScoreParams get params => ScoreParams(
    scanMinutes: _scanMinutes,
    overweightOz: _overweightOz,
    shape: _shape,
    mineInflation: _mineInflation,
  );

  void _onAppChanged() {
    if (_source == PathSource.live) _markStale();
  }

  void _markStale() {
    if (_stale) return;
    _stale = true;
    notifyListeners();
  }

  void _set(void Function() change) {
    change();
    _stale = true;
    notifyListeners();
  }

  set source(PathSource value) => _set(() => _source = value);
  set scenario(Scenario value) => _set(() {
    _scenario = value;
    _source = PathSource.scenario;
  });
  set scanMinutes(double value) => _set(() => _scanMinutes = value);
  set overweightOz(double value) => _set(() => _overweightOz = value);
  set maxGreen(int value) => _set(() => _maxGreen = value);
  set mineInflation(int value) => _set(() => _mineInflation = value);
  set shape(GreenZoneShape value) => _set(() => _shape = value);
  /// ``null`` wraca do wyboru automatycznego.
  void setOfficialGrid(bool? value) =>
      _set(() => _officialGridOverride = value);

  /// Wyznacza ścieżkę. Cała robota idzie do osobnego izolatu.
  Future<void> compute() async {
    if (_computing) return;
    if (!ready) {
      _error = 'potrzebne są cztery narożniki pola';
      notifyListeners();
      return;
    }

    _computing = true;
    _error = null;
    notifyListeners();

    final watch = Stopwatch()..start();
    try {
      final plan = await planPathInBackground(
        corners: corners,
        mines: mines,
        scans: scans,
        observer: observer,
        officialGrid: officialGrid,
        params: params,
        cfg: SolverConfig(maxGreen: _maxGreen),
      );
      _mapped = plan.mapped;
      _solution = plan.solution;
      _stale = false;
    } catch (e) {
      _error = '$e';
      _mapped = null;
      _solution = null;
    } finally {
      _elapsedMs = watch.elapsedMilliseconds;
      _computing = false;
      notifyListeners();
    }
  }

  /// Zawartość pliku path.txt do oddania sędziom.
  String? get pathTxt => _solution?.path?.toText();

  @override
  void dispose() {
    _app.removeListener(_onAppChanged);
    super.dispose();
  }
}
