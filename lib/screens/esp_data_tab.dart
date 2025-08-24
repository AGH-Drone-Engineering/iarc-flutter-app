// lib/screens/esp_data_tab.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../state/app_state.dart';
import '../widgets/voice_button.dart';

enum CommandOption {
  start,
  setAltitude, // requires numeric value (meters)
  flyForward,  // requires numeric value (meters)
  land,
}

class EspDataTab extends StatefulWidget {
  const EspDataTab({super.key});
  @override
  State<EspDataTab> createState() => _EspDataTabState();
}

class _EspDataTabState extends State<EspDataTab> {
  List<UsbDevice> _devices = [];
  UsbDevice? _selected;

  // Voice
  stt.SpeechToText? _speech;
  bool _speechAvailable = false;

  // Last heard phrase + parsed + confirmable command
  String _heardText = '';
  String? _parsedCmdString; // normalized string to send (e.g., "SET_ALTITUDE 50")
  String? _parseError;

  // Command dropdown + optional parameter
  CommandOption _cmd = CommandOption.start;
  final TextEditingController _paramCtrl = TextEditingController();

  Future<void> _refreshDevices(AppState app) async {
    _devices = await app.serial.listDevices();
    if (!mounted) return;
    setState(() {
      if (_devices.isNotEmpty) {
        _selected ??= _devices.first;
      } else {
        _selected = null;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Init device list
      _refreshDevices(context.read<AppState>());
      // Init speech engine
      final ok = await _speech!.initialize(onStatus: (_) {}, onError: (_) {});
      if (mounted) setState(() => _speechAvailable = ok);
    });
  }

  @override
  void dispose() {
    _paramCtrl.dispose();
    super.dispose();
  }

  bool get _requiresParam =>
      _cmd == CommandOption.setAltitude || _cmd == CommandOption.flyForward;

  String get _paramLabel =>
      _cmd == CommandOption.setAltitude ? 'Altitude (m)' : 'Distance (m)';

  // ---------- Helpers ----------

  String _fmtNumber(double v) {
    // nice compact formatting: 50.0 -> 50 ; 50.25 -> 50.25
    if (v == v.roundToDouble()) return v.toInt().toString();
    final s = v.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _buildCmdString(CommandOption c, [double? value]) {
    switch (c) {
      case CommandOption.start:
        return 'START';
      case CommandOption.setAltitude:
        return 'SET_ALTITUDE ${_fmtNumber(value ?? 0)}';
      case CommandOption.flyForward:
        return 'FLY_FORWARD ${_fmtNumber(value ?? 0)}';
      case CommandOption.land:
        return 'LAND';
    }
  }

  // Try parsing a natural voice phrase into a normalized command string.
  // Returns (cmdString, error). If cmdString is null, show the error.
  (String? cmdString, String? error) _parseVoiceToCommand(String phrase) {
    final text = phrase.toLowerCase().trim();

    // Regex helpers to pull a number if present
    double? _pullNumber(RegExp re) {
      final m = re.firstMatch(text);
      if (m != null && m.groupCount >= 1) {
        return double.tryParse(m.group(1)!.replaceAll(',', '.'));
      }
      return null;
    }

    // Order matters: parameterized commands first

    // Set altitude to X (meters)
    // Matches: "set altitude to 50", "altitude 100", "set alt 120 meters", "height 30"
    final altRe =
    RegExp(r'(?:set\s+)?(?:altitude|alt|height)\s*(?:to)?\s*(\d+(?:[\.,]\d+)?)');
    if (altRe.hasMatch(text)) {
      final v = _pullNumber(altRe);
      if (v == null) return (null, 'Could not read altitude value');
      return (_buildCmdString(CommandOption.setAltitude, v), null);
    }

    // Fly forward X (meters)
    // Matches: "fly forward 10", "go forward 5 meters", "forward 12"
    final fwdRe = RegExp(
        r'(?:(?:fly|go|move)\s+)?forward\s*(\d+(?:[\.,]\d+)?)(?:\s*(?:m|meter|meters))?');
    if (fwdRe.hasMatch(text)) {
      final v = _pullNumber(fwdRe);
      if (v == null) return (null, 'Could not read distance value');
      return (_buildCmdString(CommandOption.flyForward, v), null);
    }

    // Land
    if (RegExp(r'\b(land|touch\s*down|descend)\b').hasMatch(text)) {
      return (_buildCmdString(CommandOption.land), null);
    }

    // Start
    if (RegExp(r'\b(start|arm|begin)\b').hasMatch(text)) {
      return (_buildCmdString(CommandOption.start), null);
    }

    return (null, 'Unrecognized command');
    // You can expand with more synonyms if needed.
  }

  Future<void> _startVoiceCommand(AppState app) async {
    if (_speech == null) return;
    if (!_speechAvailable) {
      _speechAvailable = await _speech!.initialize();
      if (!_speechAvailable) return;
    }

    setState(() {
      _heardText = '';
      _parsedCmdString = null;
      _parseError = null;
    });

    await _speech!.listen(
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 2),
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
      ),
      onResult: (r) async {
        final text = r.recognizedWords.trim();
        if (!mounted) return;
        setState(() {
          _heardText = text;
          // Always attempt parsing so user sees live parse; only final will be used for sending
          final parsed = _parseVoiceToCommand(text);
          _parsedCmdString = parsed.$1;
          _parseError = parsed.$2;
        });
      },
    );
  }

