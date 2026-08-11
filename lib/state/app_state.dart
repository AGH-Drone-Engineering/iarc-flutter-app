import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/drone.dart';
import '../models/link_config.dart';
import '../models/mission_message.dart';
import '../pathfinding/field_grid.dart' show ScanRegion;
import '../services/command_tracker.dart';
import '../services/debug_traffic.dart';
import '../services/demo_runner.dart';
import '../services/link_probe.dart';
import '../services/global_log.dart';
import '../services/lora_link_service.dart';
import '../services/udp_link_service.dart';
import '../services/mission_transport.dart';
import 'mission_limits.dart';

const _tag = 'app';

class AppState extends ChangeNotifier {
  AppState() {
    Drone.ensureRegistered();
    lora = LoraLinkService();
    udp = UdpLinkService();
    config = LinkConfig.defaults(Drone.allIds);
    tracker = CommandTracker(
      sender: (dest, msg) => transport.sendMission(dest, msg),
      knownDrones: Drone.allIds,
    );
    demo = DemoRunner(tracker: tracker);
    debug = DebugTraffic(tracker: tracker);
    probe = LinkProbe(tracker: tracker);
    tracker.addListener(notifyListeners);
    demo.addListener(notifyListeners);
    debug.addListener(notifyListeners);
    probe.addListener(notifyListeners);
  }

  late final LoraLinkService lora;
  late final UdpLinkService udp;
  late final CommandTracker tracker;
  late final DemoRunner demo;
  late final DebugTraffic debug;
  late final LinkProbe probe;

  late LinkConfig config;

  MissionTransport get transport =>
      _testTransport ?? (config.transport == TransportKind.udp ? udp : lora);

  MissionTransport? _testTransport;

  /// Stand a fake link in for the real ones, and listen to it.
  ///
  /// The uplink-ACK contract is about what the app puts back on the wire, which
  /// is otherwise only observable through a USB serial port or a socket.
  @visibleForTesting
  void useTransportForTest(MissionTransport t) {
    _testTransport = t;
    _subs.add(t.missionStream.listen(_onMission));
  }

  static const _kLinkKey = 'link_config_v1';
  static const _kCornersKey = 'corners_v1';
  static const _kDemoAltKey = 'demo_alt_v1';
  static const _kLockstepKey = 'demo_lockstep_v1';
  static const _kClearanceKey = 'demo_clearance_v1';
  static const _kSettleKey = 'demo_settle_v1';
  static const _kMainAltKey = 'main_alt_v1';
  static const _kVertexKey = 'demo_vertices_v1';
  static const _kRadiusKey = 'demo_radius_v1';
  static const _kVoiceLocaleKey = 'voice_locale_v1';

  SharedPreferences? _prefs;
  Future<SharedPreferences> _ensurePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  final List<LatLng?> corners = List<LatLng?>.filled(4, null, growable: false);
  final List<MineReport> mines = [];

  /// Prostokąty zgłoszone przez drony jako przeskanowane.
  ///
  /// Kumulują się i mogą się nakładać -- dron nie musi pamiętać, co już
  /// wysłał. Bez nich pole jest w całości nieznane, a więc nieprzejezdne.
  final List<ScanRegion> scans = [];

  double demoAltitude = 3.0;
  double mainAltitude = 2.0;

  /// Shape of the demo figure. Lives here, not on the drone: MOVE carries
  /// absolute coordinates, so changing it needs no drone-side release.
  int get demoVertices => demo.vertexCount;
  double get demoRadius => demo.radiusMeters;
  bool get demoLockstep => demo.lockstep;
  double get demoClearance => demo.clearanceMeters;

  /// Pause between a drone being seen on its vertex and the next step going
  /// out, in seconds.
  double get demoSettleSeconds => demo.settleDelay.inMilliseconds / 1000;

