import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../services/lora_frame.dart';

const int kProtocolVersion = 1;
const int kBroadcastAddress = 0xFF; // RFNet's ADDR_BROADCAST

class MissionMessageException implements Exception {
  final String message;
  const MissionMessageException(this.message);
  @override
  String toString() => 'MissionMessageException: $message';
}

class UnsupportedMessageTypeException extends MissionMessageException {
  final String messageType;
  final int? seq;
  const UnsupportedMessageTypeException(this.messageType, this.seq)
      : super('Unsupported message type: $messageType');
}

enum DroneState {
  boot('BOOT'),
  idle('IDLE'),
  arming('ARMING'),
  takeoff('TAKEOFF'),
  hover('HOVER'),
  demo('DEMO'),
  main('MAIN'),
  rth('RTH'),
  landing('LANDING'),
  landed('LANDED'),
  error('ERROR'),
  killed('KILLED');

  const DroneState(this.wire);
  final String wire;

  static DroneState fromWire(String s) => DroneState.values.firstWhere(
        (d) => d.wire == s,
        orElse: () => throw MissionMessageException('Unknown state: $s'),
      );

  bool get isAirborne => const {
        DroneState.takeoff,
        DroneState.hover,
        DroneState.demo,
        DroneState.main,
        DroneState.rth,
        DroneState.landing,
      }.contains(this);
}

enum NackError {
  noGps('NO_GPS'),
  notArmed('NOT_ARMED'),
  busy('BUSY'),
  badState('BAD_STATE'),
  badParam('BAD_PARAM'),
  geofence('GEOFENCE'),
  lowBatt('LOW_BATT'),
  unsupported('UNSUPPORTED');

  const NackError(this.wire);
  final String wire;

  static NackError fromWire(String s) => NackError.values.firstWhere(
        (e) => e.wire == s,
        orElse: () => throw MissionMessageException('Unknown error: $s'),
      );
}

enum MissionEvent {
  missionStart('MISSION_START'),
  waypointReached('WAYPOINT_REACHED'),
  missionDone('MISSION_DONE'),
  rthStart('RTH_START'),
  landed('LANDED'),
  abort('ABORT');

  const MissionEvent(this.wire);
  final String wire;

  static MissionEvent fromWire(String s) => MissionEvent.values.firstWhere(
        (e) => e.wire == s,
        orElse: () => throw MissionMessageException('Unknown event: $s'),
      );
}

sealed class MissionMessage {
  final int version;
  final int seq;

  const MissionMessage({required this.seq, this.version = kProtocolVersion});

  String get type;
  Map<String, Object?> get fields;

  bool get expectsAck => false;

  Map<String, Object?> toJson() => _plain(_envelope) as Map<String, Object?>;

  Map<String, Object?> get _envelope => {
        'v': version,
        'q': seq,
        't': type,
        ...fields,
      };

  String encode() => _writeJson(_envelope);

  Uint8List encodeBytes() {
    final bytes = Uint8List.fromList(utf8.encode(encode()));
    if (bytes.length > kMaxMessageSize) {
      throw MissionMessageException(
        '$type encodes to ${bytes.length} bytes, over the $kMaxMessageSize-byte limit',
      );
    }
    return bytes;
  }

  static MissionMessage decodeBytes(Uint8List payload) =>
      decode(utf8.decode(payload, allowMalformed: true));

