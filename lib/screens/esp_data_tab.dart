// lib/screens/esp_data_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter_esp_android_communication/models/message.dart';
import 'package:flutter_esp_android_communication/services/global_log.dart';
import 'package:flutter_esp_android_communication/widgets/drone_status_tile.dart';
import 'package:latlong2/latlong.dart'; // LatLng, Distance
import 'package:provider/provider.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../state/app_state.dart';
import '../widgets/voice_button.dart';

enum CommandOption {
  start,
  setAltitude, // requires numeric value (meters)
  flyForward,  // requires numeric value (meters)
  land,
  proceed,
  prepareForMission,
  prepareForTestFlight
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
  int _target = NodeId.broadcast;

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

  String? _parseVoiceToCommand(String phrase) {
    final text = phrase.toLowerCase().trim();

    double? pullNumber(RegExp re) {
      final m = re.firstMatch(text);
      if (m != null && m.groupCount >= 1) {
        return double.tryParse(m.group(1)!.replaceAll(',', '.'));
      }
      return null;
    }

    final altRePl = RegExp(
      r'(?:ustaw\s+)?(?:wysoko(?:ść|sc)|wysokosc|wysokość\s*lotu|wysokosc\s*lotu|wys\.)\s*(?:na|do)?\s*(\d+(?:[\.,]\d+)?)'
    );
    final altReEn = RegExp(
      r'(?:set\s+)?(?:altitude|alt|height)\s*(?:to)?\s*(\d+(?:[\.,]\d+)?)'
    );
    if (altRePl.hasMatch(text) || altReEn.hasMatch(text)) {
      final v = pullNumber(altRePl) ?? pullNumber(altReEn);
      if (v == null) return 'Could not parse altitude value from STT';
      _cmd = CommandOption.setAltitude;
      _paramCtrl.text = v.toString();
      return null;
    }

    final fwdRePl = RegExp(
      r'(?:(?:le[cć]|lec|jed[zź]|idzi[eę]|rusz|przesu[nń])\s+)?(?:do\s+prz[óo]du|naprz[óo]d|prosto)\s*(\d+(?:[\.,]\d+)?)(?:\s*(?:m|metr(?:y|ów|ow)?))?'
    );
    final fwdReEn = RegExp(
      r'(?:(?:fly|go|move)\s+)?forward\s(for)?(\d+(?:[\.,]\d+)?)(?:\s*(?:m|meter|meters))?'
    );
    if (fwdRePl.hasMatch(text) || fwdReEn.hasMatch(text)) {
      final v = pullNumber(fwdRePl) ?? pullNumber(fwdReEn);
      if (v == null) return 'Could not parse distance value from STT';
      _cmd = CommandOption.flyForward;
      _paramCtrl.text = v.toString();
      return null;
    }

    final landEn = RegExp(
      r'\b(land|touch\s*down|descend)\b'
    );
    final landPl = RegExp(
      r'\b(l[aą]duj|wyl[aą]duj|przyziemiaj|przyziemi[eę])\b'
    );
    if (landPl.hasMatch(text) || landEn.hasMatch(text)) {
      _cmd = CommandOption.land;
      _paramCtrl.text = "";
      return null;
    }

    final missionEn = RegExp(
      r'\b(proceed|continue|resume)\b'
    );
    final missionPl = RegExp(
      r'\b(misja|kontynuuj|rozpocznij misję)\b'
    );
    if (missionPl.hasMatch(text) || missionEn.hasMatch(text)) {
      _cmd = CommandOption.proceed;
      _paramCtrl.text = "";
      return null;
    }

    final startEn = RegExp(
      r'\b(start|arm|begin)\b'
    );
    final startPl = RegExp(
      r'\b(startuj|uzbr[óo]j|zacznij|rozpocznij)\b'
    );
    if (startPl.hasMatch(text) || startEn.hasMatch(text)) {
      _cmd = CommandOption.start;
      _paramCtrl.text = "";
      return null;
    }

    final prepTestEn = RegExp(
      r'\b(?:prepare|prep|ready|arm)\s*(?:for\s*)?(?:test[-\s]*flight|pre[-\s]*flight|preflight)\b'
    );
    final prepTestPl = RegExp(
      r'(?:przygotuj|uzbr[oó]j|got[oó]w(?:uj)?)\s*(?:do\s*)?(?:lotu?\s*testow(?:ego|y)|testowego\s*lotu|lotu?\s*pr[óo]bnego)'
    );
    if (prepTestPl.hasMatch(text) || prepTestEn.hasMatch(text)) {
      _cmd = CommandOption.prepareForTestFlight;
      _paramCtrl.text = "";
      return null;
    }

    final prepMissionEn = RegExp(
      r'\b(?:prepare|prep|ready)\s*(?:for\s*)?missions?\b'
    );
    final prepMissionPl = RegExp(
      r'(?:przygotuj|got[oó]w(?:uj)?|uzbr[oó]j)\s*(?:do|na)?\s*misj[ieę]'
    );
    if (prepMissionPl.hasMatch(text) || prepMissionEn.hasMatch(text)) {
      _cmd = CommandOption.prepareForMission;
      _paramCtrl.text = "";
      return null;
    }

    return 'Unrecognized command';
  }

