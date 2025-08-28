enum ParamKind { number } // easy to extend later (text, enum, etc.)

class CommandParam {
  final String key;      // e.g. 'alt', 'lat', 'lng', 'dist', 'angle'
  final String label;    // e.g. 'Altitude (m)'
  final ParamKind kind;  // all numeric for now
  final bool signed;     // allow '-' (lat, angle, etc.)
  final bool decimal;    // allow decimals

  const CommandParam.number({
    required this.key,
    required this.label,
    this.signed = false,
    this.decimal = true,
  }) : kind = ParamKind.number;
}

class Command {
  final int byte;
  final String internalName;
  late String displayName;
  late bool display;
  final List<CommandParam> params;
  final List<RegExp> voice;

  static Map<int, Command> registeredCommands = {};

  static Command start    = Command(0x01, "START", "Start",
    voice: [
      RegExp(r'\b(start|arm|begin)\b'),
      RegExp(r'\b(startuj|uzbr[óo]j|zacznij|rozpocznij)\b'),
    ],
  );

  static Command crdSnd = Command(0x02, "CRD_SND", "Send coords",
    voice: [
      // EN: "send coords", "share coordinates", "broadcast location/position"
      RegExp(r'\b(?:send|share|broadcast|push|upload)\s*(?:coords?|coordinates|position|location)\b'),
      // PL: "wyślij współrzędne/koordynaty/pozycję/lokalizację"
      RegExp(r'\b(?:wy[śs]lij|prze[śs]lij|udost[ęe]pnij)\s*(?:wsp[óo]łrz[ęe]dne|koordynaty|pozycj[ea]|lokalizacj[ea])\b'),
    ],
  );

  static Command flyTo = Command(0x03, "FLY_TO", "Fly to",
    params: [
      CommandParam.number(key: 'lat', label: 'Latitude'),
      CommandParam.number(key: 'lng', label: 'Longitude'),
    ],
    voice: [
      // EN: "lat -52.1 lon 21.0" / "latitude: minus 52.1, longitude: 21.0"
      RegExp(
          r'(?:lat(?:itude)?)\s*[:=]?\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
          r'\s*(?:,|;|\s)\s*lon(?:gitude)?\s*[:=]?\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
      ),

      // PL: "szer. -52.1 dl. 21.0" / "szerokość: minus 52.1, długość: 21.0"
      RegExp(
          r'(?:szer(?:oko(?:ść|sc))?|szer\.)\s*[:=]?\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
          r'\s*(?:,|;|\s)\s*(?:d[łl]ugo(?:ść|sc)|d[łl]\.|dl\.)\s*[:=]?\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
      ),

      // EN generic: "coordinates -52.1, 21.0" / "coords: minus 52.1 21.0"
      RegExp(
          r'(?:coords?|coordinates)\s*[:=]?\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
          r'\s*[,;\s]\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
      ),

      // PL generic: "współrzędne -52.1, 21.0" / "koordynaty: minus 52.1 21.0"
      RegExp(
          r'(?:wsp[óo]łrz[ęe]dne|koordynaty)\s*[:=]?\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
          r'\s*[,;\s]\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
      ),
    ],
  );

  static Command altSet   = Command(0x04, "ALT_SET", "Set altitude",
    params: [ CommandParam.number(key: 'alt', label: 'Altitude (m)') ],
    voice: [
      RegExp(r'(?:ustaw\s+)?(?:wysoko(?:ść|sc)|wysokosc|wysokość\s*lotu|wysokosc\s*lotu|wys\.)\s*(?:na|do)?\s*(\d+(?:[\.,]\d+)?)'),
      RegExp(r'(?:set\s+)?(?:altitude|alt|height)\s*(?:to)?\s*(\d+(?:[\.,]\d+)?)'),
    ],
  );

  static Command msnStart = Command(0x05, "MSN_START", "Proceed",
    voice: [
      RegExp(r'\b(proceed|continue|resume)\b'),
      RegExp(r'\b(misja|kontynuuj|rozpocznij misję)\b'),
    ],
  );

  static Command end      = Command(0x06, "END", "End",
    voice: [
      RegExp(r'\b(land|touch\s*down|descend)\b'),
      RegExp(r'\b(l[aą]duj|wyl[aą]duj|przyziemiaj|przyziemi[eę])\b'),
    ],
  );