  static MissionMessage decode(String raw) {
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException catch (e) {
      throw MissionMessageException('Malformed JSON: ${e.message}');
    }
    if (parsed is! Map<String, Object?>) {
      throw const MissionMessageException('Payload is not a JSON object');
    }

    final version = _int(parsed, 'v');
    final seq = _int(parsed, 'q');
    if (version != kProtocolVersion) {
      throw MissionMessageException(
        'Unsupported protocol version $version (expected $kProtocolVersion)',
      );
    }

    final type = _string(parsed, 't');
    return switch (type) {
      'ACK' => AckMessage(
          seq: seq,
          respondingTo: _int(parsed, 're'),
          position: parsed.containsKey('lat') && parsed.containsKey('lon')
              ? LatLng(_double(parsed, 'lat'), _double(parsed, 'lon'))
              : null,
        ),
      'NACK' => NackMessage(
          seq: seq,
          respondingTo: _int(parsed, 're'),
          error: NackError.fromWire(_string(parsed, 'err')),
        ),
      'TELEM' => TelemMessage(
          seq: seq,
          position: LatLng(_double(parsed, 'lat'), _double(parsed, 'lon')),
          altitude: _double(parsed, 'alt'),
          battery: _optionalDouble(parsed, 'bat'),
          batteryPercent: _optionalDouble(parsed, 'pct')?.round(),
          state: DroneState.fromWire(_string(parsed, 'st')),
          sampleMs: _optionalDouble(parsed, 'ts')?.round(),
          velocity: _optionalVelocity(parsed),
          accuracyMeters: _optionalDouble(parsed, 'acc'),
        ),
      'MINE' => MineMessage(
          seq: seq,
          tag: _int(parsed, 'tag'),
          position: LatLng(_double(parsed, 'lat'), _double(parsed, 'lon')),
        ),
      'EVT' =>
          EventMessage(
            seq: seq,
            event: MissionEvent.fromWire(_string(parsed, 'ev')),
            at: parsed.containsKey('at') ? _latLonPair(parsed, 'at') : null,
          ),
      'SCAN' => ScanMessage(
          seq: seq,
          cornerA: _latLonPair(parsed, 'a'),
          cornerB: _latLonPair(parsed, 'b'),
        ),
      'ARRIVED' => ArrivedMessage(
          seq: seq,
          target: _latLonPair(parsed, 'to'),
          at: _latLonPair(parsed, 'at'),
          speed: _optionalDouble(parsed, 'spd'),
        ),
      'START_DEMO' => StartDemoMessage(seq: seq, altitude: _double(parsed, 'alt')),
      'START_MAIN' => StartMainMessage(
          seq: seq,
          corners: _corners(parsed),
          altitude: _double(parsed, 'alt'),
        ),
      'MOVE' => MoveMessage(
          seq: seq,
          target: _latLonPair(parsed, 'to'),
          altitude: _optionalDouble(parsed, 'alt'),
        ),
      'LAND' => LandMessage(seq: seq),
      'RTH' => RthMessage(seq: seq, altitude: _optionalDouble(parsed, 'alt')),
      'STATUS' => StatusMessage(seq: seq),
      'PING' => PingMessage(seq: seq, n: _int(parsed, 'n')),
      'PONG' => PongMessage(
          seq: seq,
          rx: _int(parsed, 'rx'),
          tx: _int(parsed, 'tx'),
          last: _int(parsed, 'last'),
        ),
      _ => throw UnsupportedMessageTypeException(type, seq),
    };
  }
}

class StartDemoMessage extends MissionMessage {
  final double altitude;
  const StartDemoMessage({required super.seq, required this.altitude});

  @override
  String get type => 'START_DEMO';
  @override
  bool get expectsAck => true;
  @override
  Map<String, Object?> get fields => {'alt': _round(altitude, 2)};
}

class StartMainMessage extends MissionMessage {
  final List<LatLng> corners;
  final double altitude;

  StartMainMessage({
    required super.seq,
    required this.corners,
    required this.altitude,
  }) {
    if (corners.length != 4) {
      throw MissionMessageException(
        'START_MAIN needs exactly 4 corners, got ${corners.length}',
      );
    }
    if (altitude < 0.5 || altitude > 30.0) {
      throw MissionMessageException(
        'START_MAIN altitude $altitude is outside 0.5..30.0 m',
      );
    }
  }