  /// Language the speech recogniser listens in, `pl` or `en`. The parser takes
  /// both regardless -- this only picks the acoustic model, which the engine
  /// will not switch on its own mid-sentence.
  String voiceLocale = 'pl';

  String connectionStatus = 'No device connected';
  LatLng? userLocation;
  double? headingDegrees;

  int _selectedTarget = kBroadcastAddress;
  int get selectedTarget => _selectedTarget;

  final _subs = <StreamSubscription<Object?>>[];

  bool get isConnected => transport.isConnected;

  /// Worst horizontal accuracy any drone is currently reporting, in metres, or
  /// null when none of them report one. This is what the operator's clearance
  /// margin sits on top of, so it belongs next to the control that sets it.
  double? get worstReportedAccuracy {
    final reported = Drone.all
        .map((d) => d.accuracyMeters)
        .whereType<double>();
    return reported.isEmpty ? null : reported.reduce((a, b) => a > b ? a : b);
  }
  List<Drone> get drones => Drone.all;

  Future<void> init() async {
    await _loadLinkConfig();
    for (final t in [lora, udp]) {
      _listenTo(t);
    }
    await Future.wait([_loadCorners(), _loadSettings()]);
  }

  void _listenTo(MissionTransport t) {
    _subs.add(t.statusStream.listen((s) {
      if (t.kind != config.transport) return;
      connectionStatus = s;
      notifyListeners();
    }));
    _subs.add(t.stateStream.listen((s) {
      if (t.kind != config.transport) return;
      if (s == LinkState.disconnected) {
        logTrace(_tag, 'link down: clearing tracker and drone telemetry');
        demo.stop();
        debug.stop();
        tracker.reset();
        for (final d in Drone.all) {
          d.reset();
        }
      }
      notifyListeners();
    }));
    _subs.add(t.missionStream.listen((m) {
      if (t.kind != config.transport) return;
      _onMission(m);
    }));
  }

  Future<void> _loadLinkConfig() async {
    final p = await _ensurePrefs();
    final raw = p.getString(_kLinkKey);
    if (raw != null) config = LinkConfig.decode(raw, Drone.allIds);
    notifyListeners();
  }

  Future<void> _saveLinkConfig() async {
    (await _ensurePrefs()).setString(_kLinkKey, config.encode());
  }

  Future<void> setTransport(TransportKind kind) async {
    if (config.transport == kind) return;
    await transport.disconnect();
    config = config.copyWith(transport: kind);
    connectionStatus = 'Switched to ${kind.label}';
    logInfo('Transport switched to ${kind.label}', _tag);
    notifyListeners();
    await _saveLinkConfig();
  }

  Future<void> setUdpListenPort(int port) async {
    config = config.copyWith(listenPort: port);
    notifyListeners();
    await _saveLinkConfig();
  }

  Future<void> setUdpEndpoint(int droneId, {String? host, int? port}) async {
    config = config.withEndpoint(droneId, host: host, port: port);
    notifyListeners();
    await _saveLinkConfig();
  }

  Future<bool> connectUdp() => udp.connect(config);

  Future<void> disconnectActive() => transport.disconnect();

