// lib/screens/esp_data_tab.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_esp_android_communication/models/message.dart';
import 'package:flutter_esp_android_communication/services/global_log.dart';
import 'package:flutter_esp_android_communication/widgets/drone_status_tile.dart';
import 'package:provider/provider.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../models/Drone.dart';
import '../models/command.dart';
import '../state/app_state.dart';
import '../widgets/voice_button.dart';

class EspDataTab extends StatefulWidget {
  const EspDataTab({super.key});
  @override
  State<EspDataTab> createState() => _EspDataTabState();
}

class _EspDataTabState extends State<EspDataTab> with AutomaticKeepAliveClientMixin {
  List<UsbDevice> _devices = [];
  UsbDevice? _selected;

  // Voice
  stt.SpeechToText? _speech;
  bool _speechAvailable = false;

  // Last heard phrase + parsed + confirmable command
  String _heardText = '';
  String? _parseError;

  Command? _lastCmdForCtrls; // track to know when to rebuild controllers

  final Map<String, TextEditingController> _paramCtrls = {};

  @override
  bool get wantKeepAlive => true;

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
    Command.ensureRegistered();
    Drone.ensureRegistered();
    _speech = stt.SpeechToText();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Init device list
      _refreshDevices(context.read<AppState>());
      // Init speech engine
      final ok = await _speech!.initialize(onStatus: (_) {}, onError: (_) {});
      if (mounted) {
        setState(() => _speechAvailable = ok);
        final cmd = context.read<AppState>().selectedCommand;
        _rebuildControllersFor(cmd);
        _lastCmdForCtrls = cmd;
      }
    });
  }

  @override
  void dispose() {
    for (final c in _paramCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _rebuildControllersFor(Command? cmd) {
    // Dispose old
    for (final c in _paramCtrls.values) {
      c.dispose();
    }
    _paramCtrls.clear();

    if (cmd == null) return;
    for (final p in cmd.params) {
      _paramCtrls[p.key] = TextEditingController();
    }
  }

  void _maybeRebuildCtrlsFor(Command? cmd) {
    if (identical(cmd, _lastCmdForCtrls)) return;
    _rebuildControllersFor(cmd);
    _lastCmdForCtrls = cmd;
  }

  double? _parseSignedNum(String s) {
    var t = s.trim().toLowerCase();

    // Normalize unicode dashes to '-'
    t = t.replaceFirst(RegExp(r'^[\u2212\u2012\u2013\u2014]'), '-'); // minus, figure, en, em

    // Detect leading sign words/chars
    bool neg = false;
    if (RegExp(r'^\s*(?:minus|negative|ujemn(?:y|a|e))\b').hasMatch(t)) {
      neg = true;
      t = t.replaceFirst(RegExp(r'^\s*(?:minus|negative|ujemn(?:y|a|e))\b\s*'), '');
    } else if (RegExp(r'^\s*(?:\+|plus|dodatni(?:a|e)?)\b').hasMatch(t)) {
      // explicit positive
      t = t.replaceFirst(RegExp(r'^\s*(?:\+|plus|dodatni(?:a|e)?)\b\s*'), '');
    } else if (RegExp(r'^\s*[-]').hasMatch(t)) {
      neg = true;
      t = t.replaceFirst(RegExp(r'^\s*[-]\s*'), '');
    } else if (RegExp(r'^\s*[+]').hasMatch(t)) {
      t = t.replaceFirst(RegExp(r'^\s*[+]\s*'), '');
    }

    // Decimal comma → dot
    t = t.replaceAll(',', '.');

    final v = double.tryParse(t);
    if (v == null) return null;
    return neg ? -v : v;
  }

  // Assumes: Command.registeredCommands filled; Map<String, TextEditingController> _paramCtrls exists.
  String? _parseVoiceToCommand(AppState app, String phrase) {
    final text = phrase.toLowerCase().trim();

    double? parseNum(String s) => _parseSignedNum(s);

    for (final cmd in Command.registeredCommands.values) {
      if (cmd.voice.isEmpty) continue;

      for (final re in cmd.voice) {
        final m = re.firstMatch(text);
        if (m == null) continue;
        app.setSelectedCommand(cmd);
        // inside _parseVoiceToCommand, right after you set `_cmd = cmd;`
        final tgt = _tryParseTargetFromVoice(text);
        if (tgt != null) app.setSelectedTarget(tgt);

        _maybeRebuildCtrlsFor(cmd);

        for (final p in cmd.params) {
          (_paramCtrls[p.key] ??= TextEditingController()).clear();
        }
        final nums = <double>[];
        for (var i = 1; i <= m.groupCount; i++) {
          final g = m.group(i);
          if (g != null) {
            final v = parseNum(g);
            if (v != null) nums.add(v);
          }
        }
        if (nums.isEmpty) {
          final g = RegExp(
              r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
          ).firstMatch(text);
          if (g != null) {
            final v = parseNum(g.group(1)!);
            if (v != null) nums.add(v);
          }
        }
        for (var i = 0; i < cmd.params.length && i < nums.length; i++) {
          final key = cmd.params[i].key;
          (_paramCtrls[key] ??= TextEditingController()).text = nums[i].toString();
        }
        if (cmd == Command.flyPolar &&
            (_paramCtrls['dist']?.text.isNotEmpty ?? false) &&
            (_paramCtrls['angle']?.text.isEmpty ?? true)) {
          (_paramCtrls['angle'] ??= TextEditingController()).text = '0';
        }

        return null; // success
      }
    }

    return 'Unrecognized command';
  }

  int? _tryParseTargetFromVoice(String text) {
    final t = text.toLowerCase();

    // 1) Broadcast / all drones
    if (RegExp(r'\b(?:broadcast|all(?:\s+drones?)?|wszys(?:tkie|cy)(?:\s+drony?)?|do\s+wszystkich)\b')
        .hasMatch(t)) {
      return Drone.broadcast;
    }

    // 2) By exact registered name (dynamic)
    for (final d in Drone.registeredDronesMap.values) {
      final name = d.name.toLowerCase();
      if (name.isNotEmpty && RegExp(r'\b' + RegExp.escape(name) + r'\b').hasMatch(t)) {
        return d.id;
      }
    }

    // 3) “drone/dron/unit #N”
    final mNum = RegExp(r'\b(?:drone|dron|unit|uav|quad)\s*(?:no\.?|nr\.?|#)?\s*(\d+)\b').firstMatch(t);
    if (mNum != null) {
      final n = int.tryParse(mNum.group(1)!);
      if (n != null && Drone.registeredDronesMap.containsKey(n)) return n;
    }

    // 4) Hex id like “0x03”
    final mHex = RegExp(r'\b0x([0-9a-f]{1,2})\b').firstMatch(t);
    if (mHex != null) {
      final n = int.tryParse(mHex.group(1)!, radix: 16);
      if (n != null && Drone.registeredDronesMap.containsKey(n)) return n;
    }

    // 5) Word numbers (“drone three”, “dron drugi”)
    final mWord = RegExp(r'\b(?:drone|dron|unit)\s+([a-ząćęłńóśżź]+)\b').firstMatch(t);
    if (mWord != null) {
      final w = mWord.group(1)!;
      const words = {
        // EN
        'one':1,'two':2,'three':3,'four':4,'five':5,'six':6,'seven':7,'eight':8,'nine':9,'ten':10,
        // PL (cardinals + ordinals)
        'jeden':1,'pierwszy':1,'dwa':2,'drugi':2,'trzy':3,'trzeci':3,'cztery':4,'czwarty':4,
        'pięć':5,'piec':5,'piąty':5,'piaty':5,'sześć':6,'szesc':6,'szósty':6,'szosty':6,
        'siedem':7,'siódmy':7,'siodmy':7,'osiem':8,'ósmy':8,'osmy':8,'dziewięć':9,'dziewiec':9,'dziewiąty':9,'dziewiaty':9,
        'dziesięć':10,'dziesiec':10,'dziesiąty':10,'dziesiaty':10,
      };
      final n = words[w];
      if (n != null && Drone.registeredDronesMap.containsKey(n)) return n;
    }

    return null; // no target found
  }

  Future<void> _startVoiceCommand(AppState app) async {
    if (_speech == null) return;
    if (!_speechAvailable) {
      _speechAvailable = await _speech!.initialize();
      if (!_speechAvailable) return;
    }
    _clearHeard();

    await _speech!.listen(
      listenFor: const Duration(seconds: 15),
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
          _parseError = _parseVoiceToCommand(app, text);
        });
      },
    );
  }

  Future<void> _sendSelectedCommand(AppState app) async {
    final cmd = app.selectedCommand;
    final target = app.selectedTarget;

    String args = '';
    if (cmd.params.isNotEmpty) {
      final parts = <String>[];
      for (final p in cmd.params) {
        final t = _paramCtrls[p.key]?.text.trim() ?? '';
        if (t.isNotEmpty) parts.add('${p.label}: $t');
      }
      if (parts.isNotEmpty) args = ' (${parts.join(', ')})';
    }

    final parsed = <String, double>{};
    for (final p in cmd.params) {
      final raw = (_paramCtrls[p.key]?.text ?? '').trim();
      final val = double.tryParse(raw.replaceAll(',', '.'));
      if (raw.isEmpty || val == null) {
        _showSnack('Enter a valid ${p.label}.');
        return;
      }
      parsed[p.key] = val;
    }

    final sndName = target  == Drone.broadcast
        ? 'All drones'
        : Drone.registeredDronesMap[target]?.name;
    logSnt('Sending ${cmd.internalName} to $sndName$args');

    switch (cmd) {
      case Command(byte: 0x01): // START
        await app.serial.send(MessageBuilder.start(dest: target));
        return;

      case Command(byte: 0x04): // ALT_SET
        await app.serial.send(
          MessageBuilder.altSet(
            dest: target,
            meters: parsed['alt']!, // from Command.altSet.params
            endian: Endian.big,
          ),
        );
        return;

      case Command(byte: 0x0B): // SET_SPEED
        await app.serial.send(
          MessageBuilder.setSpeed(
            dest: target,
            speed: parsed['speed']!,
            endian: Endian.big,
          ),
        );
        return;

      case Command(byte: 0x03): // FLY_TO (lat/lng)
        await app.serial.send(
          MessageBuilder.flyTo(
            dest: target,
            lat: parsed['lat']!,
            lon: parsed['lng']!,
            endian: Endian.big,
          ),
        );
        return;

      case Command(byte: 0x09): // FLY_POLAR (dist, angle → lat/lon)
        await app.serial.send(
          MessageBuilder.flyPolar(
            dest: target,
            dist: parsed['dist']!,
            angle: parsed['angle']!,
            endian: Endian.big,
          ),
        );
        return;

      case Command(byte: 0x05): // MSN_START (Proceed)
        await app.serial.send(MessageBuilder.msnStart(dest: target));
        return;

      case Command(byte: 0x06): // END (Land)
        await app.serial.send(MessageBuilder.end(dest: target));
        return;

      case Command(byte: 0x07): // PREP_TEST
        await app.serial.send(MessageBuilder.prepareForTest(dest: target));
        return;

      case Command(byte: 0x08): // PREP_MSN
        await app.serial.send(MessageBuilder.prepareForMission(dest: target));
        return;

      case Command(byte: 0x02): // CRD_SND
        final pts = app.orderedCorners;
        if (pts.length != 4) {
          logError("User tried to send incomplete point list: $pts");
          _showSnack("Not all points are provided!");
          return;
        }
        await app.serial.send(MessageBuilder.crdSnd(dest: target, corners: pts));
        return;

      default:
        logWarn(
          'Unhandled command: ${cmd.internalName} (0x${cmd.byte.toRadixString(16)})',
        );
        return;
    }
  }


  void _clearHeard() {
    setState(() {
      _heardText = '';
      _parseError = null;
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    Command.ensureRegistered();
    Drone.ensureRegistered();

    final app = context.watch<AppState>();
    final drones = Drone.registeredDronesMap.values.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
    final commands = Command.visible.toList()
      ..sort((a, b) => a.byte.compareTo(b.byte)); // stable order

    _maybeRebuildCtrlsFor(app.selectedCommand);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                    initialValue: app.selectedTarget,
                    items: [
                      const DropdownMenuItem(value: Drone.broadcast, child: Text('All drones')),
                      for (final d in drones) DropdownMenuItem(value: d.id, child: Text(d.name)),
                    ],
                    onChanged: (id) {
                      if (id == null) return;
                      app.setSelectedTarget(id);
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
                  child: DropdownButtonFormField<Command>(
                    initialValue: app.selectedCommand,
                    items: [
                      for (final c in commands)
                        DropdownMenuItem(
                          value: c,
                          child: Text(c.displayName),
                        ),
                    ],
                    onChanged: (c) {
                      app.setSelectedCommand(c);
                      _rebuildControllersFor(c);
                    },
                    decoration: const InputDecoration(
                      labelText: 'Command',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Dynamic parameter inputs (0..n)
                if ((app.selectedCommand.params.isNotEmpty))
                  Flexible(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final p in app.selectedCommand.params)
                          SizedBox(
                            width: 160,
                            child: TextField(
                              controller: _paramCtrls[p.key],
                              decoration: InputDecoration(
                                labelText: p.label,
                                border: const OutlineInputBorder(),
                              ),
                              keyboardType: const TextInputType.numberWithOptions(
                                signed: true,  // we'll restrict with inputFormatters below
                                decimal: true,
                              ),
                              inputFormatters: [
                                // Optional: lightly constrain numeric inputs
                                // You can add a more robust formatter per p.signed/p.decimal
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _sendSelectedCommand(app),
                icon: const Icon(Icons.send),
                label: const Text('Send Command'),
              )
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 2, // tweak to match your tile shape
              ),
              itemCount: drones.length,
              itemBuilder: (context, index) {
                final d = drones[index];
                return DroneStatusTile(
                  lastMessageAt: d.lastSeen,
                  droneId: d.name,
                  points: d.points.length,
                );
              },
            )
          ],
        ),
      )
    );
  }
}
