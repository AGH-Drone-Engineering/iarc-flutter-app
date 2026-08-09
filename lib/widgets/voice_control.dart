import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../models/drone.dart';
import '../services/voice_commands.dart';
import '../state/app_state.dart';
import 'section_card.dart';
import 'voice_button.dart';

/// Voice panel: a live transcript of what the recogniser is hearing, the
/// settings it applied, and a confirm step for anything that would reach a
/// drone.
class VoiceControl extends StatefulWidget {
  const VoiceControl({super.key});

  @override
  State<VoiceControl> createState() => _VoiceControlState();
}

class _VoiceControlState extends State<VoiceControl> {
  /// How long the transcript has to hold still before we act on it. Long
  /// enough for the recogniser to revise "eight" into "eighty", short enough
  /// that a finished command does not sit there while the engine waits out its
  /// own end-of-speech timeout.
  static const _settleDelay = Duration(milliseconds: 600);

  final _parser = VoiceCommandParser();
  stt.SpeechToText? _speech;
  bool _available = false;
  String? _unavailableReason;

  List<stt.LocaleName> _locales = const [];

  /// Ours rather than the recogniser's, so the button flips on the tap instead
  /// of when the platform gets round to reporting the session closed.
  bool _listening = false;

  /// Set once the session's transcript has been acted on. The settle timer, a
  /// final result from the engine and the button all race to be first, and
  /// applying the same sentence twice would move a setting twice.
  bool _handled = false;

  Timer? _settleTimer;

  /// What the recogniser has heard so far in this session. Updated on every
  /// partial result, which is the whole point of the panel.
  String _transcript = '';
  bool _transcriptIsFinal = false;

  /// Reading of [_transcript] while it is still being spoken. Partials get
  /// revised, so this is shown immediately but only acted on once it has held
  /// still for [_settleDelay].
  VoiceResult? _preview;