  void _onMission(IncomingMission incoming) {
    final drone = Drone.byId(incoming.from);
    if (drone == null) {
      logWarn('Message from unregistered node ${incoming.from}', _tag);
    }
    drone?.markSeen();

    switch (incoming.message) {
      case TelemMessage t:
        drone?.applyTelemetry(t);
        demo.handleTelemetry(incoming.from, t);
        logTrace(_tag, '${Drone.nameFor(incoming.from)} st=${t.state.wire} '
            'alt=${t.altitude} bat=${t.battery ?? "-"} '
            'pos=${t.position.latitude},${t.position.longitude}');
      case MineMessage m:
        if (_acknowledgeReport(incoming.from, m.seq, 'MINE')) {
          _recordMine(incoming.from, m);
        }
      case ScanMessage s:
        if (!_acknowledgeReport(incoming.from, s.seq, 'SCAN')) break;
        scans.add(ScanRegion(s.cornerA, s.cornerB));
        logInfo(
          'Scan region from ${Drone.nameFor(incoming.from)}: '
          '${s.cornerA.latitude.toStringAsFixed(7)},'
          '${s.cornerA.longitude.toStringAsFixed(7)} .. '
          '${s.cornerB.latitude.toStringAsFixed(7)},'
          '${s.cornerB.longitude.toStringAsFixed(7)} '
          '(${scans.length} łącznie)',
          _tag,
        );
      case ArrivedMessage a:
        // Potwierdzamy zawsze, przekazujemy raz. Powtórka znaczy tylko tyle, że
        // nasze poprzednie ACK nie doszło - dron stoi tam, gdzie stał, a drugie
        // zwolnienie bariery przestawiłoby szyk o wierzchołek za daleko.
        if (_acknowledgeReport(incoming.from, a.seq, 'ARRIVED')) {
          demo.handleArrived(incoming.from, a);
        }
      case PongMessage p:
        // Straight to the probe and nowhere else. Deliberately not answered:
        // a reply would add a transmission to the thing being measured.
        probe.handlePong(incoming.from, p);
      case EventMessage e:
        drone?.lastEvent = e.event;
        demo.handleEvent(incoming.from, e.event);
        logInfo('${Drone.nameFor(incoming.from)}: ${e.event.wire}', _tag);
      default:
        break;
    }

    tracker.handleIncoming(incoming.from, incoming.message);
    notifyListeners();
  }

  final Set<String> _reportsSeen = {};
  final List<String> _reportOrder = [];

  /// Ile potwierdzonych raportów pamiętamy, żeby rozpoznać powtórkę.
  ///
  /// Dron powtarza MINE/SCAN aż do potwierdzenia, więc zgubione ACK wraca do
  /// nas jako ta sama wiadomość z tym samym `q`. Pamięć jest ograniczona, bo
  /// SCAN leci raz na klatkę; gdyby powtórka przyszła po wypadnięciu z pamięci,
  /// minę i tak wyłapie scalanie po znaczniku i pozycji, a powtórzony SCAN jest
  /// nieszkodliwy (to ten sam prostokąt).
  static const int _reportMemory = 1024;

  /// Potwierdza raport drona i mówi, czy widzimy go PIERWSZY raz.
  ///
  /// ACK wychodzi zawsze, także dla powtórki: skoro dron pyta ponownie, to
  /// znaczy, że poprzedniego potwierdzenia nie dostał. Zapisujemy natomiast
  /// tylko za pierwszym razem - inaczej jedna mina zgłoszona trzy razy byłaby
  /// trzema minami.
  final Map<int, int> _lastReportSeq = {};

  /// O tyle niższy numer uznajemy za restart licznika, a nie za spóźnioną
  /// ramkę. Raporty idą po kilka na przelot, więc okno jest wielokrotnie
  /// szersze niż jakiekolwiek realne wyprzedzenie na łączu.
  static const int _seqRestartWindow = 64;

  /// Licznik `q` należy do drona i startuje od 1 przy każdym uruchomieniu
  /// skryptu na Pi. W logu z 2026-08-10 widać to wprost: 119 -> 1 o 14:02:25,
  /// w środku jednej sesji aplikacji.
  ///
  /// Pamięć powtórek jest kluczowana `(dron, q)`, więc bez wykrycia restartu
  /// pierwsze kilkadziesiąt meldunków po restarcie drona wyglądałoby jak
  /// powtórki sprzed restartu i zostałoby po cichu wyrzucone. Dla MINE/SCAN
  /// znaczyłoby to zgubioną minę; dla ARRIVED - szyk, który nigdy nie rusza,
  /// bo dolot dociera, jest potwierdzany i nigdzie nie trafia.
  void _forgetReportsIfCounterRestarted(int from, int seq) {
    final highest = _lastReportSeq[from];
    if (highest != null && seq + _seqRestartWindow < highest) {
      final prefix = '$from/';
      _reportsSeen.removeWhere((k) => k.startsWith(prefix));
      _reportOrder.removeWhere((k) => k.startsWith(prefix));
      logWarn(
          '${Drone.nameFor(from)}: numeracja raportów spadła z $highest na $seq '
          '- dron wystartował od nowa, czyszczę pamięć powtórek',
          _tag);
      _lastReportSeq[from] = seq;
      return;
    }
    if (highest == null || seq > highest) _lastReportSeq[from] = seq;
  }

