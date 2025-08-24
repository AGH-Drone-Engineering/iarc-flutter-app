import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    for (final c in _latCtrls) {
      c.dispose();
    }
    for (final c in _lonCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _applyToState(BuildContext context) {
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

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    // Pre-fill text fields when state already has values
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                  child: Text('Enter 4 corner coordinates (lat, lon):'))
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < 4; i++) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latCtrls[i],
                    decoration: InputDecoration(
                        labelText: 'Lat ${i + 1}',
                        border: const OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _lonCtrls[i],
                    decoration: InputDecoration(
                        labelText: 'Lon ${i + 1}',
                        border: const OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: () => _applyToState(context),
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
        ],
      ),
    );
  }
}
