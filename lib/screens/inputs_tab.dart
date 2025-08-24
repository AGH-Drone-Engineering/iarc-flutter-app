// lib/screens/inputs_tab.dart
// Inputs tab with:
// 1) "Rotate map with compass" toggle (persisted via AppState)
// 2) 4× corner inputs
// 3) Per-row "use my location" buttons (kept)
// 4) Single point inputs + "use my location" button
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
  final List<TextEditingController> _latCtrls =
  List.generate(4, (_) => TextEditingController());
  final List<TextEditingController> _lonCtrls =
  List.generate(4, (_) => TextEditingController());

  // Single point controllers
  final TextEditingController _singleLatCtrl = TextEditingController();
  final TextEditingController _singleLonCtrl = TextEditingController();

  // Busy flags for “use my location” buttons
  final List<bool> _cornerBusy = List<bool>.filled(4, false);
  bool _singleBusy = false;

  @override
  void dispose() {
    for (final c in _latCtrls) c.dispose();
    for (final c in _lonCtrls) c.dispose();
    _singleLatCtrl.dispose();
    _singleLonCtrl.dispose();
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

  void _applyCorners(BuildContext context) {
    final app = context.read<AppState>();
    String buffer = 'Received coords: ';
    for (var i = 0; i < 4; i++) {
      final lat = double.tryParse(_latCtrls[i].text.trim());
      final lon = double.tryParse(_lonCtrls[i].text.trim());
      buffer += '[$lat, $lon]';
      if (i < 3) buffer += ", ";
      app.setCorner(i, (lat != null && lon != null) ? LatLng(lat, lon) : null);
    }
    logInfo(buffer);
  }

  void _applySinglePoint(BuildContext context) {
    final app = context.read<AppState>();
    final lat = double.tryParse(_singleLatCtrl.text.trim());
    final lon = double.tryParse(_singleLonCtrl.text.trim());
    if (lat != null && lon != null) {
      app.setSinglePoint(LatLng(lat, lon));
      logInfo('Single point set: [$lat, $lon]');
    } else {
      app.setSinglePoint(null);
      logWarn('Single point cleared (invalid input)');
    }
  }

  Future<void> _fillCornerFromLocation(int i) async {
    setState(() => _cornerBusy[i] = true);
    final p = await _getMyLatLng();
    if (p != null) {
      _latCtrls[i].text = p.latitude.toStringAsFixed(6);
      _lonCtrls[i].text = p.longitude.toStringAsFixed(6);
      _applyCorners(context); // immediately reflect on map/state + persist
    }
    if (mounted) setState(() => _cornerBusy[i] = false);
  }

  Future<void> _fillSingleFromLocation() async {
    setState(() => _singleBusy = true);
    final p = await _getMyLatLng();
    if (p != null) {
      _singleLatCtrl.text = p.latitude.toStringAsFixed(6);
      _singleLonCtrl.text = p.longitude.toStringAsFixed(6);
      _applySinglePoint(context); // update state + persist
    }
    if (mounted) setState(() => _singleBusy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    // Pre-fill corner fields from state (only if empty)
    for (var i = 0; i < 4; i++) {
      final c = app.corners[i];
      if (c != null) {
        if (_latCtrls[i].text.isEmpty) {
          _latCtrls[i].text = c.latitude.toStringAsFixed(6);
        }
        if (_lonCtrls[i].text.isEmpty) {
          _lonCtrls[i].text = c.longitude.toStringAsFixed(6);
        }
      }
    }
    // Pre-fill single point from state (only if empty)
    final sp = app.singlePoint;
    if (sp != null) {
      if (_singleLatCtrl.text.isEmpty) {
        _singleLatCtrl.text = sp.latitude.toStringAsFixed(6);
      }
      if (_singleLonCtrl.text.isEmpty) {
        _singleLonCtrl.text = sp.longitude.toStringAsFixed(6);
      }
    }

    Widget hereBtn({required bool busy, required VoidCallback onPressed}) {
      return SizedBox(
        width: 44,
        height: 44,
        child: busy
            ? const Padding(
          padding: EdgeInsets.all(10),
          child: CircularProgressIndicator(strokeWidth: 2),
        )
            : IconButton(
          tooltip: 'Use my location',
          onPressed: onPressed,
          icon: const Icon(Icons.my_location),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Rotate map preference (persists via AppState)
          SwitchListTile.adaptive(
            title: const Text('Rotate map with compass'),
            value: app.rotateWithCompass,
            onChanged: (v) => context.read<AppState>().setRotateWithCompass(v),
          ),

          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 12),

          Row(children: const [
            Expanded(child: Text('Enter 4 corner coordinates (lat, lon):')),
          ]),
          const SizedBox(height: 12),

          // 4× corner rows with "use my location"
          for (var i = 0; i < 4; i++) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latCtrls[i],
                    decoration: InputDecoration(
                      labelText: 'Lat ${i + 1}',
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
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                hereBtn(busy: _cornerBusy[i], onPressed: () => _fillCornerFromLocation(i)),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // Corner actions
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: () => _applyCorners(context),
                icon: const Icon(Icons.check_circle),
                label: const Text('Apply'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => context.read<AppState>().clearCorners(),
                icon: const Icon(Icons.clear),
                label: const Text('Clear'),
              ),
            ],
          ),

          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 12),

          Row(children: const [
            Expanded(child: Text('Single point (lat, lon):')),
          ]),
          const SizedBox(height: 12),

          // Single point row with "use my location"
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _singleLatCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Lat',
                    border: OutlineInputBorder(),
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
                  controller: _singleLonCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Lon',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              hereBtn(busy: _singleBusy, onPressed: _fillSingleFromLocation),
            ],
          ),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => _applySinglePoint(context),
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Apply Point'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => context.read<AppState>().clearSinglePoint(),
                icon: const Icon(Icons.location_off),
                label: const Text('Clear Point'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
