import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../models/drone.dart';
import '../services/voice_commands.dart';
import '../state/app_state.dart';
import 'voice_button.dart';

class VoiceControl extends StatefulWidget {
  const VoiceControl({super.key});

  @override
  State<VoiceControl> createState() => _VoiceControlState();
}

class _VoiceControlState extends State<VoiceControl> {
  final _parser = VoiceCommandParser();
  stt.SpeechToText? _speech;
  bool _available = false;
  String _heard = '';
  String? _error;
  String? _accepted;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ok = await _speech!.initialize(onStatus: (_) {
        if (mounted) setState(() {});
      }, onError: (_) {
        if (mounted) setState(() {});
      });
      if (mounted) setState(() => _available = ok);
    });
  }

  @override
  void dispose() {
    _speech?.cancel();
    super.dispose();
  }

  Future<void> _listen() async {
    final speech = _speech;
    if (speech == null) return;
    if (!_available) {
      _available = await speech.initialize();
      if (!_available) return;
    }

    setState(() {
      _heard = '';
      _error = null;
      _accepted = null;
    });

    await speech.listen(
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        listenFor: const Duration(seconds: 15),
        pauseFor: const Duration(seconds: 2),
      ),
      onResult: (r) {
        if (!mounted) return;
        setState(() => _heard = r.recognizedWords.trim());
        if (r.finalResult) _dispatch(_heard);
      },
    );
  }

  Future<void> _dispatch(String phrase) async {
    final app = context.read<AppState>();
    final result = _parser.parse(phrase);

    if (result.error != null) {
      setState(() => _error = result.error);
      return;
    }
    if (result.target != null) app.setSelectedTarget(result.target!);

    final intent = result.intent;
    if (intent == null) return;

    final target = result.target ?? app.selectedTarget;
    final who = Drone.nameFor(target);

    switch (intent) {
      case StartDemoIntent():
        await app.startDemo(target: target);
        _accept('START DEMO → $who');
      case StartMainIntent():
        final ok = await app.startMain(target: target);
        ok ? _accept('START MAIN → $who') : _fail('Set all 4 field corners first');
      case LandIntent():
        await app.land(target: target);
        _accept('LAND → $who');
      case ReturnHomeIntent():
        await app.returnHome(target: target);
        _accept('RTH → $who');
      case StatusIntent():
        await app.requestStatus(target: target);
        _accept('STATUS → $who');
      case TargetIntent():
        _accept('Target: $who');
    }
  }

  void _accept(String summary) {
    if (mounted) setState(() => _accepted = summary);
  }

  void _fail(String message) {
    if (mounted) setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final listening = _speech?.isListening ?? false;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VoiceButton(
          available: _available && context.watch<AppState>().isConnected,
          isListening: listening,
          onPressed: _listen,
        ),
        if (_heard.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('“$_heard”',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center),
        ],
        if (_accepted != null) ...[
          const SizedBox(height: 4),
          Text(
            _accepted!,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: Colors.green, fontWeight: FontWeight.w700),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: scheme.error),
          ),
        ],
      ],
    );
  }
}