  /// Czy ten raport widzimy pierwszy raz.
  ///
  /// Nie odsyłamy już żadnego ACK-a: dron nie czeka na potwierdzenie i niczego
  /// nie powtarza, bo doniesienie ramki należy do warstwy LoRa. Pamięć o
  /// widzianych `q` zostaje mimo to - gdyby radio dostarczyło ramkę dwa razy,
  /// drugi ARRIVED przestawiłby szyk o wierzchołek za daleko, a druga mina
  /// pojawiłaby się na mapie podwójnie.
  bool _acknowledgeReport(int from, int seq, String kind) {
    _forgetReportsIfCounterRestarted(from, seq);

    final key = '$from/$seq';
    if (!_reportsSeen.add(key)) {
      logWarn('Powtórka $kind q=$seq od ${Drone.nameFor(from)} - radio '
          'dostarczyło ją dwa razy; pomijam, nie działam drugi raz', _tag);
      return false;
    }
    _reportOrder.add(key);
    if (_reportOrder.length > _reportMemory) {
      _reportsSeen.remove(_reportOrder.removeAt(0));
    }
    return true;
  }

  /// Dwa zgłoszenia to ta sama mina tylko przy zgodnym znaczniku *i* pozycji.
  ///
  /// Próg jest rzędu błędu GPS. Powyżej niego ten sam znacznik w dwóch
  /// miejscach oznacza dwie miny -- albo ten sam kod naklejono dwa razy, albo
  /// odczyt był błędny. W obu przypadkach zgubienie jednej z nich jest gorsze
  /// niż pokazanie obu. Odwrotny przypadek, dwa różne znaczniki w tym samym
  /// miejscu, też daje dwie miny -- tu nie ma żadnego scalania.
  static const double _mineDedupeMeters = 3.0;

  /// `roundResult` domyślnie TRUE w latlong2 - bez tego każdy dystans jest
  /// zaokrąglany do pełnych metrów, a próg scalania ma tu 3 m. Dwie miny 3.4 m
  /// od siebie wyszłyby jako 3 m i zostałyby uznane za jedną: dokładnie ta
  /// strata, przed którą ostrzega komentarz wyżej.
  static const Distance _distance = Distance(roundResult: false);

  int _nextMineId = 1;

  void _recordMine(int from, MineMessage m) {
    final duplicate = mines.any(
      (e) =>
          e.tag == m.tag &&
          _distance.as(LengthUnit.Meter, e.position, m.position) <=
              _mineDedupeMeters,
    );
    if (duplicate) return;

    final report = MineReport(
      id: _nextMineId++,
      tag: m.tag,
      position: m.position,
      reportedBy: from,
      at: DateTime.now(),
    );
    mines.add(report);

    final sameTag = mines.where((e) => e.tag == m.tag).length;
    final suffix = sameTag > 1
        ? ' (znacznik ${m.tag} widziany już w $sameTag miejscach)'
        : '';
    logInfo(
      'Mine ${m.tag} [#${report.id}] reported by ${Drone.nameFor(from)} at '
      '${m.position.latitude.toStringAsFixed(7)}, '
      '${m.position.longitude.toStringAsFixed(7)}$suffix',
      _tag,
    );
  }

