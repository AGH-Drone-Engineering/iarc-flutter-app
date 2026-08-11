import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart' as fmtc;
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/drone.dart';
import '../../pathfinding/scenarios.dart';
import '../../state/app_state.dart';
import '../../state/path_state.dart';
import '../../widgets/drone_visuals.dart';
import '../../widgets/grid_overlay_layer.dart';

/// Ścieżka zawodowa na siatce 2x2 stopy, narysowana na mapie.
class GridPathView extends StatefulWidget {
  const GridPathView({super.key});

  @override
  State<GridPathView> createState() => _GridPathViewState();
}

class _GridPathViewState extends State<GridPathView> {
  final _mapController = MapController();
  late final fmtc.FMTCTileProvider _tileProvider;
  bool _showSafeCells = true;
  bool _showScanRects = true;
  bool _followedResult = false;

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

  void _fitToField(List<LatLng> polygon) {
    if (polygon.isEmpty) return;
    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: polygon,
        padding: const EdgeInsets.all(32),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PathState>();
    final mapped = state.mapped;
    final score = state.score;

    if (mapped != null && !_followedResult) {
      _followedResult = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _fitToField(mapped.polygon),
      );
    }

    return Column(
      children: [
        _Controls(onFit: () => _fitToField(mapped?.polygon ?? state.corners)),
        Expanded(
          child: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: const MapOptions(
                  initialCenter: LatLng(50.063, 19.9157),
                  initialZoom: 17,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.esp_map',
                    tileProvider: _tileProvider,
                  ),
                  if (mapped != null)
                    PolygonLayer(
                      polygons: [
                        Polygon(
                          points: mapped.polygon,
                          borderColor: Colors.indigoAccent,
                          borderStrokeWidth: 2,
                          color: Colors.transparent,
                        ),
                      ],
                    ),
                  if (mapped != null)
                    GridOverlayLayer(
                      mapping: mapped.mapping,
                      field: mapped.field,
                      pathCells: score?.pathCells ?? const [],
                      zoneCells: score?.zoneCells ?? const {},
                      coverage: mapped.coverage,
                      showSafeCells: _showSafeCells,
                    ),
                  if (mapped != null)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: [mapped.frontEdge.$1, mapped.frontEdge.$2],
                          color: Colors.lightBlueAccent,
                          strokeWidth: 3,
                        ),
                        if (score != null && score.pathCells.isNotEmpty)
                          Polyline(
                            points: mapped.mapping.pathLatLng(score.pathCells),
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                      ],
                    ),
                  const _DroneAndUserLayer(),
                ],
              ),
              Positioned(
                right: 8,
                top: 8,
                child: _LayerToggle(
                  showSafeCells: _showSafeCells,
                  onSafeCells: (v) => setState(() => _showSafeCells = v),
                  showScanRects: _showScanRects,
                  onScanRects: state.scans.isEmpty
                      ? null
                      : (v) => setState(() => _showScanRects = v),
                ),
              ),
            ],
          ),
        ),
        _ResultPanel(onFit: () => _fitToField(mapped?.polygon ?? const [])),
      ],
    );
  }
}

class _DroneAndUserLayer extends StatelessWidget {
  const _DroneAndUserLayer();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return MarkerLayer(
      markers: [
        for (final drone in Drone.all)
          if (drone.position != null)
            Marker(
              point: drone.position!,
              width: 24,
              height: 24,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: drone.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black87, width: 2),
                ),
                child: Center(
                  child: Text(
                    '${drone.id}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: readableOn(drone.color),
                    ),
                  ),
                ),
              ),
            ),
        if (app.userLocation != null)
          Marker(
            point: app.userLocation!,
            width: 18,
            height: 18,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.blueAccent,
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                  BorderSide(color: Colors.black87, width: 2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _LayerToggle extends StatelessWidget {
  const _LayerToggle({
    required this.showSafeCells,
    required this.onSafeCells,
    required this.showScanRects,
    required this.onScanRects,
  });

  final bool showSafeCells;
  final ValueChanged<bool> onSafeCells;
  final bool showScanRects;
  final ValueChanged<bool>? onScanRects;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Bezpieczne'),
                Switch(value: showSafeCells, onChanged: onSafeCells),
              ],
            ),
            if (onScanRects != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Skany'),
                  Switch(value: showScanRects, onChanged: onScanRects),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.onFit});

  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PathState>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<PathSource>(
                  segments: const [
                    ButtonSegment(
                      value: PathSource.live,
                      label: Text('Z dronów'),
                      icon: Icon(Icons.sensors, size: 18),
                    ),
                    ButtonSegment(
                      value: PathSource.scenario,
                      label: Text('Scenariusz'),
                      icon: Icon(Icons.science_outlined, size: 18),
                    ),
                  ],
                  selected: {state.source},
                  onSelectionChanged: (s) => state.source = s.first,
                ),
              ),
              IconButton(
                tooltip: 'Dopasuj widok do pola',
                onPressed: onFit,
                icon: const Icon(Icons.fit_screen),
              ),
            ],
          ),
          if (state.source == PathSource.scenario) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<Scenario>(
              initialValue: state.scenario,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Scenariusz',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final s in builtInScenarios)
                  DropdownMenuItem(
                    value: s,
                    child: Text(
                      '${s.name}  ·  ${s.mines.length} min',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (s) {
                if (s != null) state.scenario = s;
              },
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                state.scenario.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${state.corners.length}/4 narożników, '
                '${state.mines.length} min z dronów',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          const _GridModePicker(),
          const SizedBox(height: 8),
          const _SolveButton(),
        ],
      ),
    );
  }
}