  static Command prepTest = Command(0x07, "PREP_TEST", "Prep test",
    voice: [
      RegExp(r'\b(?:prepare|prep|ready|arm)\s*(?:for\s*)?(?:test[-\s]*flight|pre[-\s]*flight|preflight)\b'),
      RegExp(r'(?:przygotuj|uzbr[oó]j|got[oó]w(?:uj)?)\s*(?:do\s*)?(?:lotu?\s*testow(?:ego|y)|testowego\s*lotu|lotu?\s*pr[óo]bnego)'),
    ],
  );

  static Command prepMsn  = Command(0x08, "PREP_MSN", "Prep mission",
    voice: [
      RegExp(r'\b(?:prepare|prep|ready)\s*(?:for\s*)?missions?\b'),
      RegExp(r'(?:przygotuj|got[oó]w(?:uj)?|uzbr[oó]j)\s*(?:do|na)?\s*misj[ieę]'),
    ],
  );

  static Command flyPolar = Command(0x09, "FLY_POLAR", "Fly polar",
    params: [
      CommandParam.number(key: 'dist',  label: 'Distance (m)'),
      CommandParam.number(key: 'angle', label: 'Angle (°)', signed: true),
    ],
    voice: [
      // EN: "forward 30 m at minus 90 degrees"
      RegExp(
          r'(?:(?:fly|go|move)\s+)?forward\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
          r'\s*(?:m|meter|meters)?\s*(?:at\s*)?(?:angle|bearing|heading)?\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
          r'(?:\s*(?:°|degrees|deg))?'
      ),

      // PL: "do przodu 30 m kąt minus 90 stopni"
      RegExp(
          r'(?:(?:le[cć]|lec|jed[zź]|idzi[eę]|rusz|przesu[nń])\s+)?(?:do\s+prz[óo]du|naprz[óo]d|prosto)\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
          r'\s*(?:m|metr(?:y|ów|ow)?)?\s*(?:pod\s*k[ąa]tem|k[ąa]t|azymut)\s*'
          r'((?:(?:[-\u2212\u2012\u2013\u2014])|(?:minus|negative|ujemn(?:y|a|e))|(?:\+|plus|dodatni(?:a|e)?))?\s*\d+(?:[\.,]\d+)?)'
          r'(?:\s*(?:°|stopni|deg))?'
      ),
    ],
  );


  static Command setSpeed = Command(0x0B, "SET_SPEED", "Set speed",
    params: [
      CommandParam.number(key: 'speed', label: 'Speed (m/s)'),
    ],
    voice: [
      // EN: "set speed to 5 (m/s)"
      RegExp(r'(?:set\s+)?(?:speed|velocity)\s*(?:to)?\s*(\d+(?:[\.,]\d+)?)(?:\s*(?:m\/s|mps|meters?\/s(?:ec)?|meters?\s*per\s*second))?'),
      // PL: "ustaw prędkość na 5 (m/s)"
      RegExp(r'(?:ustaw\s+)?(?:pr[ęe]dko(?:ść|sc)|predkosc|v)\s*(?:na|do)?\s*(\d+(?:[\.,]\d+)?)(?:\s*(?:m\/s|mps|metr(?:y|ów|ow)?\/s(?:ek)?|metr(?:y|ów|ow)?\s*na\s*sekund[ęe]?))?'),
    ],
  );

  static Command telemetry= Command._(0xFF, "TELEMETRY");

  static void ensureRegistered() {
    start; crdSnd; flyTo; altSet; msnStart; end; prepTest; prepMsn; flyPolar; setSpeed; telemetry;
  }

  static Iterable<Command> get all {
    ensureRegistered();
    return registeredCommands.values;
  }

  static Iterable<Command> get visible {
    ensureRegistered();
    return registeredCommands.values.where((c) => c.display);
  }

  // Strongly recommended to avoid Dropdown value identity issues:
  @override
  bool operator ==(Object other) => other is Command && other.byte == byte;
  @override
  int get hashCode => byte.hashCode;

  Command(
      this.byte,
      this.internalName,
      this.displayName, {
        this.display = true,
        this.params = const [],
        this.voice = const []
      }) {
    registeredCommands[byte] = this;
  }

  Command._(
      this.byte,
      this.internalName, {
        this.displayName = '',
        this.display = false,
        this.params = const [],
        this.voice = const []
      }) {
    registeredCommands[byte] = this;
  }

  static Command fromByte(int b) {
    if (registeredCommands.containsKey(b)) return registeredCommands[b]!;
    throw FormatException('Unknown command byte: 0x${b.toRadixString(16).padLeft(2, '0')}');
  }

  @override
  String toString() {
    return internalName;
  }
}