  @override
  String get type => 'START_MAIN';
  @override
  bool get expectsAck => true;
  @override
  Map<String, Object?> get fields => {
        'c': [
          for (final c in corners) [_round(c.latitude, 7), _round(c.longitude, 7)],
        ],
        'alt': _round(altitude, 2),
      };
}

class MoveMessage extends MissionMessage {
  /// Absolute target. Hops carry no reference frame of their own, so they
  /// cannot drift and both ends agree without sharing an origin.
  final LatLng target;

  /// Height for this hop, or null to fly it at the demo's altitude.
  ///
  /// Set only for a drone deliberately being flown off the rest -- a late joiner
  /// walking the same vertex indices a metre away vertically. Dropping the field
  /// again on a later step is how it merges back in: it is on the same vertex
  /// index at both ends of that leg, so it stays its anchor spacing from
  /// everybody throughout and may change height while translating.
  final double? altitude;

  const MoveMessage({required super.seq, required this.target, this.altitude});

  @override
  String get type => 'MOVE';
  @override
  bool get expectsAck => true;
  @override
  Map<String, Object?> get fields => {
        'to': [_round(target.latitude, 7), _round(target.longitude, 7)],
        if (altitude != null) 'alt': _round(altitude!, 2),
      };
}

class LandMessage extends MissionMessage {
  const LandMessage({required super.seq});
  @override
  String get type => 'LAND';
  @override
  bool get expectsAck => true;
  @override
  Map<String, Object?> get fields => const {};
}

class RthMessage extends MissionMessage {
  /// Height to return at, or null for the drone's own assigned RTH altitude.
  ///
  /// Given when the return has to avoid a formation that is still flying: the
  /// drone reaches this height *in place* before it translates, so it leaves the
  /// altitude the others are using before it crosses their circles. Without that
  /// ordering an RTH is a diagonal straight through them, which is why aborts
  /// used to be `LAND` and never this.
  final double? altitude;

  const RthMessage({required super.seq, this.altitude});
  @override
  String get type => 'RTH';
  @override
  bool get expectsAck => true;
  @override
  Map<String, Object?> get fields => {
        if (altitude != null) 'alt': _round(altitude!, 2),
      };
}

class StatusMessage extends MissionMessage {
  const StatusMessage({required super.seq});
  @override
  String get type => 'STATUS';
  @override
  bool get expectsAck => true;
  @override
  Map<String, Object?> get fields => const {};
}

class AckMessage extends MissionMessage {
  final int respondingTo;

  /// Where the drone was when it accepted the command, when it had a fix.
  /// A `START_DEMO` ACK's position is the anchor the demo figure is laid around.
  final LatLng? position;

  const AckMessage({
    required super.seq,
    required this.respondingTo,
    this.position,
  });

  @override
  String get type => 'ACK';
  @override
  Map<String, Object?> get fields => {
        're': respondingTo,
        if (position != null) ...{
          'lat': _round(position!.latitude, 7),
          'lon': _round(position!.longitude, 7),
        },
      };
}

class NackMessage extends MissionMessage {
  final int respondingTo;
  final NackError error;
  const NackMessage({
    required super.seq,
    required this.respondingTo,
    required this.error,
  });
  @override
  String get type => 'NACK';
  @override
  Map<String, Object?> get fields => {'re': respondingTo, 'err': error.wire};
}

class TelemMessage extends MissionMessage {
  final LatLng position;
  final double altitude;
  /// Pack voltage. Raw and always available, but sags under load.
  final double? battery;

  /// Remaining charge, 0..100. What an operator should judge on, when the
  /// flight controller has a pack capacity configured to derive it from.
  final int? batteryPercent;

  final DroneState state;