  Future<void> _sendParsedVoice(AppState app) async {
    final s = _parsedCmdString;
    if (s == null || s.isEmpty) {
      _showSnack(_parseError ?? 'Nothing to send');
      return;
    }
    await app.serial.sendText('$s\n');
    _showSnack('Sent: $s');
    setState(() {
      _heardText = '';
      _parsedCmdString = null;
      _parseError = null;
    });
  }

  Future<void> _sendSelectedCommand(AppState app) async {
    switch (_cmd) {
      case CommandOption.start:
        await app.serial.sendText('${_buildCmdString(CommandOption.start)}\n');
        return;
      case CommandOption.setAltitude:
        final v = double.tryParse(_paramCtrl.text.trim());
        if (v == null) {
          _showSnack('Enter a valid altitude (meters).');
          return;
        }
        await app.serial.sendText('${_buildCmdString(CommandOption.setAltitude, v)}\n');
        return;
      case CommandOption.flyForward:
        final v = double.tryParse(_paramCtrl.text.trim());
        if (v == null) {
          _showSnack('Enter a valid distance (meters).');
          return;
        }
        await app.serial.sendText('${_buildCmdString(CommandOption.flyForward, v)}\n');
        return;
      case CommandOption.land:
        await app.serial.sendText('${_buildCmdString(CommandOption.land)}\n');
        return;
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Device picker + refresh
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<UsbDevice>(
                  isExpanded: true,
                  value: _selected,
                  hint: const Text('Select USB device'),
                  items: _devices.map((d) {
                    return DropdownMenuItem(
                      value: d,
                      child: Text(d.deviceName),
                    );
                  }).toList(),
                  onChanged: (d) => setState(() => _selected = d),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh devices',
                onPressed: () => _refreshDevices(app),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Connect/disconnect + status
          Row(
            children: [
              ElevatedButton.icon(
                onPressed:
                _selected == null ? null : () => app.serial.connect(_selected!),
                icon: const Icon(Icons.usb),
                label: const Text('Connect'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => app.serial.disconnect(),
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  app.connectionStatus,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Voice button + parsed/confirm UI
          VoiceButton(
            available: _speechAvailable,
            isListening: _speech?.isListening ?? false,
            onPressed: () => _startVoiceCommand(app),
            onLongPress: () => _startVoiceCommand(app), // optional push-to-talk
          ),
          const SizedBox(height: 8),
          if (_heardText.isNotEmpty || _parsedCmdString != null || _parseError != null)
            Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_heardText.isNotEmpty)
                      Text('Heard: $_heardText',
                          style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 6),
                    if (_parsedCmdString != null)
                      Text('Parsed as: $_parsedCmdString',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: Colors.green)),
                    if (_parseError != null)
                      Text(_parseError!,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: Colors.red)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          onPressed: () {
                            setState(() {
                              _heardText = '';
                              _parsedCmdString = null;
                              _parseError = null;
                            });
                          },
                          child: const Text('Clear'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed:
                          _parsedCmdString == null ? null : () => _sendParsedVoice(app),
                          icon: const Icon(Icons.send),
                          label: const Text('Send'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 16),

          // Dropdown of commands + conditional parameter input
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<CommandOption>(
                  value: _cmd,
                  items: const [
                    DropdownMenuItem(
                      value: CommandOption.start,
                      child: Text('Start'),
                    ),
                    DropdownMenuItem(
                      value: CommandOption.setAltitude,
                      child: Text('Set alt. to'),
                    ),
                    DropdownMenuItem(
                      value: CommandOption.flyForward,
                      child: Text('Fly forward'),
                    ),
                    DropdownMenuItem(
                      value: CommandOption.land,
                      child: Text('Land'),
                    ),
                  ],
                  onChanged: (c) {
                    if (c == null) return;
                    setState(() {
                      _cmd = c;
                      if (!_requiresParam) _paramCtrl.clear();
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Command',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_requiresParam)
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _paramCtrl,
                    decoration: InputDecoration(
                      labelText: _paramLabel,
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: false,
                      decimal: true,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Action buttons: send selected command + send coords
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => _sendSelectedCommand(app),
                icon: const Icon(Icons.send),
                label: const Text('Send Command'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => app.sendCornersToEsp(),
                icon: const Icon(Icons.share_location),
                label: const Text('Send Coords'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}