  /// Which drones this demo is for. An arbitrary subset, because which airframes
  /// are on the field changes between tests -- "1, 2 and 4" has to be sayable.
  ///
  /// It also decides where the uplink goes. Broadcast addressed all four
  /// regardless of what was switched on, so on 2026-08-10 half of every
  /// `START_DEMO` burst and its retries went to drones that could never answer,
  /// competing for airtime with the two that could.
  final Set<int> demoRoster = {...Drone.allIds};

  void toggleDemoRoster(int id) {
    if (!demoRoster.remove(id)) demoRoster.add(id);
    notifyListeners();
  }

  List<int> get _demoTargets {
    final chosen = Drone.allIds.where(demoRoster.contains).toList();
    return chosen.isEmpty ? Drone.allIds : chosen;
  }

  Future<void> startDemo({int? target}) {
    final targets = target != null && target != kBroadcastAddress
        ? <int>[target]
        : _demoTargets;
    logTrace(_tag, 'startDemo alt=$demoAltitude targets=[${targets.join(",")}]');
    return demo.start(targets, demoAltitude);
  }

  /// Release the mustered drones onto the figure. Returns why it refused, if it
  /// did, so the operator sees a reason rather than a button that does nothing.
  String? beginFormation() {
    final refusal = demo.beginFormation();
    if (refusal != null) logWarn('Formation not released: $refusal', _tag);
    notifyListeners();
    return refusal;
  }

  /// Step the formation on without waiting for every arrival report.
  String? forceNextStep() {
    final refusal = demo.forceNextStep();
    if (refusal != null) logWarn('Step not forced: $refusal', _tag);
    notifyListeners();
    return refusal;
  }

  /// Try again for a drone whose START_DEMO went unanswered, without disturbing
  /// the ones already holding.
  Future<String?> retryStart(int id) async {
    final refusal = await demo.addDrones([id]);
    if (refusal != null) logWarn('Could not re-add drone $id: $refusal', _tag);
    notifyListeners();
    return refusal;
  }

  /// Bring a joiner onto the formation's altitude, on its next step.
  String? mergeIntoFormation(int id) {
    final refusal = demo.mergeIntoFormation(id);
    if (refusal != null) logWarn('Could not merge drone $id: $refusal', _tag);
    notifyListeners();
    return refusal;
  }

  void stopDemo() => demo.stop();

  Future<bool> startMain({int? target}) async {
    final pts = orderedCorners;
    if (pts.length != 4) {
      logError('START_MAIN needs 4 corners, have ${pts.length}', _tag);
      return false;
    }
    logTrace(_tag, 'startMain alt=$mainAltitude corners='
        '${pts.map((c) => "[${c.latitude},${c.longitude}]").join(",")}');
    await tracker.send(
      (q) => StartMainMessage(seq: q, corners: pts, altitude: mainAltitude),
      dest: target ?? _selectedTarget,
    );
    return true;
  }

  Future<void> land({int? target}) => tracker.send(
        (q) => LandMessage(seq: q),
        dest: target ?? _selectedTarget,
      );

  Future<void> returnHome({int? target}) => tracker.send(
        (q) => RthMessage(seq: q),
        dest: target ?? _selectedTarget,
      );

  Future<void> requestStatus({int? target}) => tracker.send(
        (q) => StatusMessage(seq: q),
        dest: target ?? _selectedTarget,
      );

  void setSelectedTarget(int id) {
    if (_selectedTarget == id) return;
    _selectedTarget = id;
    logTrace(_tag, 'target=${Drone.nameFor(id)}');
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    final p = await _ensurePrefs();
    demoAltitude = p.getDouble(_kDemoAltKey) ?? 3.0;
    demo.vertexCount = p.getInt(_kVertexKey) ?? 8;
    demo.radiusMeters = p.getDouble(_kRadiusKey) ?? 5.0;
    demo.lockstep = p.getBool(_kLockstepKey) ?? true;
    demo.clearanceMeters = p.getDouble(_kClearanceKey) ?? 4.0;
    demo.settleDelay = _settleDuration(p.getDouble(_kSettleKey) ?? 1.0);
    mainAltitude = p.getDouble(_kMainAltKey) ?? 2.0;
    voiceLocale = p.getString(_kVoiceLocaleKey) ?? 'pl';
    notifyListeners();
  }

