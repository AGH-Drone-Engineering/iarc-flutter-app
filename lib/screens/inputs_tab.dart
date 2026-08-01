import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../services/global_log.dart';
import '../state/app_state.dart';

class InputsTab extends StatefulWidget {
  const InputsTab({super.key});

  @override
  State<InputsTab> createState() => _InputsTabState();
}

class _InputsTabState extends State<InputsTab> {
  final _latCtrls = List.generate(4, (_) => TextEditingController());
  final _lonCtrls = List.generate(4, (_) => TextEditingController());
  final _cornerBusy = List<bool>.filled(4, false);

  @override
  void dispose() {
    for (final c in [..._latCtrls, ..._lonCtrls]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<LatLng?> _getMyLatLng() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied')),
          );
        }
        return null;
      }
    }
    try {
      final pos = await Geolocator.getCurrentPosition();
      return LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to get location: $e')),
        );
      }
      return null;
    }
  }

  void _applyCorners() {
    final app = context.read<AppState>();
    final parts = <String>[];
    for (var i = 0; i < 4; i++) {
      final lat = double.tryParse(_latCtrls[i].text.trim().replaceAll(',', '.'));
      final lon = double.tryParse(_lonCtrls[i].text.trim().replaceAll(',', '.'));
      app.setCorner(i, (lat != null && lon != null) ? LatLng(lat, lon) : null);
      parts.add('[$lat, $lon]');
    }
    logInfo('Corners set: ${parts.join(", ")}');
  }

  void _clearCorners() {
    for (var i = 0; i < 4; i++) {
      _latCtrls[i].clear();
      _lonCtrls[i].clear();
    }
    context.read<AppState>().clearCorners();
  }

  Future<void> _fillCornerFromLocation(int i) async {
    setState(() => _cornerBusy[i] = true);
    final p = await _getMyLatLng();
    if (p != null) {
      _latCtrls[i].text = p.latitude.toStringAsFixed(7);
      _lonCtrls[i].text = p.longitude.toStringAsFixed(7);
      _applyCorners();
    }
    if (mounted) setState(() => _cornerBusy[i] = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    for (var i = 0; i < 4; i++) {
      final c = app.corners[i];
      if (c == null) continue;
      if (_latCtrls[i].text.isEmpty) {
        _latCtrls[i].text = c.latitude.toStringAsFixed(7);
      }
      if (_lonCtrls[i].text.isEmpty) {
        _lonCtrls[i].text = c.longitude.toStringAsFixed(7);
      }
    }

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile.adaptive(
              title: const Text('Rotate map with compass'),
              value: app.rotateWithCompass,
              onChanged: app.setRotateWithCompass,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Field corners',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Any order — the app arranges them into a quadrilateral.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  for (var i = 0; i < 4; i++) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _latCtrls[i],
                            decoration: InputDecoration(
                              labelText: 'Lat ${i + 1}',
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              signed: true,
                              decimal: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _lonCtrls[i],
                            decoration: InputDecoration(
                              labelText: 'Lon ${i + 1}',
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              signed: true,
                              decimal: true,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: _cornerBusy[i]
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : IconButton(
                                  tooltip: 'Use my location',
                                  onPressed: () => _fillCornerFromLocation(i),
                                  icon: const Icon(Icons.my_location),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _applyCorners,
                          icon: const Icon(Icons.check_circle),
                          label: const Text('Apply'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _clearCorners,
                          icon: const Icon(Icons.clear),
                          label: const Text('Clear'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        app.hasFourCorners ? Icons.check_circle : Icons.error_outline,
                        size: 18,
                        color: app.hasFourCorners
                            ? Colors.green
                            : Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${app.filledCorners.length}/4 set',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