  /// Ground velocity as (north, east) in m/s, straight from the drone's EKF.
  ///
  /// Worth more than it looks. The ground station would otherwise have to infer
  /// motion by differencing 1 Hz positions, which is noisy, a sample behind, and
  /// cannot tell a drone flying its leg from one drifting off it. This is the
  /// same estimate the autopilot navigates on — and with optical flow fused into
  /// it (`EK3_SRC1_VELXY = 5`), it is the sharpest number the vehicle produces.
  final ({double north, double east})? velocity;

  /// Speed over the ground in m/s, or null when the drone did not report it.
  double? get groundSpeed => velocity == null
      ? null
      : sqrt(velocity!.north * velocity!.north + velocity!.east * velocity!.east);

  /// Horizontal position accuracy in metres, or null when the drone has none.
  ///
  /// The GPS receiver's own 1-sigma, taken *before* the EKF fuses IMU and
  /// optical flow — so it bounds the error of [position] rather than measuring
  /// it. The filter's own number would be better and is not available: ArduPilot
  /// sends neither `ESTIMATOR_STATUS` nor `GLOBAL_POSITION_INT_COV`, and the
  /// variances in `EKF_STATUS_REPORT` are dimensionless test ratios.
  ///
  /// Pessimistic is the right direction here — this sizes a separation bubble.
  final double? accuracyMeters;

  /// When the drone READ this position, in milliseconds on its own monotonic
  /// clock (`ts` on the wire). Null from a drone that predates the field.
  ///
  /// Not a wall clock and not comparable to ours -- the drone has no RTC and no
  /// network, so its calendar time is whatever it booted with. What it is good
  /// for is age: paired with our receive time it separates "this fix is fresh"
  /// from "this frame sat in the radio queue for four seconds", which arrival
  /// time alone cannot tell you. See DroneClock.
  final int? sampleMs;

  const TelemMessage({
    required super.seq,
    required this.position,
    required this.altitude,
    required this.state,
    this.battery,
    this.batteryPercent,
    this.sampleMs,
    this.velocity,
    this.accuracyMeters,
  });

  @override
  String get type => 'TELEM';
  @override
  Map<String, Object?> get fields => {
        'lat': _round(position.latitude, 7),
        'lon': _round(position.longitude, 7),
        'alt': _round(altitude, 2),
        if (battery != null) 'bat': _round(battery!, 2),
        if (batteryPercent != null) 'pct': batteryPercent,
        'st': state.wire,
        if (velocity != null)
          'vel': [_round(velocity!.north, 2), _round(velocity!.east, 2)],
        if (accuracyMeters != null) 'acc': _round(accuracyMeters!, 2),
        if (sampleMs != null) 'ts': sampleMs,
      };
}

class MineMessage extends MissionMessage {
  final int tag;
  final LatLng position;
  const MineMessage({
    required super.seq,
    required this.tag,
    required this.position,
  });
  @override
  String get type => 'MINE';
  @override
  Map<String, Object?> get fields => {
        'tag': tag,
        'lat': _round(position.latitude, 7),
        'lon': _round(position.longitude, 7),
      };
}

class EventMessage extends MissionMessage {
  final MissionEvent event;
  final LatLng? at;

  const EventMessage({required super.seq, required this.event, this.at});
  @override
  String get type => 'EVT';
  @override
  Map<String, Object?> get fields => {
        'ev': event.wire,
        if (at != null) 'at': [_round(at!.latitude, 7), _round(at!.longitude, 7)],
      };
}

/// Prostokątny obszar uznany przez drona za przeskanowany.
///
/// Bez tego komunikatu stacja naziemna nie odróżnia „nie ma tu miny" od „nikt
/// tu nie patrzył". Dla wyznaczania ścieżki to różnica zasadnicza: teren
/// nieprzeskanowany jest traktowany jak zaminowany, bo nic o nim nie wiemy.
///
/// Prostokąt jest osiowany w lat/lon i zadany dwoma przeciwległymi
/// narożnikami; kolejność narożników nie ma znaczenia.
class ScanMessage extends MissionMessage {
  final LatLng cornerA;
  final LatLng cornerB;
  const ScanMessage({
    required super.seq,
    required this.cornerA,
    required this.cornerB,
  });
  @override
  String get type => 'SCAN';
  @override
  Map<String, Object?> get fields => {
        'a': [_round(cornerA.latitude, 7), _round(cornerA.longitude, 7)],
        'b': [_round(cornerB.latitude, 7), _round(cornerB.longitude, 7)],
      };
}