  List<String> _applied = const [];
  VoiceIntent? _pending;
  int _pendingTarget = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initSpeech());
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _speech?.cancel();
    super.dispose();
  }

  Future<void> _initSpeech() async {
    final speech = _speech;
    if (speech == null) return;

    final ok = await speech.initialize(
      // Only reached when the engine stops without having sent a final result;
      // the default two seconds of waiting for one is dead time.
      finalTimeout: const Duration(milliseconds: 400),
      // The platform may end a session on its own -- listenFor elapsing, an
      // error, the OS taking the mic -- so it can clear the flag, never set it.
      onStatus: (_) {
        if (!mounted || speech.isListening || !_listening) return;
        setState(() => _listening = false);
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _error = _friendlyError(e.errorMsg));
      },
    );
    if (!mounted) return;

    final locales = ok ? await speech.locales() : const <stt.LocaleName>[];
    if (!mounted) return;

    setState(() {
      _available = ok;
      _locales = locales;
      _unavailableReason = ok
          ? null
          : 'No speech recogniser available. On Android install or enable '
              'Google’s speech services, then reopen the app.';
    });
  }

  /// `error_no_match` and friends fire constantly on background noise and mean
  /// nothing to the operator.
  String? _friendlyError(String code) => switch (code) {
        'error_no_match' || 'error_speech_timeout' => 'Didn’t catch that',
        'error_permission' => 'Microphone permission denied',
        'error_network' || 'error_network_timeout' =>
          'Recogniser offline — no network',
        'error_busy' => 'Recogniser busy, try again',
        _ => code,
      };

  /// The engine wants a full id such as `pl_PL`; we store only the language.
  String? _localeIdFor(String language) {
    for (final l in _locales) {
      if (l.localeId.toLowerCase().startsWith(language)) return l.localeId;
    }
    return null;
  }

  Future<void> _listen() async {
    final speech = _speech;
    if (speech == null) return;
    final language = context.read<AppState>().voiceLocale;

    // A second tap means "I have said my piece": run it now rather than making
    // the operator wait for the engine to notice the silence.
    if (_listening) {
      await _finish();
      return;
    }
    if (!_available) {
      await _initSpeech();
      if (!_available) return;
    }

    setState(() {
      _listening = true;
      _handled = false;
      _transcript = '';
      _transcriptIsFinal = false;
      _preview = null;
      _applied = const [];
      _error = null;
    });

    try {
      await speech.listen(
        // These two have to be passed here, not only inside the options: the
        // stop timers are armed from these parameters, and nothing on the
        // Android side reads the copies the options carry across the channel.
        // Both are only backstops now -- a recognised command ends the session
        // through _armSettle long before either runs out.
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 2),
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          listenMode: stt.ListenMode.dictation,
          localeId: _localeIdFor(language),
        ),
        onResult: (r) {
          if (!mounted) return;
          final text = r.recognizedWords.trim();
          final changed = text != _transcript;
          setState(() {
            _transcript = text;
            _transcriptIsFinal = r.finalResult;
            _preview = text.isEmpty ? null : _parser.parse(text);
          });
          if (r.finalResult) {
            unawaited(_finish());
          } else if (changed) {
            _armSettle();
          }
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _error = 'Could not start listening';
      });
    }
  }

  /// Acts on the transcript as soon as it stops moving, so a command takes
  /// effect while the operator is still lowering the phone. Nothing is armed
  /// until the sentence parses to something, or a half-spoken order would be
  /// cut off and applied in the middle.
  void _armSettle() {
    _settleTimer?.cancel();
    _settleTimer = null;

    final preview = _preview;
    if (preview == null || preview.isEmpty) return;

    _settleTimer = Timer(_settleDelay, () {
      if (mounted) unawaited(_finish());
    });
  }

  /// Runs the transcript and closes the mic.
  Future<void> _finish() async {
    _settleTimer?.cancel();
    _settleTimer = null;

    if (!_handled && _transcript.isNotEmpty) {
      _handled = true;
      _dispatch(_transcript);
    }
    if (mounted) setState(() => _listening = false);

    // Cancel, not stop: the words have been used already, so a final result
    // from the engine would only arrive to be thrown away.
    await _speech?.cancel();
  }

  void _dispatch(String phrase) {
    final app = context.read<AppState>();
    final result = _parser.parse(phrase);

    if (result.target != null) app.setSelectedTarget(result.target!);

    final applied = <String>[];
    for (final intent in result.applyNow) {
      _apply(app, intent);
      applied.add(intent.label);
    }

    if (!mounted) return;
    setState(() {
      _applied = applied;
      _transcriptIsFinal = true;
      _pending = result.needsConfirm;
      _pendingTarget = result.target ?? app.selectedTarget;
      _error = result.isEmpty ? (result.error ?? 'Unrecognised command') : null;
    });
  }

  void _apply(AppState app, VoiceIntent intent) {
    switch (intent) {
      case SetDemoAltitudeIntent(:final meters):
        app.setDemoAltitude(meters);
      case SetMainAltitudeIntent(:final meters):
        app.setMainAltitude(meters);
      case SetDemoVerticesIntent(:final count):
        app.setDemoVertices(count.toDouble());
      case SetDemoRadiusIntent(:final meters):
        app.setDemoRadius(meters);
      case StopDemoIntent():
        app.stopDemo();
      case StartDemoIntent() ||
            StartMainIntent() ||
            LandIntent() ||
            ReturnHomeIntent() ||
            StatusIntent():
        // Never reached: these are held for confirmation.
        break;
    }
  }

  Future<void> _confirm() async {
    final intent = _pending;
    if (intent == null) return;
    final app = context.read<AppState>();
    final target = _pendingTarget;
    final who = Drone.nameFor(target);

    setState(() => _pending = null);

    switch (intent) {
      case StartDemoIntent():
        await app.startDemo(target: target);
        _note('START DEMO → $who');
      case StartMainIntent():
        final ok = await app.startMain(target: target);
        ok
            ? _note('START MAIN → $who')
            : _fail('Set all 4 field corners first');
      case LandIntent():
        await app.land(target: target);
        _note('LAND → $who');
      case ReturnHomeIntent():
        await app.returnHome(target: target);
        _note('RTH → $who');
      case StatusIntent():
        await app.requestStatus(target: target);
        _note('STATUS → $who');
      case StopDemoIntent() ||
            SetDemoAltitudeIntent() ||
            SetMainAltitudeIntent() ||
            SetDemoVerticesIntent() ||
            SetDemoRadiusIntent():
        // Never reached: these already ran when they were heard.
        break;
    }
  }

  void _note(String summary) {
    if (mounted) setState(() => _applied = [..._applied, summary]);
  }

  void _fail(String message) {
    if (mounted) setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final listening = _listening;
    final scheme = Theme.of(context).colorScheme;

    return SectionCard(
      title: 'Voice',
      trailing: SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'pl', label: Text('PL')),
          ButtonSegment(value: 'en', label: Text('EN')),
        ],
        selected: {app.voiceLocale},
        onSelectionChanged: (s) => app.setVoiceLocale(s.first),
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VoiceButton(
            available: _available,
            isListening: listening,
            onPressed: _listen,
          ),
          const SizedBox(height: 12),
          _Transcript(
            text: _transcript,
            listening: listening,
            isFinal: _transcriptIsFinal,
          ),
          if (listening && _preview != null) ...[
            const SizedBox(height: 6),
            _PreviewLine(result: _preview!),
          ],
          for (final line in _applied) ...[
            const SizedBox(height: 6),
            _StatusLine(
              icon: Icons.check_circle,
              color: Colors.green,
              text: line,
            ),
          ],
          if (_pending != null) ...[
            const SizedBox(height: 10),
            _PendingAction(
              intent: _pending!,
              target: _pendingTarget,
              enabled: app.isConnected,
              onSend: _confirm,
              onDismiss: () => setState(() => _pending = null),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 6),
            _StatusLine(
              icon: Icons.error_outline,
              color: scheme.error,
              text: _error!,
            ),
          ],
          if (_unavailableReason != null) ...[
            const SizedBox(height: 6),
            _StatusLine(
              icon: Icons.mic_off,
              color: scheme.error,
              text: _unavailableReason!,
            ),
          ],
        ],
      ),
    );
  }
}

