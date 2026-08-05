import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart' as fmtc;
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../pathfinding/voronoi/config.dart';
import '../../pathfinding/voronoi/geometry.dart' as geo;
import '../../pathfinding/voronoi/minefield.dart';
import '../../pathfinding/voronoi/voronoi_solver.dart' as voronoi;
import '../../state/path_state.dart';
import '../../widgets/drone_visuals.dart';

/// Ścieżka maksymalizująca odstęp od najbliższej miny, w przestrzeni ciągłej.
///
/// To *nie* jest ścieżka punktowana. Wzór z spec.txt płaci za szerokość strefy
/// zielonej i karze za długość, więc trasa o największym odstępie regularnie
/// przegrywa punktowo z krótszą. Ten widok odpowiada na inne pytanie: czy w
/// ogóle istnieje bezpieczny korytarz i gdzie jest najwęższe miejsce --
/// niezależnie od tego, jak pole zostało podzielone na komórki.
class ClearanceView extends StatefulWidget {
  const ClearanceView({super.key});

  @override
  State<ClearanceView> createState() => _ClearanceViewState();
}

class _ClearanceViewState extends State<ClearanceView> {
  final _mapController = MapController();
  late final fmtc.FMTCTileProvider _tileProvider;

  voronoi.VoronoiSolution? _solution;
  geo.LocalFrame? _frame;
  List<LatLng> _path = const [];
  List<LatLng> _rawPath = const [];
  bool _computing = false;
  String? _error;
  double _bodyClearance = 1.0;
  double _blastRadius = 0.0;
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    _tileProvider = fmtc.FMTCTileProvider(
      stores: const {'OSM': fmtc.BrowseStoreStrategy.readUpdateCreate},
    );
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _compute() async {
    final state = context.read<PathState>();
    final corners = state.corners;
    if (corners.length < 3) {
      setState(() => _error = 'potrzebne są cztery narożniki pola');
      return;
    }

    setState(() {
      _computing = true;
      _error = null;
    });

    try {
      final observer = state.observer;
      final field = Minefield.fromLatLon(
        [for (final c in corners) (lat: c.latitude, lon: c.longitude)],
        [for (final m in state.mines) (lat: m.latitude, lon: m.longitude)],
        _startSide(corners, observer),
      );
      final solution = voronoi.solve(
        field,
        VoronoiConfig(bodyClearance: _bodyClearance, blastRadius: _blastRadius),
      );
      final frame = field.frame!;

      setState(() {
        _solution = solution;
        _frame = frame;
        _path = _toLatLng(frame, solution.path);
        _rawPath = _toLatLng(frame, solution.rawPath);
      });

      if (_path.isNotEmpty) {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: [...corners, ..._path],
            padding: const EdgeInsets.all(32),
          ),
        );
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _computing = false);
    }
  }

  /// Bok wejściowy: ten najbliższy telefonowi, tak jak w widoku siatki.
  ///
  /// Bez tego solver bierze bok 0, czyli przypadkowy -- a wtedy „korytarz”
  /// biegnie w poprzek pola i nic nie znaczy.
  int _startSide(List<LatLng> corners, LatLng? observer) {
    if (observer == null) return 0;
    final frame = geo.LocalFrame.fromPoints([
      for (final c in corners) (lat: c.latitude, lon: c.longitude),
    ]);
    final poly = geo.asCcw(
      frame.manyToXy([
        for (final c in corners) (lat: c.latitude, lon: c.longitude),
      ]),
    );
    final me = frame.toXy(observer.latitude, observer.longitude);
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < poly.length; i++) {
      final d = geo.pointSegmentDistance(
        me,
        poly[i],
        poly[(i + 1) % poly.length],
      );
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  List<LatLng> _toLatLng(geo.LocalFrame frame, List<geo.Vec> points) => [
    for (final p in points)
      () {
        final ll = frame.toLatLon(p.x, p.y);
        return LatLng(ll.lat, ll.lon);
      }(),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PathState>();
    final solution = _solution;

    return Column(
      children: [
        _Controls(
          bodyClearance: _bodyClearance,
          blastRadius: _blastRadius,
          computing: _computing,
          onBodyClearance: (v) => setState(() => _bodyClearance = v),
          onBlastRadius: (v) => setState(() => _blastRadius = v),
          onCompute: state.ready ? _compute : null,
        ),
        Expanded(
          child: FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: LatLng(50.063, 19.9157),
              initialZoom: 17,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.esp_map',
                tileProvider: _tileProvider,
              ),
              if (state.corners.length >= 3)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: state.corners,
                      borderColor: Colors.indigoAccent,
                      borderStrokeWidth: 2,
                      color: Colors.indigo.withValues(alpha: 0.08),
                    ),
                  ],
                ),
              if (solution != null && _frame != null)
                CircleLayer(
                  circles: [
                    for (final mine in state.mines)
                      CircleMarker(
                        point: mine,
                        radius: _bodyClearance + _blastRadius,
                        useRadiusInMeter: true,
                        color: Colors.red.withValues(alpha: 0.18),
                        borderColor: Colors.redAccent,
                        borderStrokeWidth: 1,
                      ),
                  ],
                ),
              if (_rawPath.isNotEmpty && _showRaw)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _rawPath,
                      color: Colors.white54,
                      strokeWidth: 1.5,
                    ),
                  ],
                ),
              if (_path.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _path,
                      color: Colors.lightGreenAccent,
                      strokeWidth: 4,
                    ),
                  ],
                ),
            ],
          ),
        ),
        _Result(
          solution: solution,
          error: _error,
          required: _bodyClearance + _blastRadius,
          showRaw: _showRaw,
          onShowRaw: (v) => setState(() => _showRaw = v),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.bodyClearance,
    required this.blastRadius,
    required this.computing,
    required this.onBodyClearance,
    required this.onBlastRadius,
    required this.onCompute,
  });

  final double bodyClearance;
  final double blastRadius;
  final bool computing;
  final ValueChanged<double> onBodyClearance;
  final ValueChanged<double> onBlastRadius;
  final VoidCallback? onCompute;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _Slider(
                  label: 'Odstęp',
                  value: bodyClearance,
                  max: 10,
                  onChanged: onBodyClearance,
                ),
              ),
              Expanded(
                child: _Slider(
                  label: 'Rażenie',
                  value: blastRadius,
                  max: 20,
                  onChanged: onBlastRadius,
                ),
              ),
            ],
          ),
          FilledButton.icon(
            onPressed: computing ? null : onCompute,
            icon: computing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.social_distance),
            label: Text(computing ? 'Liczę…' : 'Wyznacz korytarz'),
          ),
        ],
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.value,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label ${value.toStringAsFixed(1)} m',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Slider(
          value: value,
          max: max,
          divisions: (max * 2).round(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.solution,
    required this.error,
    required this.required,
    required this.showRaw,
    required this.onShowRaw,
  });

  final voronoi.VoronoiSolution? solution;
  final String? error;
  final double required;
  final bool showRaw;
  final ValueChanged<bool> onShowRaw;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (error != null) {
      return _strip(context, theme.colorScheme.errorContainer, error!);
    }
    if (solution == null) {
      return _strip(
        context,
        theme.colorScheme.surfaceContainerHighest,
        'Naciśnij „Wyznacz korytarz”, żeby sprawdzić, czy istnieje bezpieczne '
        'przejście niezależnie od podziału na komórki.',
      );
    }
    if (!solution!.found) {
      return _strip(
        context,
        theme.colorScheme.errorContainer,
        solution!.reason,
      );
    }

    final safe = solution!.clearance >= required;
    final background = safe
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.errorContainer;

    return Material(
      elevation: 8,
      child: Container(
        width: double.infinity,
        color: background,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  safe
                      ? Icons.check_circle_outline
                      : Icons.warning_amber_rounded,
                  size: 18,
                  color: readableOn(background),
                ),
                const SizedBox(width: 6),
                Text(
                  'najwęziej ${solution!.clearance.toStringAsFixed(2)} m',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: readableOn(background),
                  ),
                ),
                const Spacer(),
                Text(
                  '${solution!.length.toStringAsFixed(0)} m',
                  style: TextStyle(color: readableOn(background)),
                ),
              ],
            ),
            Text(
              solution!.reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: readableOn(background),
              ),
            ),
            Row(
              children: [
                Text(
                  'Surowa trasa Woronoja',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: readableOn(background),
                  ),
                ),
                Switch(value: showRaw, onChanged: onShowRaw),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _strip(BuildContext context, Color background, String text) =>
      Container(
        width: double.infinity,
        color: background,
        padding: const EdgeInsets.all(12),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: readableOn(background)),
        ),
      );
}