  Future<void> _startVoiceCommand(AppState app) async {
    if (_speech == null) return;
    if (!_speechAvailable) {
      _speechAvailable = await _speech!.initialize();
      if (!_speechAvailable) return;
    }
    _clearHeard();

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
          final parsed = _parseVoiceToCommand(text);
          _parseError = parsed;
        });
      },
    );
  }

  Future<double?> _getHeadingDegrees(AppState app) async {
    try {
      final ev = await FlutterCompass.events
          ?.firstWhere((e) => e.heading != null && e.heading!.isFinite)
          .timeout(const Duration(milliseconds: 800));
      if (ev?.heading != null && ev!.heading!.isFinite) {
        app.headingDegrees = ev.heading;
        return ev.heading;
      }
    } catch (_) {}
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (pos.heading.isFinite && pos.heading >= 0) {
        app.headingDegrees = pos.heading;
        return pos.heading;
      }
    } catch (_) {}
    return null;
  }

  Future<LatLng?> _getCurrentLatLng(AppState app) async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      final here = LatLng(pos.latitude, pos.longitude);
      app.userLocation = here;
      return here;
    } catch (_) {
      return null;
    }
  }

  Future<LatLng?> _latLngFromDistanceToUser(AppState app, double meters) async {
    LatLng? start = await _getCurrentLatLng(app);
    double? heading = await _getHeadingDegrees(app);

    if (heading == null) {
      if (app.headingDegrees != null) {
        heading = app.headingDegrees;
        logWarn("Heading unavailable, using last cached");
      } else {
        heading = 0.0;
        logWarn("Heading unavailable, no previous heading found, using geo north");
      }
    }

    if (start == null) {
      if (app.userLocation != null) {
        start = app.userLocation;
        logWarn(
          'Location unavailable; using last known location (${start!.latitude.toStringAsFixed(5)}, ${start.longitude.toStringAsFixed(5)})'
        );
      } else if (app.singlePoint != null) {
        start = app.singlePoint;
        logWarn(
          'Location unavailable; using singlePoint (${start!.latitude.toStringAsFixed(5)}, ${start.longitude.toStringAsFixed(5)})'
        );
      } else {
        logError('Location unavailable, no last known location, no single point set. Command not sent');
        return null;
      }
    }

    final dest = Distance().offset(start, meters, heading as num);
    app.singlePoint = dest;
    return dest;
  }

  Future<void> _sendSelectedCommand(AppState app) async {
    String args = "";
    final argTrim = _paramCtrl.text.trim();
    if (argTrim.isNotEmpty) {
      args = ' (argument: $argTrim)';
    }
    final v = double.tryParse(argTrim);
    if (v == null) {
      if (_cmd == CommandOption.setAltitude) {
        _showSnack('Enter a valid altitude (meters).');
        return;
      }
      if (_cmd == CommandOption.flyForward) {
        _showSnack('Enter a valid distance (meters).');
        return;
      }
    }
    logSnt('Sending ${_cmd.name} to ${nodeIdToName[_target]}$args');

    switch (_cmd) {
      case CommandOption.start:
        await app.serial.send(MessageBuilder.start(dest: _target));
        return;
      case CommandOption.setAltitude:
        await app.serial.send(MessageBuilder.altSet(dest: _target, meters: v!));
        return;
      case CommandOption.flyForward:
        LatLng? coord = await _latLngFromDistanceToUser(app, v!);
        if (coord == null) return;
        await app.serial.send(MessageBuilder.flyTo(dest: _target, lat: coord.latitude, lon: coord.longitude));
        return;
      case CommandOption.land:
        await app.serial.send(MessageBuilder.end(dest: _target));
        return;
      case CommandOption.proceed:
        await app.serial.send(MessageBuilder.msnStart(dest: _target));
        return;
      case CommandOption.prepareForTestFlight:
        await app.serial.send(MessageBuilder.msnStart(dest: _target));
        return;
      case CommandOption.prepareForMission:
        await app.serial.send(MessageBuilder.msnStart(dest: _target));
        return;
    }
  }

  void _clearHeard() {
    setState(() {
      _heardText = '';
      _parsedCmdString = null;
      _parseError = null;
    });
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
                  initialValue: _selected,
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
          if (_heardText.isNotEmpty)
            Text('Heard: $_heardText',
                style: Theme.of(context).textTheme.bodyMedium),
          if (_parseError != null)
            Text(_parseError!,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.red)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _target,
                  items: [
                    DropdownMenuItem(
                      value: NodeId.broadcast,
                      child: Text(nodeIdToName[NodeId.broadcast]!),
                    ),
                    DropdownMenuItem(
                      value: NodeId.drone1,
                      child: Text(nodeIdToName[NodeId.drone1]!),
                    ),
                    DropdownMenuItem(
                      value: NodeId.drone2,
                      child: Text(nodeIdToName[NodeId.drone2]!),
                    ),
                    DropdownMenuItem(
                      value: NodeId.drone3,
                      child: Text(nodeIdToName[NodeId.drone3]!),
                    ),
                    DropdownMenuItem(
                      value: NodeId.drone4,
                      child: Text(nodeIdToName[NodeId.drone4]!),
                    ),
                  ],
                  onChanged: (c) {
                    if (c == null) return;
                    setState(() {
                      _target = c;
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Target',
                    border: OutlineInputBorder(),
                  ),
                ),
              )
            ]
          ),
          const SizedBox(height: 16),
          // Dropdown of commands + conditional parameter input
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<CommandOption>(
                  initialValue: _cmd,
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
                    DropdownMenuItem(
                      value: CommandOption.proceed,
                      child: Text('Proceed'),
                    ),
                    DropdownMenuItem(
                      value: CommandOption.prepareForMission,
                      child: Text('Prep mission'),
                    ),
                    DropdownMenuItem(
                      value: CommandOption.prepareForTestFlight,
                      child: Text('Prep test'),
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
          Row (
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(child: DroneStatusTile(lastMessageAt: app.lastSeen[NodeId.drone1], droneId: nodeIdToName[NodeId.drone1]!, points: app.espPoints[NodeId.drone1]!.length)),
              const SizedBox(width: 12),
              Expanded(child: DroneStatusTile(lastMessageAt: app.lastSeen[NodeId.drone2], droneId: nodeIdToName[NodeId.drone2]!, points: app.espPoints[NodeId.drone2]!.length))
            ]
          ),
          const SizedBox(height: 12),
          Row (
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(child: DroneStatusTile(lastMessageAt: app.lastSeen[NodeId.drone3], droneId: nodeIdToName[NodeId.drone3]!, points: app.espPoints[NodeId.drone3]!.length)),
              const SizedBox(width: 12),
              Expanded(child: DroneStatusTile(lastMessageAt: app.lastSeen[NodeId.drone4], droneId: nodeIdToName[NodeId.drone4]!, points: app.espPoints[NodeId.drone4]!.length))
            ]
          )
        ],
      ),
    );
  }
}