/// The live field: what the recogniser is hearing, word by word.
class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.text,
    required this.listening,
    required this.isFinal,
  });

  final String text;
  final bool listening;
  final bool isFinal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final empty = text.isEmpty;

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: listening ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              empty
                  ? (listening ? 'Listening…' : 'Tap the mic and speak')
                  : (isFinal ? '“$text”' : '$text…'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: empty
                        ? scheme.onSurfaceVariant
                        : (isFinal ? scheme.onSurface : scheme.primary),
                    fontStyle: empty || !isFinal
                        ? FontStyle.italic
                        : FontStyle.normal,
                    height: 1.3,
                  ),
            ),
          ),
          if (listening) ...[
            const SizedBox(width: 8),
            const _LiveDot(),
          ],
        ],
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller.drive(Tween(begin: 0.25, end: 1.0)),
      child: Container(
        width: 10,
        height: 10,
        margin: const EdgeInsets.only(top: 5),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// What the half-finished sentence would do, so the operator can stop talking
/// early if it is going wrong.
class _PreviewLine extends StatelessWidget {
  const _PreviewLine({required this.result});

  final VoiceResult result;

  @override
  Widget build(BuildContext context) {
    final parts = [
      ...result.applyNow.map((i) => i.label),
      if (result.needsConfirm != null) result.needsConfirm!.label,
      if (result.applyNow.isEmpty &&
          result.needsConfirm == null &&
          result.target != null)
        'Target: ${Drone.nameFor(result.target!)}',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();

    return _StatusLine(
      icon: Icons.subdirectory_arrow_right,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      text: parts.join(' · '),
      italic: true,
    );
  }
}

class _PendingAction extends StatelessWidget {
  const _PendingAction({
    required this.intent,
    required this.target,
    required this.enabled,
    required this.onSend,
    required this.onDismiss,
  });

  final VoiceIntent intent;
  final int target;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${intent.label} → ${Drone.nameFor(target)}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send, size: 18),
            label: const Text('Send'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            tooltip: 'Discard',
            icon: const Icon(Icons.close),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.color,
    required this.text,
    this.italic = false,
  });

  final IconData icon;
  final Color color;
  final String text;
  final bool italic;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: italic ? FontWeight.w400 : FontWeight.w600,
                  fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                ),
          ),
        ),
      ],
    );
  }
}
