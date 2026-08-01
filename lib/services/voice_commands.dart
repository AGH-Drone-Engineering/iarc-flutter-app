import '../models/drone.dart';
import '../models/mission_message.dart';

sealed class VoiceIntent {
  const VoiceIntent();
}

class StartDemoIntent extends VoiceIntent {
  const StartDemoIntent();
}

class StartMainIntent extends VoiceIntent {
  const StartMainIntent();
}

class LandIntent extends VoiceIntent {
  const LandIntent();
}

class ReturnHomeIntent extends VoiceIntent {
  const ReturnHomeIntent();
}

class StatusIntent extends VoiceIntent {
  const StatusIntent();
}

class MoveIntent extends VoiceIntent {
  final MoveDirection direction;

  final double? distance;
  const MoveIntent(this.direction, this.distance);
}

class TargetIntent extends VoiceIntent {
  final int droneId;
  const TargetIntent(this.droneId);
}

class VoiceResult {
  final VoiceIntent? intent;

  final int? target;
  final String? error;

  const VoiceResult({this.intent, this.target, this.error});

  bool get isEmpty => intent == null && target == null;
}

class VoiceCommandParser {
  static final _startDemo = [
    RegExp(r'\b(?:start|begin|run)\s+(?:the\s+)?demo\b'),
    RegExp(r'\b(?:start|rozpocznij|uruchom)\s+(?:misj[ęe]\s+)?demo\b'),
  ];

  static final _startMain = [
    RegExp(r'\b(?:start|begin|run)\s+(?:the\s+)?(?:main|field)\s*(?:mission)?\b'),
    RegExp(r'\b(?:start|rozpocznij|uruchom)\s+(?:misj[ęe]\s+)?(?:g[łl][óo]wn[ąa]|main)\b'),
  ];

  static final _land = [
    RegExp(r'\b(?:land|touch\s*down|descend)\b'),
    RegExp(r'\b(?:l[aą]duj|wyl[aą]duj|siadaj)\b'),
  ];

  static final _rth = [
    RegExp(r'\b(?:return|rth|go\s+home|come\s+back)\b'),
    RegExp(r'\b(?:wracaj|powr[óo]t|do\s+domu)\b'),
  ];

  static final _status = [
    RegExp(r'\b(?:status|report|check\s+in|ping)\b'),
    RegExp(r'\b(?:status|raport|melduj)\b'),
  ];

  static final _directions = <(RegExp, MoveDirection)>[
    (RegExp(r'\b(?:forward|front)[\s-]+left\b|\bnorth[\s-]*west\b'), MoveDirection.forwardLeft),
    (RegExp(r'\b(?:forward|front)[\s-]+right\b|\bnorth[\s-]*east\b'), MoveDirection.forwardRight),
    (RegExp(r'\bback(?:ward)?[\s-]+left\b|\bsouth[\s-]*west\b'), MoveDirection.backLeft),
    (RegExp(r'\bback(?:ward)?[\s-]+right\b|\bsouth[\s-]*east\b'), MoveDirection.backRight),
    (RegExp(r'\b(?:w\s*prz[óo]d|do\s*przodu|naprz[óo]d)\s+(?:w\s*)?lewo\b'), MoveDirection.forwardLeft),
    (RegExp(r'\b(?:w\s*prz[óo]d|do\s*przodu|naprz[óo]d)\s+(?:w\s*)?prawo\b'), MoveDirection.forwardRight),
    (RegExp(r'\b(?:w\s*ty[łl]|do\s*ty[łl]u|cofnij)\s+(?:w\s*)?lewo\b'), MoveDirection.backLeft),
    (RegExp(r'\b(?:w\s*ty[łl]|do\s*ty[łl]u|cofnij)\s+(?:w\s*)?prawo\b'), MoveDirection.backRight),
    (RegExp(r'\b(?:forward|ahead|straight|front)\b'), MoveDirection.forward),
    (RegExp(r'\b(?:w\s*prz[óo]d|do\s*przodu|naprz[óo]d|prosto)\b'), MoveDirection.forward),
    (RegExp(r'\b(?:back(?:ward)?|reverse)\b'), MoveDirection.back),
    (RegExp(r'\b(?:w\s*ty[łl]|do\s*ty[łl]u|cofnij)\b'), MoveDirection.back),
    (RegExp(r'\bleft\b'), MoveDirection.left),
    (RegExp(r'\b(?:w\s*)?lewo\b'), MoveDirection.left),
    (RegExp(r'\bright\b'), MoveDirection.right),
    (RegExp(r'\b(?:w\s*)?prawo\b'), MoveDirection.right),
  ];

