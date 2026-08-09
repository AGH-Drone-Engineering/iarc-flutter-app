import '../models/drone.dart';
import '../models/mission_message.dart' show kBroadcastAddress;
import '../state/mission_limits.dart';

/// Something the operator asked for out loud.
sealed class VoiceIntent {
  const VoiceIntent();

  /// Whether this may run the moment it is recognised.
  ///
  /// True for changes that never leave the ground station -- the demo figure
  /// settings, and stopping the local step pump. False for anything that puts a
  /// frame on the link, which waits for a deliberate tap: a word overheard in
  /// the room must not be able to launch or land the fleet.
  bool get appliesImmediately => false;

  /// Shown in the voice panel, so it has to read as the thing that happened.
  String get label;
}

class StartDemoIntent extends VoiceIntent {
  const StartDemoIntent();
  @override
  String get label => 'START DEMO';
}

class StopDemoIntent extends VoiceIntent {
  const StopDemoIntent();
  @override
  bool get appliesImmediately => true;
  @override
  String get label => 'STOP DEMO';
}

class StartMainIntent extends VoiceIntent {
  const StartMainIntent();
  @override
  String get label => 'START MAIN';
}

class LandIntent extends VoiceIntent {
  const LandIntent();
  @override
  String get label => 'LAND';
}

class ReturnHomeIntent extends VoiceIntent {
  const ReturnHomeIntent();
  @override
  String get label => 'RTH';
}

class StatusIntent extends VoiceIntent {
  const StatusIntent();
  @override
  String get label => 'STATUS';
}

class SetDemoAltitudeIntent extends VoiceIntent {
  const SetDemoAltitudeIntent(this.meters);
  final double meters;
  @override
  bool get appliesImmediately => true;
  @override
  String get label => 'Demo altitude → ${meters.toStringAsFixed(1)} m';
}

class SetMainAltitudeIntent extends VoiceIntent {
  const SetMainAltitudeIntent(this.meters);
  final double meters;
  @override
  bool get appliesImmediately => true;
  @override
  String get label => 'Main altitude → ${meters.toStringAsFixed(1)} m';
}

class SetDemoVerticesIntent extends VoiceIntent {
  const SetDemoVerticesIntent(this.count);
  final int count;
  @override
  bool get appliesImmediately => true;
  @override
  String get label => 'Figure vertices → $count';
}

class SetDemoRadiusIntent extends VoiceIntent {
  const SetDemoRadiusIntent(this.meters);
  final double meters;
  @override
  bool get appliesImmediately => true;
  @override
  String get label => 'Figure radius → ${meters.toStringAsFixed(1)} m';
}

class VoiceResult {
  const VoiceResult({
    this.applyNow = const [],
    this.needsConfirm,
    this.target,
    this.error,
  });

  /// Recognised changes that stay on the ground station.
  final List<VoiceIntent> applyNow;

  /// The one recognised command that would reach a drone, held back until the
  /// operator confirms it.
  final VoiceIntent? needsConfirm;

  /// The drone the sentence addressed, if it named one.
  final int? target;

  final String? error;

  bool get isEmpty =>
      applyNow.isEmpty && needsConfirm == null && target == null;
}

// A letter in either language. Dart's `\w` is ASCII-only, so it stops dead in
// the middle of "wierzchołków" and the pattern after it never lines up.
const _rest = r'[a-ząćęłńóśżź]*';
const _noLetterAfter = r'(?![a-ząćęłńóśżź])';
const _noLetterBefore = r'(?<![a-ząćęłńóśżź])';

const _sign =
    r'(?:[-−‒–—]\s*|(?:minus|negative|ujemn(?:y|a|e))\s+|[+]\s*|plus\s+)?';
const _digits = r'\d+(?:[.,]\d+)?';

/// "to"/"na"/"do", a colon, or nothing at all -- recognisers drop the small
/// words constantly, so "wysokość pięć" has to land the same as
/// "ustaw wysokość na pięć".
const _to = r'(?:\s*[:=]\s*|\s+(?:to|na|do|at)\s+|\s+)';
const _verb =
    r'(?:(?:set|change|make|adjust|ustaw|ustawi[cć]|zmie[nń]|daj)\s+)?';
const _the = r'(?:(?:the|a|an)\s+)?';

const _kAltitude =
    r'(?:altitude|alt|height|wysoko(?:ść|sc)' + _rest + r'|pu[łl]ap' + _rest + r')';
const _kMain =
    r'(?:main|search|scan|g[łl][óo]wn' + _rest + r'|przeszukiwania|skanowania|misji)';
const _kDemo = r'(?:demo|pokaz' + _rest + r'|figur' + _rest + r')';
const _kVertices = r'(?:vert(?:ices|exes|ex)|corners|sides|wierzcho[łl]k' +
    _rest +
    r'|bok(?:i|[óo]w)|bok)';
const _kRadius = r'(?:radius|radii|promie[nń]' + _rest + r')';
const _kCount = r'(?:number\s+of\s+|liczb[ęe]\s+|ilo(?:ść|sc)\s+)?';