/// Dron melduje, że stanął na punkcie, do którego go wysłano (PROTOCOL.md §8).
///
/// To jedyna wiadomość, która przestawia szyk, więc jest raportem, a nie
/// zdarzeniem: dron powtarza ją aż do potwierdzenia. Zgubiony EVT operator co
/// najwyżej przeoczy, zgubiony dolot zatrzymuje figurę.
///
/// [target] to `to` z MOVE-a, odesłane z powrotem, i to ono czyni ten meldunek
/// samoidentyfikującym. Stacja naziemna zna krok, który jest w locie, więc
/// dolot z innym `to` jest dolotem tam, gdzie nikt nie kazał, i nie ma prawa
/// zwolnić bariery. Sama pozycja by tego nie rozstrzygnęła: na ciasnej figurze
/// sąsiednie wierzchołki leżą w promieniu tolerancji dolotu.
///
/// [at] to miejsce, w którym dron faktycznie stanął, a [speed] prędkość w tej
/// chwili — obie po to, żeby meldunek dało się sprawdzić, a nie tylko przyjąć.
class ArrivedMessage extends MissionMessage {
  final LatLng target;
  final LatLng at;
  final double? speed;

  const ArrivedMessage({
    required super.seq,
    required this.target,
    required this.at,
    this.speed,
  });

  @override
  String get type => 'ARRIVED';

  @override
  Map<String, Object?> get fields => {
        'to': [_round(target.latitude, 7), _round(target.longitude, 7)],
        'at': [_round(at.latitude, 7), _round(at.longitude, 7)],
        if (speed != null) 'spd': _round(speed!, 2),
      };
}

/// A numbered frame nobody answers, for measuring the radio itself.
///
/// [expectsAck] is false and the drone must not reply to it. That is the whole
/// design: loss on this link was being inferred from missing ACKs, and an ACK
/// cannot tell "the frame never arrived" from "the frame arrived and its answer
/// was lost" -- while costing a transmission of its own, so asking the question
/// changes the answer.
///
/// [n] counts pings independently of [seq]: the envelope sequence wraps and is
/// shared with every other message the app sends, whereas a gap in [n] is
/// exactly one lost ping.
class PingMessage extends MissionMessage {
  final int n;
  const PingMessage({required super.seq, required this.n});

  @override
  String get type => 'PING';
  @override
  bool get expectsAck => false;
  @override
  Map<String, Object?> get fields => {'n': n};
}

/// The drone's tally, sent on a timer and acknowledged by nobody.
///
/// [rx] PINGs seen, [tx] PONGs sent, [last] the newest ping number. Those three
/// against what the app counted separate the two directions, which is what a
/// missing ACK can never do:
///
///     uplink loss   = 1 - rx / pingsSent
///     downlink loss = 1 - pongsReceived / tx
class PongMessage extends MissionMessage {
  final int rx;
  final int tx;
  final int last;
  const PongMessage({
    required super.seq,
    required this.rx,
    required this.tx,
    required this.last,
  });

  @override
  String get type => 'PONG';
  @override
  Map<String, Object?> get fields => {'rx': rx, 'tx': tx, 'last': last};
}

class _Decimal {
  final String text;
  const _Decimal(this.text);

  double get value => double.parse(text);
}

_Decimal _round(double v, int places) {
  if (!v.isFinite) {
    throw MissionMessageException('Non-finite number: $v');
  }
  var s = v.toStringAsFixed(places);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s += '0';
  }
  return _Decimal(s);
}