  static final _distance = RegExp(
    r'(\d+(?:[\.,]\d+)?)\s*(?:m\b|met(?:er|re)s?\b|metr(?:y|ów|ow|a)?\b)',
  );

  static final _broadcast = RegExp(
    r'\b(?:broadcast|all(?:\s+drones?)?|everyone|wszystkie(?:\s+drony)?|do\s+wszystkich)\b',
  );

  static final _droneNumber = RegExp(
    r'\b(?:drone|dron|unit|uav)\s*(?:no\.?|nr\.?|#)?\s*(\d+)\b',
  );

  static final _droneWord = RegExp(r'\b(?:drone|dron|unit)\s+([a-ząćęłńóśżź]+)\b');

  static const _numberWords = <String, int>{
    'one': 1, 'two': 2, 'three': 3, 'four': 4,
    'jeden': 1, 'pierwszy': 1, 'dwa': 2, 'drugi': 2,
    'trzy': 3, 'trzeci': 3, 'cztery': 4, 'czwarty': 4,
  };

  VoiceResult parse(String phrase) {
    final text = phrase.toLowerCase().trim();
    if (text.isEmpty) return const VoiceResult();

    final target = _parseTarget(text);

    if (_matchesAny(_startDemo, text)) {
      return VoiceResult(intent: const StartDemoIntent(), target: target);
    }
    if (_matchesAny(_startMain, text)) {
      return VoiceResult(intent: const StartMainIntent(), target: target);
    }
    if (_matchesAny(_rth, text)) {
      return VoiceResult(intent: const ReturnHomeIntent(), target: target);
    }
    if (_matchesAny(_land, text)) {
      return VoiceResult(intent: const LandIntent(), target: target);
    }
    if (_matchesAny(_status, text)) {
      return VoiceResult(intent: const StatusIntent(), target: target);
    }

    for (final (re, dir) in _directions) {
      if (re.hasMatch(text)) {
        return VoiceResult(
          intent: MoveIntent(dir, _parseDistance(text)),
          target: target,
        );
      }
    }

    if (target != null) {
      return VoiceResult(intent: TargetIntent(target), target: target);
    }
    return const VoiceResult(error: 'Unrecognised command');
  }

  bool _matchesAny(List<RegExp> patterns, String text) =>
      patterns.any((re) => re.hasMatch(text));

  double? _parseDistance(String text) {
    final m = _distance.firstMatch(text);
    if (m == null) return null;
    return double.tryParse(m.group(1)!.replaceAll(',', '.'));
  }

  int? _parseTarget(String text) {
    if (_broadcast.hasMatch(text)) return kBroadcastAddress;

    for (final d in Drone.all) {
      if (RegExp(r'\b' + RegExp.escape(d.name.toLowerCase()) + r'\b').hasMatch(text)) {
        return d.id;
      }
    }

    final numeric = _droneNumber.firstMatch(text);
    if (numeric != null) {
      final n = int.tryParse(numeric.group(1)!);
      if (n != null && Drone.byId(n) != null) return n;
    }

    final word = _droneWord.firstMatch(text);
    if (word != null) {
      final n = _numberWords[word.group(1)!];
      if (n != null && Drone.byId(n) != null) return n;
    }

    return null;
  }
}