RegExp _re(String pattern) => RegExp(pattern, caseSensitive: false);

class VoiceCommandParser {
  static const _numberWords = <String, num>{
    // EN
    'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
    'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10,
    'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14,
    'fifteen': 15, 'sixteen': 16, 'seventeen': 17, 'eighteen': 18,
    'nineteen': 19, 'twenty': 20, 'thirty': 30,
    // PL, with the bare-ASCII spellings a recogniser sometimes emits
    'jeden': 1, 'jedna': 1, 'pierwszy': 1,
    'dwa': 2, 'dwie': 2, 'drugi': 2,
    'trzy': 3, 'trzeci': 3, 'cztery': 4, 'czwarty': 4,
    'pięć': 5, 'piec': 5, 'piąty': 5, 'piaty': 5,
    'sześć': 6, 'szesc': 6, 'szósty': 6, 'szosty': 6,
    'siedem': 7, 'siódmy': 7, 'siodmy': 7,
    'osiem': 8, 'ósmy': 8, 'osmy': 8,
    'dziewięć': 9, 'dziewiec': 9, 'dziewiąty': 9, 'dziewiaty': 9,
    'dziesięć': 10, 'dziesiec': 10, 'dziesiąty': 10, 'dziesiaty': 10,
    'jedenaście': 11, 'jedenascie': 11,
    'dwanaście': 12, 'dwanascie': 12,
    'trzynaście': 13, 'trzynascie': 13,
    'czternaście': 14, 'czternascie': 14,
    'piętnaście': 15, 'pietnascie': 15,
    'szesnaście': 16, 'szesnascie': 16,
    'siedemnaście': 17, 'siedemnascie': 17,
    'osiemnaście': 18, 'osiemnascie': 18,
    'dziewiętnaście': 19, 'dziewietnascie': 19,
    'dwadzieścia': 20, 'dwadziescia': 20,
    'trzydzieści': 30, 'trzydziesci': 30,
  };