  /// The setters clamp because they are also the voice parser's way in, and a
  /// spoken number arrives without the stepper's end stops.
  Future<void> setDemoAltitude(double v) async {
    demoAltitude = demoAltitudeRange.clamp(v);
    notifyListeners();
    (await _ensurePrefs()).setDouble(_kDemoAltKey, demoAltitude);
  }

  Future<void> setDemoVertices(double v) async {
    demo.vertexCount = demoVerticesRange.clamp(v).round();
    notifyListeners();
    (await _ensurePrefs()).setInt(_kVertexKey, demo.vertexCount);
  }

  Future<void> setDemoRadius(double v) async {
    demo.radiusMeters = demoRadiusRange.clamp(v);
    notifyListeners();
    (await _ensurePrefs()).setDouble(_kRadiusKey, demo.radiusMeters);
  }

  /// Lockstep or off-step. Refused mid-demo: the two modes disagree about what
  /// keeps the drones apart, and swapping while they fly would leave the run
  /// half-governed by each.
  Future<void> setDemoLockstep(bool v) async {
    if (demo.isRunning) {
      logWarn('Cannot change formation mode while the demo is running', _tag);
      return;
    }
    demo.lockstep = v;
    notifyListeners();
    (await _ensurePrefs()).setBool(_kLockstepKey, v);
  }

  Future<void> setDemoClearance(double v) async {
    demo.clearanceMeters = demoClearanceRange.clamp(v);
    notifyListeners();
    (await _ensurePrefs()).setDouble(_kClearanceKey, demo.clearanceMeters);
  }

  /// Safe to change mid-run, unlike the figure or the formation mode: it only
  /// paces the steps.
  Future<void> setDemoSettle(double seconds) async {
    demo.settleDelay = _settleDuration(seconds);
    notifyListeners();
    (await _ensurePrefs()).setDouble(_kSettleKey, demoSettleSeconds);
  }

  static Duration _settleDuration(double seconds) =>
      Duration(milliseconds: (demoSettleRange.clamp(seconds) * 1000).round());

  Future<void> setMainAltitude(double v) async {
    mainAltitude = mainAltitudeRange.clamp(v);
    notifyListeners();
    (await _ensurePrefs()).setDouble(_kMainAltKey, mainAltitude);
  }

  Future<void> setVoiceLocale(String v) async {
    if (voiceLocale == v) return;
    voiceLocale = v;
    notifyListeners();
    (await _ensurePrefs()).setString(_kVoiceLocaleKey, v);
  }