/// Hand-rolled because jsonEncode emits exponent notation, which the spec forbids.
String _writeJson(Object? v) {
  if (v == null) return 'null';
  if (v is _Decimal) return v.text;
  if (v is int) return v.toString();
  if (v is bool) return v.toString();
  if (v is String) return jsonEncode(v);
  if (v is List) return '[${v.map(_writeJson).join(',')}]';
  if (v is Map) {
    final entries = v.entries
        .map((e) => '${jsonEncode(e.key.toString())}:${_writeJson(e.value)}')
        .join(',');
    return '{$entries}';
  }
  if (v is double) return _round(v, 7).text;
  throw MissionMessageException('Cannot serialise ${v.runtimeType}');
}

Object? _plain(Object? v) {
  if (v is _Decimal) return v.value;
  if (v is List) return v.map(_plain).toList();
  if (v is Map) {
    return <String, Object?>{
      for (final e in v.entries) e.key.toString(): _plain(e.value),
    };
  }
  return v;
}

Object? _require(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) {
    throw MissionMessageException('Missing required field "$key"');
  }
  return json[key];
}

int _int(Map<String, Object?> json, String key) {
  final v = _require(json, key);
  if (v is int) return v;
  if (v is num && v == v.roundToDouble()) return v.toInt();
  throw MissionMessageException('Field "$key" is not an integer: $v');
}

double _double(Map<String, Object?> json, String key) {
  final v = _require(json, key);
  if (v is num) return v.toDouble();
  throw MissionMessageException('Field "$key" is not a number: $v');
}

double? _optionalDouble(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is num) return v.toDouble();
  throw MissionMessageException('Field "$key" is not a number: $v');
}

String _string(Map<String, Object?> json, String key) {
  final v = _require(json, key);
  if (v is String) return v;
  throw MissionMessageException('Field "$key" is not a string: $v');
}

List<LatLng> _corners(Map<String, Object?> json) {
  final v = _require(json, 'c');
  if (v is! List || v.length != 4) {
    throw const MissionMessageException('Field "c" must be 4 [lat,lon] pairs');
  }
  return [
    for (final pair in v)
      if (pair is List && pair.length >= 2 && pair[0] is num && pair[1] is num)
        LatLng((pair[0] as num).toDouble(), (pair[1] as num).toDouble())
      else
        throw const MissionMessageException('Corner is not a [lat,lon] pair'),
  ];
}

LatLng _latLonPair(Map<String, Object?> json, String key) {
  final v = _require(json, key);
  if (v is! List || v.length < 2 || v[0] is! num || v[1] is! num) {
    throw MissionMessageException('Field "$key" must be a [lat,lon] pair');
  }
  final lat = (v[0] as num).toDouble();
  final lon = (v[1] as num).toDouble();
  // LatLng samo pilnuje zakresu, ale rzuca AssertionError, a tego wyżej nikt nie
  // łapie -- jedna przekręcona ramka zabiłaby odbiór do końca sesji. Sprawdzamy
  // więc sami i zgłaszamy to jak każde inne złe pole.
  if (lat.isNaN ||
      lon.isNaN ||
      lat < -90 ||
      lat > 90 ||
      lon < -180 ||
      lon > 180) {
    throw MissionMessageException(
      'Field "$key" is outside lat/lon range: $lat,$lon',
    );
  }
  return LatLng(lat, lon);
}

({double north, double east})? _optionalVelocity(Map<String, Object?> parsed) {
  final raw = parsed['vel'];
  if (raw is! List || raw.length < 2) return null;
  final north = raw[0], east = raw[1];
  if (north is! num || east is! num) return null;
  return (north: north.toDouble(), east: east.toDouble());
}

class SeqCounter {
  int _next = 1;
  int take() {
    final v = _next;
    _next = (_next + 1) & 0xFFFF;
    return v;
  }
}