  /// Longest first: otherwise "dwa" wins against "dwanaście" and leaves a
  /// dangling "naście" behind.
  static final String _wordAlt = (_numberWords.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length)))
      .join('|');

  static final String _num =
      '($_sign(?:$_digits|(?:$_wordAlt)$_noLetterAfter))';

  static final _settings =
      <({RegExp pattern, VoiceIntent Function(double) build})>[
    // Main before demo: "set main altitude to 10" also reads as a bare
    // altitude, and whichever runs first consumes the words.
    (
      pattern: _re('$_noLetterBefore$_verb$_the$_kMain\\s+$_kAltitude$_to$_num'),
      build: (v) => SetMainAltitudeIntent(mainAltitudeRange.clamp(v)),
    ),
    (
      pattern: _re('$_noLetterBefore$_verb$_the$_kAltitude'
          '\\s+(?:for\\s+|of\\s+|dla\\s+)?$_kMain$_to$_num'),
      build: (v) => SetMainAltitudeIntent(mainAltitudeRange.clamp(v)),
    ),
    (
      pattern: _re('$_noLetterBefore$_verb$_the(?:$_kDemo\\s+)?$_kAltitude$_to$_num'),
      build: (v) => SetDemoAltitudeIntent(demoAltitudeRange.clamp(v)),
    ),
    (
      pattern: _re('$_noLetterBefore$_verb$_the$_kCount$_kVertices$_to$_num'),
      build: (v) => SetDemoVerticesIntent(demoVerticesRange.clamp(v).round()),
    ),
    // "eight vertices", "sześć boków"
    (
      pattern: _re('$_noLetterBefore$_num\\s+$_kVertices'),
      build: (v) => SetDemoVerticesIntent(demoVerticesRange.clamp(v).round()),
    ),
    (
      pattern: _re('$_noLetterBefore$_verb$_the$_kRadius$_to$_num'),
      build: (v) => SetDemoRadiusIntent(demoRadiusRange.clamp(v)),
    ),
  ];

  static final _actions = <({List<RegExp> patterns, VoiceIntent intent})>[
    (
      patterns: [
        _re(r'\b(?:stop|abort|halt|cancel)\b(?:\s+(?:the\s+)?(?:demo|pokaz|misj))?'),
        _re(r'\b(?:zatrzymaj|przerwij|anuluj|sko[nń]cz)\b'),
      ],
      intent: const StopDemoIntent(),
    ),
    (
      patterns: [
        _re(r'\b(?:start|begin|run|launch)\s+(?:the\s+)?demo\b'),
        _re(r'\b(?:start(?:uj)?|rozpocznij|uruchom|odpal)\s+(?:misj[ęe]\s+)?(?:demo|pokaz)'),
      ],
      intent: const StartDemoIntent(),
    ),
    (
      patterns: [
        _re(r'\b(?:start|begin|run|launch)\s+(?:the\s+)?(?:main|field|search|scan)\b'),
        _re(r'\b(?:start(?:uj)?|rozpocznij|uruchom)\s+(?:misj[ęe]\s+)?'
            r'(?:g[łl][óo]wn[ąa]|main|przeszukiwanie|skanowanie)'),
      ],
      intent: const StartMainIntent(),
    ),
    // Before LAND: "return home and land" is one order, not two.
    (
      patterns: [
        _re(r'\b(?:return(?:\s+(?:to\s+)?home)?|rth|go\s+home|come\s+back)\b'),
        _re(r'\b(?:wracaj|powr[óo]t|wr[óo][cć]|do\s+domu)'),
      ],
      intent: const ReturnHomeIntent(),
    ),
    (
      patterns: [
        _re(r'\b(?:land|touch\s*down|descend)\b'),
        _re(r'\b(?:l[aą]duj|wyl[aą]duj|siadaj|uziem)'),
      ],
      intent: const LandIntent(),
    ),
    (
      patterns: [
        _re(r'\b(?:status|report|check\s*in|ping|sit\s*rep)\b'),
        _re(r'\b(?:raport|melduj|meldunek)\b'),
      ],
      intent: const StatusIntent(),
    ),
  ];

  VoiceResult parse(String phrase) {
    final text = phrase.toLowerCase().trim();
    if (text.isEmpty) return const VoiceResult();

    final target = _parseTarget(text);

    // Each setting is blanked out of the sentence once it matches, so "set main
    // altitude to 10" cannot read a second time as a demo altitude, and one
    // breath can carry several of them.
    var rest = text;
    final applyNow = <VoiceIntent>[];
    for (final setting in _settings) {
      final m = setting.pattern.firstMatch(rest);
      if (m == null) continue;
      final value = _parseNumber(m.group(1)!);
      if (value == null) continue;
      applyNow.add(setting.build(value));
      rest = rest.replaceRange(m.start, m.end, ' ' * (m.end - m.start));
    }

    final action = _parseAction(rest);
    if (action != null && action.appliesImmediately) applyNow.add(action);

    if (applyNow.isEmpty && action == null && target == null) {
      return const VoiceResult(error: 'Unrecognised command');
    }

    return VoiceResult(
      applyNow: applyNow,
      needsConfirm: action != null && !action.appliesImmediately ? action : null,
      target: target,
    );
  }

  VoiceIntent? _parseAction(String text) {
    for (final action in _actions) {
      if (action.patterns.any((re) => re.hasMatch(text))) return action.intent;
    }
    return null;
  }

  /// Accepts "8", "8,5", "-8", "minus osiem", "eight".
  static double? _parseNumber(String token) {
    var t = token.trim().toLowerCase();

    t = t.replaceFirst(RegExp(r'^[−‒–—]'), '-');

    var negative = false;
    if (RegExp(r'^(?:minus|negative|ujemn(?:y|a|e))\b\s*').hasMatch(t)) {
      negative = true;
      t = t.replaceFirst(RegExp(r'^(?:minus|negative|ujemn(?:y|a|e))\b\s*'), '');
    } else if (RegExp(r'^(?:plus|dodatni(?:a|e)?)\b\s*').hasMatch(t)) {
      t = t.replaceFirst(RegExp(r'^(?:plus|dodatni(?:a|e)?)\b\s*'), '');
    } else if (t.startsWith('-')) {
      negative = true;
      t = t.substring(1).trim();
    } else if (t.startsWith('+')) {
      t = t.substring(1).trim();
    }

    final value = double.tryParse(t.replaceAll(',', '.')) ??
        _numberWords[t]?.toDouble();
    if (value == null) return null;
    return negative ? -value : value;
  }

  static final _broadcast = _re(
    r'\b(?:broadcast|all(?:\s+drones?)?|everyone|every\s+drone'
    r'|wszystkie(?:\s+drony)?|wszyscy|do\s+wszystkich)\b',
  );

  static final _droneNumber = _re(
    r'\b(?:drone|dron|unit|uav|quad|bajer)\s*(?:no\.?|nr\.?|#)?\s*(\d+)\b',
  );

  static final _droneHex = _re(r'\b0x([0-9a-f]{1,2})\b');

  static final _droneWord =
      _re(r'\b(?:drone|dron|unit|bajer)\s+([a-ząćęłńóśżź]+)');

  int? _parseTarget(String text) {
    if (_broadcast.hasMatch(text)) return kBroadcastAddress;

    for (final d in Drone.all) {
      if (_re(r'\b' + RegExp.escape(d.name.toLowerCase()) + r'\b')
          .hasMatch(text)) {
        return d.id;
      }
    }

    final numeric = _droneNumber.firstMatch(text);
    if (numeric != null) {
      final n = int.tryParse(numeric.group(1)!);
      if (n != null && Drone.byId(n) != null) return n;
    }

    final hex = _droneHex.firstMatch(text);
    if (hex != null) {
      final n = int.tryParse(hex.group(1)!, radix: 16);
      if (n != null && Drone.byId(n) != null) return n;
    }

    final word = _droneWord.firstMatch(text);
    if (word != null) {
      final n = _numberWords[word.group(1)!]?.toInt();
      if (n != null && Drone.byId(n) != null) return n;
    }

    return null;
  }
}