  Future<void> _loadCorners() async {
    final prefs = await _ensurePrefs();
    final s = prefs.getString(_kCornersKey);
    if (s == null || s.isEmpty) return;
    try {
      final data = jsonDecode(s);
      if (data is List && data.length == 4) {
        for (var i = 0; i < 4; i++) {
          final e = data[i];
          corners[i] = (e is List && e.length >= 2)
              ? LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble())
              : null;
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _saveCorners() async {
    final prefs = await _ensurePrefs();
    final list =
        corners.map((c) => c == null ? null : [c.latitude, c.longitude]).toList();
    await prefs.setString(_kCornersKey, jsonEncode(list));
  }

  void setCorner(int index, LatLng? value) {
    if (index < 0 || index > 3) return;
    corners[index] = value;
    logTrace(_tag, 'corner[$index]=${value == null ? "cleared" : "${value.latitude},${value.longitude}"}');
    _saveCorners();
    notifyListeners();
  }

  void clearCorners() {
    for (var i = 0; i < 4; i++) {
      corners[i] = null;
    }
    _saveCorners();
    notifyListeners();
  }

  List<LatLng> get filledCorners => corners.whereType<LatLng>().toList();
  bool get hasFourCorners => corners.every((c) => c != null);

  List<LatLng> get orderedCorners {
    final pts = filledCorners;
    if (pts.length != 4) return pts;

    final perms = <List<int>>[];
    void gen(List<int> curr, List<int> rem) {
      if (rem.isEmpty) {
        perms.add(List<int>.from(curr));
        return;
      }
      for (var i = 0; i < rem.length; i++) {
        final next = List<int>.from(rem)..removeAt(i);
        gen(List<int>.from(curr)..add(rem[i]), next);
      }
    }

    gen([], [0, 1, 2, 3]);

    double polygonArea(List<LatLng> p) {
      double a = 0.0;
      for (int i = 0; i < p.length; i++) {
        final j = (i + 1) % p.length;
        a += p[i].longitude * p[j].latitude - p[j].longitude * p[i].latitude;
      }
      return a / 2.0;
    }

    bool onSeg(LatLng a, LatLng b, LatLng c) {
      return (c.longitude <= (a.longitude > b.longitude ? a.longitude : b.longitude) &&
              c.longitude >= (a.longitude < b.longitude ? a.longitude : b.longitude) &&
              c.latitude <= (a.latitude > b.latitude ? a.latitude : b.latitude) &&
              c.latitude >= (a.latitude < b.latitude ? a.latitude : b.latitude)) &&
          ((b.longitude - a.longitude) * (c.latitude - a.latitude) -
                  (b.latitude - a.latitude) * (c.longitude - a.longitude))
              .abs() <
              1e-12;
    }

    int orient(LatLng a, LatLng b, LatLng c) {
      final val = (b.latitude - a.latitude) * (c.longitude - b.longitude) -
          (b.longitude - a.longitude) * (c.latitude - b.latitude);
      if (val.abs() < 1e-12) return 0;
      return val > 0 ? 1 : 2;
    }

    bool segIntersect(LatLng p1, LatLng q1, LatLng p2, LatLng q2) {
      final o1 = orient(p1, q1, p2);
      final o2 = orient(p1, q1, q2);
      final o3 = orient(p2, q2, p1);
      final o4 = orient(p2, q2, q1);

      if (o1 != o2 && o3 != o4) return true;

      if (o1 == 0 && onSeg(p1, q1, p2)) return true;
      if (o2 == 0 && onSeg(p1, q1, q2)) return true;
      if (o3 == 0 && onSeg(p2, q2, p1)) return true;
      if (o4 == 0 && onSeg(p2, q2, q1)) return true;

      return false;
    }

    bool simpleQuad(List<LatLng> p) {
      final a = p[0], b = p[1], c = p[2], d = p[3];
      if (segIntersect(a, b, c, d)) return false;
      if (segIntersect(b, c, d, a)) return false;
      return true;
    }

    List<LatLng>? best;
    double bestAbsArea = -1;

    for (final idx in perms) {
      var poly = [pts[idx[0]], pts[idx[1]], pts[idx[2]], pts[idx[3]]];
      if (simpleQuad(poly)) {
        var area = polygonArea(poly);
        if (area < 0) {
          poly = poly.reversed.toList();
          area = -area;
        }
        if (area > bestAbsArea) {
          best = poly;
          bestAbsArea = area;
        }
      }
    }

    return best ?? pts;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    debug.removeListener(notifyListeners);
    debug.dispose();
    demo.removeListener(notifyListeners);
    demo.dispose();
    tracker.removeListener(notifyListeners);
    tracker.dispose();
    lora.dispose();
    udp.dispose();
    super.dispose();
  }
}