/// Którą siatką pokryć pole. Wybiera się sam; da się nadpisać.
///
/// Istnieje, bo bez tego stan `officialGrid` nie miał żadnej kontrolki i siedział
/// na `true`: każde pole testowe wzięte z losowych współrzędnych było dzielone na
/// dokładnie 40 x 150 części, więc komórka rozciągała się do cienkiego prostokąta
/// (na polu 400 x 90 m: 10 x 0.6 m). Widok pokazywał wtedy paski, a nie kwadraty
/// 2x2 stopy, po których naprawdę idzie się przez pole.
class _GridModePicker extends StatelessWidget {
  const _GridModePicker();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PathState>();
    final official = state.officialGrid;
    final auto = state.officialGridIsAuto;
    final cell = state.mapped?.mapping;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool?>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: null,
              label: Text('Auto'),
              icon: Icon(Icons.auto_awesome, size: 16),
            ),
            ButtonSegment(
              value: true,
              label: Text('40 x 150'),
              icon: Icon(Icons.emoji_events_outlined, size: 16),
            ),
            ButtonSegment(
              value: false,
              label: Text('2 ft'),
              icon: Icon(Icons.grid_4x4, size: 16),
            ),
          ],
          selected: {auto ? null : official},
          onSelectionChanged: (s) => state.setOfficialGrid(s.first),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            [
              if (official)
                'Siatka zawodowa: pole dzielone na dokładnie 40 x 150 komórek, '
                    'żeby path.txt trafił w siatkę sędziowską.'
              else
                'Kwadraty 2x2 stopy, liczba komórek z pomiaru. Do debugowania - '
                    'path.txt z tej siatki NIE jest siatką scorera.',
              if (auto) 'Wybrane automatycznie z wymiarów pola.',
              if (cell != null)
                'Komórka ${cell.cellU.toStringAsFixed(2)} x '
                    '${cell.cellV.toStringAsFixed(2)} m.',
            ].join(' '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: official
                      ? null
                      : Theme.of(context).colorScheme.tertiary,
                ),
          ),
        ),
      ],
    );
  }
}

class _SolveButton extends StatelessWidget {
  const _SolveButton();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PathState>();

    if (state.computing) {
      return FilledButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: const Text('Liczę…'),
      );
    }

    final label = state.solution == null
        ? 'Wyznacz ścieżkę'
        : state.stale
        ? 'Przelicz (dane się zmieniły)'
        : 'Przelicz';

    return FilledButton.icon(
      onPressed: state.ready ? state.compute : null,
      icon: Icon(state.stale ? Icons.refresh : Icons.route),
      label: Text(label),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.onFit});

  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PathState>();
    final theme = Theme.of(context);

    if (state.error != null) {
      return _Banner(
        icon: Icons.error_outline,
        color: theme.colorScheme.errorContainer,
        text: state.error!,
      );
    }

    final solution = state.solution;
    if (solution == null) {
      return const _Banner(
        icon: Icons.info_outline,
        text: 'Wybierz źródło danych i naciśnij „Wyznacz ścieżkę”.',
      );
    }
    if (!solution.found) {
      return _Banner(
        icon: Icons.block,
        color: theme.colorScheme.errorContainer,
        text: solution.reason,
      );
    }

    final score = solution.result!;
    final warnings = state.mapped?.warnings ?? const <String>[];

    return Material(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  score.value.toStringAsFixed(0),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Text('punktów', style: theme.textTheme.bodySmall),
                const Spacer(),
                Text('${state.elapsedMs} ms', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _Stat('G', '${score.green}'),
                _Stat('W', '${score.widthFt.toStringAsFixed(0)} ft'),
                _Stat('L', '${score.lengthFt.toStringAsFixed(0)} ft'),
                _Stat('kroki', '${score.steps}'),
                _Stat('B', '${score.missed}', alert: score.missed > 0),
                if (score.minesOnPath > 0)
                  _Stat('na ścieżce', '${score.minesOnPath}', alert: true),
              ],
            ),
            if (score.unscannedInZone > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '\${score.unscannedInZone} komórek strefy zielonej nie zostało '
                  'przeskanowanych. Nie wchodzą do B, więc ten wynik obowiązuje '
                  'tylko, o ile ten teren jest czysty.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (score.minesOnPath > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  score.reason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(warning, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copy(context, state.pathTxt),
                    icon: const Icon(Icons.copy_all, size: 18),
                    label: const Text('Kopiuj path.txt'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Pokaż path.txt',
                  onPressed: () => _showPath(context, state.pathTxt),
                  icon: const Icon(Icons.description_outlined),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _copy(BuildContext context, String? text) {
    if (text == null) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('path.txt skopiowany do schowka')),
    );
  }

  void _showPath(BuildContext context, String? text) {
    if (text == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('path.txt'),
        content: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zamknij'),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.alert = false});

  final String label;
  final String value;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = alert
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: readableOn(background),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final background =
        color ?? Theme.of(context).colorScheme.surfaceContainerHighest;
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: readableOn(background)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: readableOn(background)),
            ),
          ),
        ],
      ),
    );
  }
}
