import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/mission_message.dart';
import '../pathfinding/local_frame.dart' show offsetLatLng;
import 'command_tracker.dart';
import 'conflict_monitor.dart';
import 'drone_clock.dart';
import 'global_log.dart';

const _tag = 'demo';

/// Where one drone is in the formation.
///
/// [holding] is the barrier: the drone has reached the vertex everybody is
/// walking to and is waiting for the others. [starting] is the same thing
/// before the first vertex -- waiting to be airborne and holding over its
/// anchor. Nobody leaves a barrier alone.
enum DemoPhase { starting, stepping, holding, landing, finished, stopped }

class DemoProgress {
  final int droneId;
  final DemoPhase phase;
  final int steps;
  final String? detail;

  /// The vertices this drone is walking, laid out around the anchor its
  /// `START_DEMO` ACK reported. Empty until that ACK arrives.
  final List<LatLng> figure;

  const DemoProgress({
    required this.droneId,
    required this.phase,
    this.steps = -1,
    this.detail,
    this.figure = const [],
  });

  DemoProgress copyWith({
    DemoPhase? phase,
    int? steps,
    String? detail,
    List<LatLng>? figure,
  }) =>
      DemoProgress(
        droneId: droneId,
        phase: phase ?? this.phase,
        steps: steps ?? this.steps,
        detail: detail ?? this.detail,
        figure: figure ?? this.figure,
      );

  bool get isActive =>
      phase == DemoPhase.starting ||
      phase == DemoPhase.stepping ||
      phase == DemoPhase.holding;

  /// Standing at its barrier point, waiting for the rest of the formation.
  bool get isWaiting => phase == DemoPhase.holding;

  /// The vertex this drone is flying to, or standing on. Null before takeoff.
  LatLng? targetIn(List<LatLng> figure) =>
      steps < 0 || figure.isEmpty ? null : figure[steps % figure.length];
}

/// Walks a swarm around one figure each, either in lockstep or independently.
///
/// The drones fly intersecting circles at a single altitude, so nothing but
/// their relative positions keeps them apart. There are two ways to arrange
/// that, and the operator picks one:
///
/// **Lockstep** ([lockstep] true, the default) -- separation by geometry. Four
/// identical figures anchored at each drone's own takeoff point are translated
/// copies of one another, so while every drone sits on the *same vertex index*
/// the distance between any pair is exactly the distance between their anchors,
/// constant, and it does not matter that the circles overlap. Stepping is a
/// barrier: nobody is sent to vertex k+1 until every drone has been seen
/// standing on vertex k. Let one drone slip a vertex and the guarantee is gone,
/// which is why a drone that cannot be shown to be in phase is landed.
///
/// **Off-step** -- separation by measurement. Each drone advances as soon as it
/// arrives, and the geometric guarantee no longer holds, so every step is first
/// checked against where the others are predicted to be ([ConflictMonitor]). A
/// step that would break clearance is held back rather than sent, and a pair
/// that ends up on a converging course anyway is landed. It buys a livelier
/// display for a weaker guarantee: prediction from 1 Hz positions with no
/// reported GPS accuracy is an estimate, not a proof.
///
/// Either way an abort is `LAND`, never `RTH`: landing drops the drone out of
/// the shared altitude where it stands, while a return home would fly it
/// horizontally across everybody else's circle at exactly their altitude.
class DemoRunner extends ChangeNotifier {
  DemoRunner({
    required CommandTracker tracker,
    this.maxSteps = 200,
    this.vertexCount = 8,
    this.radiusMeters = 5.0,
    this.lockstep = true,
    double clearanceMeters = 4.0,
    this.settleDelay = Duration.zero,
    this.barrierTimeout = const Duration(seconds: 6),
    this.stragglerProbeInterval = const Duration(seconds: 4),
    this.stationarySpeedMeters = 0.6,
    this.altitudeToleranceMeters = 1.2,
    this.telemetryTimeout = const Duration(seconds: 4),
    this.groundTelemetryTimeout = const Duration(seconds: 40),
    this.legTimeout = const Duration(seconds: 30),
    this.watchdogPeriod = const Duration(milliseconds: 500),
  })  : _tracker = tracker,
        _conflicts = ConflictMonitor(clearanceMeters: clearanceMeters) {
    _tracker.onAcknowledged = _onAcknowledged;
    _tracker.onFailed = _onFailed;
  }

  final CommandTracker _tracker;
  final int maxSteps;

  /// The figure is a regular polygon around the anchor. The ground station owns
  /// it now: `MOVE` carries absolute coordinates, so the drone stores no routine
  /// and a changed shape needs no drone-side release -- which is why these are
  /// operator-settable rather than constants. They are frozen for the duration
  /// of a run: changing either mid-flight would redefine every drone's figure
  /// and, with it, what being in phase means.
  int vertexCount;
  double radiusMeters;

  /// Hold the formation on one vertex index, or let each drone run at its own
  /// pace.
  ///
  /// Lockstep is separation by geometry: identical figures on the same vertex
  /// stay exactly their anchors apart, whatever the circles do. Off-step there
  /// is no such guarantee, so every step is checked against everybody else's
  /// predicted path first ([ConflictMonitor]) and a step that would break
  /// clearance is held back rather than sent.
  ///
  /// Frozen for the duration of a run, like the figure.
  bool lockstep;

  final ConflictMonitor _conflicts;

  /// Separation to keep between drones when off-step. Nothing on the wire says
  /// how accurate a fix is, so this is the operator's call -- see
  /// [ConflictMonitor].
  double get clearanceMeters => _conflicts.clearanceMeters;
  set clearanceMeters(double v) => _conflicts.clearanceMeters = v;

  /// How long a drone stands on a vertex before it is sent to the next one.
  ///
  /// A drone that has just been declared arrived is still bleeding off the
  /// approach: the flight controller calls the waypoint reached inside 1.5 m,
  /// and the first HOVER frame after it can arrive while the airframe is still
  /// swinging. Commanding the next leg at that instant turns the overshoot into
  /// the start of the next one. This pause lets it settle on the vertex first.
  ///
  /// Zero keeps the old behaviour -- step as soon as the arrival is confirmed.
  /// Unlike the figure it may be changed mid-run: it paces the formation and
  /// changes nothing about what keeps the drones apart.
  Duration settleDelay;

  /// How long a drone may be overdue at its vertex before we go and ask it.
  ///
  /// In lockstep this is a *probe* trigger, not a sentence. It used to land
  /// whoever had not reported arriving within this long of the first drone
  /// getting there, which made a lost `ARRIVED` indistinguishable from a drone
  /// that never arrived -- and on a link losing a third of its frames those are
  /// wildly different likelihoods. The drone's own retry schedule is
  /// `UPLINK_RETRY_BASE = 2.5` doubling (`comms/link.py`), so attempts land at
  /// t=0, 2.5, 7.5, 17.5 s: a six second window admits two of them, and both
  /// being lost at 35% is a 12% event *per barrier*. Over a six-vertex lap that
  /// is better than even odds of a healthy drone being landed for arriving.
  ///
  /// So the timeout now starts a conversation instead: see [_probeStraggler].
  /// What still lands a drone that has genuinely stopped flying is [legTimeout],
  /// which measures the thing that actually has to happen, and an unanswered
  /// `STATUS`, which is evidence rather than absence of it.
  ///
  /// Off-step it keeps its old meaning -- there it is the clock on a drone held
  /// back by traffic, with [settleDelay] added on top.
  final Duration barrierTimeout;

  /// How often an overdue drone is asked where it is, while it stays overdue.
  ///
  /// Slower than the watchdog on purpose. Each probe is a tracked frame with its
  /// own retries, and the point is to resolve an ambiguity rather than to shout
  /// at a link that is already dropping frames.
  final Duration stragglerProbeInterval;

  /// Ground speed below which a drone counts as standing still, in m/s.
  ///
  /// Only used when a position has to stand in for a missing arrival report:
  /// `ARRIVED` asserts "reached it *and* stopped", so a position alone must
  /// carry the same two claims or it is not the same evidence.
  final double stationarySpeedMeters;

  /// How far off the run's hover altitude a drone may be and still be treated as
  /// standing on its vertex, in metres.
  ///
  /// Wide enough to cover the altitude hold of a small quad in wind and the
  /// offset a mid-flight joiner is given, narrow enough to separate "in the
  /// formation" from "on the ground" -- which is the distinction that matters,
  /// and the one that was missing on 2026-08-11.
  final double altitudeToleranceMeters;

  /// A position this old is not evidence of anything. Airborne telemetry is
  /// 1 Hz by default, so this is several missed frames, not a hair trigger.
  ///
  /// Null switches the silence watchdog off, which is required rather than
  /// optional once the operator turns the drone's TELEM rate down: at 0.1 Hz a
  /// four-second limit lands a perfectly healthy formation between frames, and
  /// at 0 Hz there is nothing to be silent. Liveness then rests on
  /// [legTimeout] instead, which measures the thing that actually has to
  /// happen -- a step completing -- rather than the reporting that used to
  /// accompany it.
  final Duration? telemetryTimeout;

  /// The same, for a drone that has not taken off yet.
  ///
  /// Separate, and far longer, for two reasons. The cadence is slower --
  /// PROTOCOL.md §6 has the drone report every 5 s while IDLE or LANDED against
  /// 1 s airborne -- so [telemetryTimeout] would declare a healthy drone stale
  /// before its next frame is even due.
  ///
  /// More importantly, arming and climbing is the one stretch where a drone
  /// legitimately cannot report at all: the mission thread is inside blocking
  /// flight-controller calls, and the drone stops sending `TELEM` rather than
  /// repeat a position it knows is stale. A takeoff may take the better part of
  /// its 30 s timeout. Nothing is gained by being impatient here -- a drone that
  /// has never been airborne cannot be landed, so all this timeout can do is
  /// drop it from the formation, and dropping one that is halfway up its climb
  /// is the failure, not the protection.
  final Duration? groundTelemetryTimeout;

  /// How long a drone may be under way to one vertex before we give up on it.
  ///
  /// The liveness guarantee that does not depend on telemetry existing: a step
  /// either completes and is reported with `ARRIVED`, or this expires and the
  /// drone comes down. Coarser than watching a 1 Hz position stream -- it
  /// cannot see a drone drifting off mid-leg, only that the leg never finished
  /// -- so it is a floor under the formation rather than a replacement for
  /// [telemetryTimeout], and both run when telemetry is on.
  ///
  /// Generous by default: it has to cover the flight, the settle at the far end,
  /// and the report making it back through the drone's own retry backoff.
  final Duration legTimeout;

  final Duration watchdogPeriod;

  final Map<int, DemoProgress> _progress = {};
  final Map<int, DroneState> _lastState = {};
  final Map<int, DateTime> _lastFix = {};
  final DroneClock _clock = DroneClock();

  final Map<int, DateTime> _heldSince = {};

  /// The `q` of each drone's outstanding `MOVE`, withdrawn the moment the next
  /// one is committed. A step the formation has already walked past must never
  /// go back on the wire: a retry reuses the original `q`, so once it falls
  /// outside the drone's retransmission window it is accepted as a fresh order
  /// and flown — from wherever the drone has since got to, back to a vertex it
  /// left several steps ago.
  final Map<int, int> _pendingMove = {};

  /// When each drone was last sent to a vertex, for [legTimeout].
  final Map<int, DateTime> _steppingSince = {};

  /// Drones seen airborne at least once. A drone that never got off the ground
  /// cannot be landed, and must not drag the others down when we try.
  final Set<int> _everAirborne = {};

  /// When each overdue drone was last asked where it is, for
  /// [stragglerProbeInterval].
  final Map<int, DateTime> _lastProbe = {};

  Timer? _watchdog;
  Timer? _settleTimer;
  bool _escalating = false;

  /// False while the drones are being gathered, true once the operator has
  /// released them onto the figure.
  ///
  /// Getting a swarm airborne over a shared radio is not reliable enough to be
  /// part of the choreography: on 2026-08-10 a `START_DEMO` ACK took anywhere
  /// from 0.5 s to never, so a run that begins stepping as soon as the *first*
  /// drone is up is a run that flies alone. Mustering separates "up and holding
  /// over its own anchor", which each drone reaches when it can, from "walking
  /// the figure", which the whole formation does together and which the operator
  /// starts by hand once the roster looks right.
  bool _flying = false;

  /// Whether drones are being gathered rather than flying the figure.
  bool get isMustering => isRunning && !_flying;

  /// Whether the figure has been released.
  bool get isFlying => isRunning && _flying;

  /// The drones that are up and holding over their anchors, ready to be released.
  Iterable<int> get mustered => _progress.entries
      .where((e) => e.value.isWaiting && e.value.figure.isNotEmpty)
      .map((e) => e.key);

  /// The drones still expected to get airborne.
  Iterable<int> get pending => _progress.entries
      .where((e) => e.value.isActive && !e.value.isWaiting)
      .map((e) => e.key);

  DateTime? _lastKeepalive;

  /// Hover altitude of the run in progress, so a drone added to the muster later
  /// is sent to the same height as the ones already up there.
  double _altitude = 3.0;

  /// How often a mustering drone is reminded that the ground station is still
  /// here.
  ///
  /// The drone lands itself after 30 s without contact, which is right when the
  /// operator has gone away and wrong while it is deliberately waiting for the
  /// rest of the formation. Comfortably inside that, and inside it several times
  /// over so a couple of lost frames change nothing.
  static const Duration keepaliveInterval = Duration(seconds: 8);

  /// Vertical separation used to get a drone past the formation, metres.
  ///
  /// Either for a stray on its way home, or a joiner walking the figure until it
  /// is in phase. One metre: the operator's call, and tight -- downwash from the
  /// drone above is real -- so it is deliberately the *only* number here rather
  /// than something derived, and it should be raised if the airframes turn out to
  /// dislike it.
  static const double transitOffsetMeters = 1.0;

  /// Below this, going under the formation is not an option; go over instead.
  static const double minTransitAltitudeMeters = 1.0;

  /// The height to move a drone at so it misses the formation.
  ///
  /// Under the formation where there is room, over it where there is not.
  /// Preferring below is not arbitrary: it keeps the drone out of the airspace
  /// above everyone else, a failure there falls less far, and it stays clear of
  /// the 30 m ceiling.
  ///
  ///     formation 1.5 m -> 2.5 m   (0.5 m would be too low to transit)
  ///     formation 2.0 m -> 1.0 m
  ///     formation 3.0 m -> 2.0 m
  double get transitAltitude {
    final below = _altitude - transitOffsetMeters;
    return below >= minTransitAltitudeMeters
        ? below
        : _altitude + transitOffsetMeters;
  }

  /// Drones being flown off the formation's altitude, and at what height.
  ///
  /// A joiner keeps an entry until it is merged; dropping the entry is the merge,
  /// because the next `MOVE` then carries no `alt` and the drone flies the step
  /// at the demo's altitude. Safe on an ordinary step: it is on the same vertex
  /// index at both ends, so it holds its anchor spacing from everyone throughout
  /// and may change height while translating.
  final Map<int, double> _altitudeOverride = {};

  /// The height this drone is being flown at, or null if it is with the rest.
  double? altitudeOverrideFor(int droneId) => _altitudeOverride[droneId];

  /// Whether any drone is still catching up at a different altitude.
  bool get hasJoiners => _altitudeOverride.isNotEmpty;

  /// Strays already sent home, so a retried `ARRIVED` does not re-send `RTH`.
  final Set<int> _sentHome = {};

  /// Drones we have commanded down in this run. They are not candidates for
  /// adoption until they have landed and been started fresh: a `LAND` in flight
  /// and an `ARRIVED` from before it can easily cross on a lossy link.
  final Set<int> _landCommanded = {};
  int? _lockedVertexCount;
  double? _lockedRadius;
  bool _lockedLockstep = true;

  // roundResult defaults to TRUE in latlong2, which quantises every distance
  // to whole metres -- useless when the tolerances here are 2 m wide.
  static const _distance = Distance(roundResult: false);

  /// How close to the commanded vertex counts as standing on it.
  ///
  /// Deliberately a flat number rather than something derived from the vertex
  /// spacing. The flight controller calls a waypoint reached within 1.5 m
  /// ([DroneControl.point_reached]), so anything tighter would land healthy
  /// drones; and at high vertex counts the spacing drops below that, so no
  /// tolerance can tell vertex k from k+1 by position alone. Telling them apart
  /// is the barrier's job -- we never command k+1 until k is confirmed, so the
  /// drone can only be at the vertex we asked for. This check exists to catch
  /// gross errors: a drone still parked on its anchor, or drifting away.
  static const double arrivalToleranceMeters = 2.0;

  /// How far an `ARRIVED`'s echoed target may sit from the step we are waiting
  /// on before we stop believing they are the same waypoint.
  ///
  /// Tight on purpose, and nothing like [arrivalToleranceMeters]: this is not a
  /// question about where the airframe ended up, it is a question about which
  /// order the drone was answering. The coordinate is ours, echoed back at the
  /// 7 decimal places the wire format carries -- about a centimetre -- so
  /// anything past a rounding error is a different waypoint.
  static const double _targetMatchMeters = 0.5;

  /// Distance between neighbouring vertices -- the most a drone can be out of
  /// position while still merely lagging within a leg.
  ///
  /// Uses the figure actually being flown, not the operator's current settings:
  /// once a run has started those are frozen ([_lockedRadius]), and measuring a
  /// live drone against a figure it is not flying is worse than not measuring.
  double get segmentMeters =>
      2 *
      (_lockedRadius ?? radiusMeters) *
      sin(pi / (_lockedVertexCount ?? vertexCount));

  /// Minimum separation any two drones must keep, metres.
  ///
  /// Airframe plus a margin: what "they did not touch" costs before any
  /// measurement error is added on top.
  static const double minSeparationMeters = 1.5;

  /// Why this formation cannot be released, or null if it can.
  ///
  /// The check is on **anchor spacing**, and deliberately not on the figure.
  /// Lockstep separation is geometric: identical figures translated to each
  /// drone's own anchor mean that while everyone is on the same vertex index,
  /// every pair is exactly its anchors apart -- whatever the radius, whatever the
  /// vertex count, however much the circles overlap. Figure size cancels out.
  ///
  /// What does not cancel out is how far each drone may be from the vertex it
  /// claims. With anchors `D` apart and a per-drone budget of
  /// [arrivalToleranceMeters], the worst case a pair can close to is
  /// `D - 2*tolerance`, and that is the number that has to stay clear of
  /// [minSeparationMeters].
  ///
  /// This replaces an earlier guard that compared the figure's edge length to
  /// the arrival tolerance. That guard was measuring the wrong thing: it existed
  /// because position alone could not tell vertex *k* from *k+1*, and `ARRIVED`
  /// echoing its target back settled vertex identity exactly, with no tolerance
  /// involved. Only the geometry above was ever load-bearing.
  String? get separationFault {
    final anchors = <int, LatLng>{
      for (final e in _progress.entries)
        if (e.value.figure.isNotEmpty) e.key: _anchorOf(e.value),
    };
    if (anchors.length < 2) return null;   // one drone cannot collide with itself

    final ids = anchors.keys.toList();
    var closest = double.infinity;
    int? a, b;
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final d = _distance(anchors[ids[i]]!, anchors[ids[j]]!);
        if (d < closest) {
          closest = d;
          a = ids[i];
          b = ids[j];
        }
      }
    }

    final worstCase = closest - 2 * arrivalToleranceMeters;
    if (worstCase >= minSeparationMeters) return null;
    return 'drones $a and $b took off ${closest.toStringAsFixed(1)}m apart; with '
        '${arrivalToleranceMeters.toStringAsFixed(1)}m of position tolerance each '
        'they could close to ${worstCase.toStringAsFixed(1)}m, under the '
        '${minSeparationMeters.toStringAsFixed(1)}m minimum. Move them further '
        'apart and start again';
  }

  /// A drone's anchor, recovered from the figure laid around it. Vertex 0 sits
  /// due north of the anchor at the locked radius, so the anchor is that far
  /// back south.
  LatLng _anchorOf(DemoProgress p) =>
      offsetLatLng(p.figure.first, 180, _lockedRadius ?? radiusMeters);

  Map<int, DemoProgress> get progress => Map.unmodifiable(_progress);
  bool get isRunning => _progress.values.any((p) => p.isActive);

  DemoProgress? progressFor(int droneId) => _progress[droneId];

  /// Active drones that have reached the figure -- everyone except those still
  /// getting off the ground.
  Iterable<int> get _inFigure => _progress.entries
      .where((e) => e.value.isActive && e.value.phase != DemoPhase.starting)
      .map((e) => e.key);

  /// The drones still flying the figure together.
  Iterable<int> get _formation => _progress.entries
      .where((e) => e.value.isActive)
      .map((e) => e.key);

  Future<void> start(List<int> drones, double altitude) async {
    if (drones.isEmpty) return;

    _progress.clear();
    _lastState.clear();
    _lastFix.clear();
    _heldSince.clear();
    _pendingMove.clear();
    _steppingSince.clear();
    _lastProbe.clear();
    _everAirborne.clear();
    _clock.clear();
    _conflicts.clear();
    _escalating = false;
    _flying = false;
    _lastKeepalive = null;
    _altitudeOverride.clear();
    _sentHome.clear();
    _landCommanded.clear();
    _lockedVertexCount = vertexCount;
    _lockedRadius = radiusMeters;
    _lockedLockstep = lockstep;

    for (final id in drones) {
      _progress[id] = DemoProgress(droneId: id, phase: DemoPhase.starting);
    }
    logInfo(
        'Mustering ${drones.length} drone(s) [${drones.join(", ")}], '
        '${lockstep ? "in lockstep" : "off-step with "
            "${clearanceMeters.toStringAsFixed(1)}m clearance"} - '
        'they will hold over their anchors until the formation is released',
        _tag);
    notifyListeners();

    _watchdog?.cancel();
    _watchdog = Timer.periodic(watchdogPeriod, (_) => _tick());
    _settleTimer?.cancel();
    _settleTimer = null;

    _altitude = altitude;
    for (final id in drones) {
      await _tracker.send((q) => StartDemoMessage(seq: q, altitude: altitude), dest: id);
    }
  }

  /// Add drones to a muster already under way, without disturbing the ones in it.
  ///
  /// The retry path for a drone whose `START_DEMO` was never acknowledged -- which
  /// on a shared radio is routine rather than exceptional. [start] cannot serve
  /// here: it clears `_progress`, so re-running it to pick up one straggler
  /// erases every drone already airborne, leaving them flying with no watchdog,
  /// no barrier and no way to be landed.
  ///
  /// Refused once the figure is moving. A drone admitted then would be holding
  /// over its anchor while the others are on vertex *k*, and the next step would
  /// send it to *k+1* from the wrong place -- exactly the phase slip lockstep
  /// cannot survive.
  Future<String?> addDrones(List<int> drones) async {
    if (!isRunning) return 'no muster to join - start a demo first';

    // Joining a figure that is already moving is allowed, but only a metre off
    // it. A drone admitted at the formation's own altitude would be over its
    // anchor -- the centre of its figure, not a vertex -- while everyone else is
    // on vertex k, so it could sit a full radius closer than the geometry
    // promises. Held at [transitAltitude] until it is in phase, that gap is
    // covered vertically instead, and the formation never has to stop.
    final joining = _flying;
    final altitude = joining ? transitAltitude : _altitude;

    // Already in the run, in any active phase, means there is nothing to start.
    // A second START_DEMO to a flying drone can only come back BUSY, and every
    // one of those is a chance to mistake agreement for failure.
    final already = drones.where((id) => _progress[id]?.isActive ?? false).toList();
    final fresh = drones.where((id) => !(_progress[id]?.isActive ?? false)).toList();
    if (already.isNotEmpty) {
      logInfo('Drone(s) ${already.join(", ")} are already in this run - not '
          'starting them again', _tag);
    }
    if (fresh.isEmpty) return 'those drones are already in the run';

    for (final id in fresh) {
      _progress[id] = DemoProgress(droneId: id, phase: DemoPhase.starting);
      if (joining) _altitudeOverride[id] = altitude;
      _sentHome.remove(id);
      _landCommanded.remove(id);
    }
    logInfo(
        joining
            ? 'Drone(s) ${fresh.join(", ")} joining the moving figure at '
                '${altitude.toStringAsFixed(1)}m - ${transitOffsetMeters}m off '
                'the formation until merged'
            : 'Adding drone(s) ${fresh.join(", ")} to the muster',
        _tag);
    notifyListeners();

    for (final id in fresh) {
      await _tracker.send(
          (q) => StartDemoMessage(seq: q, altitude: altitude), dest: id);
    }
    return null;
  }

  /// Bring a joiner down (or up) onto the formation's altitude.
  ///
  /// Takes effect on its next ordinary step, which needs no barrier and no pause:
  /// the drone is on the same vertex index at both ends of that leg, so it keeps
  /// its anchor spacing from everybody while it changes height.
  String? mergeIntoFormation(int droneId) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) return 'drone $droneId is not in this run';
    if (_altitudeOverride.remove(droneId) == null) {
      return 'drone $droneId is already at the formation altitude';
    }
    logInfo('Drone $droneId merging onto the formation altitude '
        '(${_altitude.toStringAsFixed(1)}m) on its next step', _tag);
    notifyListeners();
    return null;
  }

  /// An aircraft we have no phase relationship with, airborne near the figure.
  ///
  /// Sent home at [transitAltitude], which the drone reaches *in place* before it
  /// translates. That ordering is the whole safety argument: it leaves the height
  /// the formation is using before it crosses their circles, which is exactly what
  /// made a plain `RTH` unusable as an abort.
  ///
  /// Once per stray -- `ARRIVED` is retried until acknowledged, so without this
  /// every repeat would fire another `RTH`.
  void _sendStrayHome(int droneId) {
    if (!_sentHome.add(droneId)) return;
    final alt = transitAltitude;
    logError('Drone $droneId is airborne but has no place in this formation - '
        'sending it home at ${alt.toStringAsFixed(1)}m, clear of the '
        '${_altitude.toStringAsFixed(1)}m the others are using', _tag);
    unawaited(_tracker.send((q) => RthMessage(seq: q, altitude: alt),
        dest: droneId));
  }

  void stop() {
    var changed = false;
    for (final entry in _progress.entries.toList()) {
      if (!entry.value.isActive) continue;
      _progress[entry.key] =
          entry.value.copyWith(phase: DemoPhase.stopped, detail: 'stopped by operator');
      changed = true;
    }
    if (changed) {
      logWarn('Demo sequence stopped by operator', _tag);
      _finishIfIdle();
      notifyListeners();
    }
  }

  void clear() {
    if (_progress.isEmpty) return;
    _progress.clear();
    _lastState.clear();
    _lastFix.clear();
    _heldSince.clear();
    _pendingMove.clear();
    _steppingSince.clear();
    _lastProbe.clear();
    _clock.clear();
    _conflicts.clear();
    _flying = false;
    _lastKeepalive = null;
    _altitudeOverride.clear();
    _sentHome.clear();
    _landCommanded.clear();
    _watchdog?.cancel();
    _watchdog = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    notifyListeners();
  }

  void handleEvent(int droneId, MissionEvent event) {
    final p = _progress[droneId];
    if (p == null) return;

    // Events are unacknowledged and sent once, so they are never a reason to act
    // -- but they are perfectly good evidence that a command was obeyed, and the
    // whole point of collecting evidence is that any one source is enough.
    switch (event) {
      case MissionEvent.missionStart:
        _tracker.confirm(droneId, (m) => m is StartDemoMessage,
            'its MISSION_START event');
      case MissionEvent.rthStart:
        _tracker.confirm(droneId, (m) => m is RthMessage, 'its RTH_START event');
      case MissionEvent.landed:
        _tracker.confirm(droneId, (m) => m is LandMessage || m is RthMessage,
            'its LANDED event');
      case MissionEvent.waypointReached:
        _tracker.confirm(droneId, (m) => m is MoveMessage,
            'its WAYPOINT_REACHED event');
      default:
        break;
    }

    if (event == MissionEvent.missionDone || event == MissionEvent.landed) {
      if (p.phase == DemoPhase.finished) return;
      _progress[droneId] =
          p.copyWith(phase: DemoPhase.finished, detail: event.wire.toLowerCase());
      logInfo('Drone $droneId finished after ${p.steps + 1} step(s)', _tag);
      _finishIfIdle();
      _releaseBarrier();
      notifyListeners();
      return;
    }

    // Not an arrival: sent once, never acknowledged, and carries no position.
    // Telemetry repeats and says where. Kept as an operator hint.
    if (event == MissionEvent.waypointReached) {
      logTrace(_tag, 'drone $droneId reported WAYPOINT_REACHED');
    }
  }

  /// Telemetry is the only thing that moves the formation.
  void handleTelemetry(int droneId, TelemMessage telemetry) {
    final now = DateTime.now();
    _clock.observe(droneId, telemetry, now);

    _lastState[droneId] = telemetry.state;

    final p = _progress[droneId];
    if (p == null || !p.isActive) return;

    // Aged by when the drone sampled it, not when it reached us -- a queued
    // frame arrives looking fresh.
    final age = _clock.ageOf(droneId, telemetry, now);
    final limit = _silenceLimitFor(p);
    if (age != null && limit != null && age > limit) {
      _landInPlace(droneId, 'position was ${age.inMilliseconds / 1000}s old on arrival');
      return;
    }
    _lastFix[droneId] = now;
    _conflicts.observe(droneId, telemetry.position, now,
        sampleAge: age,
        reportedSpeed: telemetry.groundSpeed,
        accuracyMeters: telemetry.accuracyMeters);

    if (telemetry.state.isAirborne) {
      _everAirborne.add(droneId);
      // Off the ground, so START_DEMO was obeyed whatever became of its ACK.
      _tracker.confirm(droneId, (m) => m is StartDemoMessage,
          'telemetry showing it ${telemetry.state.wire}');
    }
    if (telemetry.state == DroneState.landing ||
        telemetry.state == DroneState.landed) {
      _tracker.confirm(droneId, (m) => m is LandMessage || m is RthMessage,
          'telemetry showing it ${telemetry.state.wire}');
    }

    // Only a fault once it should be flying: between START_DEMO and the climb
    // IDLE and ARMING are correct, and those frames can arrive late.
    if (p.phase != DemoPhase.starting && _isGrounded(telemetry.state)) {
      _landInPlace(droneId, 'reported ${telemetry.state.wire} mid-formation');
      return;
    }

    // The arrival report is overdue and this position says the drone is parked
    // on the vertex anyway: the step happened and only the report was lost.
    // Gated on being overdue, so ordinary stepping still moves on ARRIVED alone.
    if (_lockedLockstep &&
        p.phase == DemoPhase.stepping &&
        _confirmArrivalFromPosition(droneId, p, telemetry)) {
      return;
    }

    // Corroboration only: the formation steps on ARRIVED, never on this. A
    // HOVER edge is not evidence of arrival -- the drone reports HOVER the
    // instant its goto returns, which on a tight figure can be centimetres into
    // the leg, and the whole transit can fall inside one telemetry gap. What
    // telemetry is still good for is catching a drone that has wandered off
    // between vertices, which nothing else watches.
    _checkOnCourse(droneId, p, telemetry.position);
  }

  /// The drone says it is standing on the point we sent it to. This, and only
  /// this, moves the formation.
  ///
  /// Checked rather than believed, in this order:
  ///
  /// 1. **Is it the step we are waiting on?** [ArrivedMessage.target] is the
  ///    `MOVE`'s `to` echoed back, so an arrival at a vertex we have already
  ///    walked past -- a report delayed on the link, or a drone acting on a
  ///    stale order -- is caught here. Position alone could not: neighbouring
  ///    vertices sit inside [arrivalToleranceMeters] of one another on any
  ///    figure tight enough to be worth flying.
  /// 2. **Did it actually get there?** [ArrivedMessage.at] against the target.
  ///
  /// Either failing means the drone is not where the formation's geometry says
  /// it is, which is the one thing lockstep cannot tolerate.
  void handleArrived(int droneId, ArrivedMessage arrived) {
    var p = _progress[droneId];

    // A drone we have no figure for, telling us it is airborne and holding. Its
    // `START_DEMO` ACK never reached us -- on 2026-08-10 that happened on almost
    // every run, and twice the drone's own MISSION_START arrived *after* the app
    // had written it off -- but the anchor is not lost with it: the opening
    // report's `to` IS the anchor. So adopt it and let it join the muster.
    //
    // Only while mustering. Adopting into a moving figure would put a drone over
    // its anchor while the rest are on vertex k, and the next step would send it
    // to k+1 from the wrong place. Left alone it stops receiving keepalives and
    // comes down on its own idle timer, which is the safe outcome.
    if (p == null || !p.isActive || p.figure.isEmpty) {
      // Checked FIRST, before anything can be sent. On 2026-08-11 this guard sat
      // below the `_flying` branch and so was unreachable in flight: the app
      // landed drone 1, its arrival report for the leg it had been flying arrived
      // a second later, and the stray path answered it with an `RTH` to 2.5 m --
      // one metre above a formation the drone was already descending out of. It
      // only did no harm because the drone refused with BAD_STATE.
      if (_landCommanded.contains(droneId)) {
        logWarn('Drone $droneId reports it is airborne, but we have already sent '
            'it LAND - leaving it alone. Start it again once it is on the ground.',
            _tag);
        return;
      }
      if (!isRunning || _flying) {
        _sendStrayHome(droneId);
        return;
      }
      final anchor = arrived.target;
      final n = _lockedVertexCount ?? vertexCount;
      final r = _lockedRadius ?? radiusMeters;
      p = DemoProgress(
        droneId: droneId,
        phase: DemoPhase.starting,
        figure: [for (var i = 0; i < n; i++) offsetLatLng(anchor, i * 360.0 / n, r)],
      );
      _progress[droneId] = p;
      logInfo('Drone $droneId adopted into the muster from its own arrival '
          'report - anchored at ${anchor.latitude},${anchor.longitude}', _tag);
      _tracker.dismissFailure(droneId);
    }

    _everAirborne.add(droneId);

    // Flying to a point we named is proof we were heard, and this report says so
    // repeatedly -- it is retried until we acknowledge it, unlike the single ACK
    // that may already have been lost.
    _tracker.confirm(droneId, (m) => m is StartDemoMessage,
        'its own arrival report');
    _tracker.confirm(
        droneId,
        (m) => m is MoveMessage &&
            _distance(m.target, arrived.target) <= _targetMatchMeters,
        'ARRIVED at the point it named');

    // An arrival IS contact, and it is the most recent contact there is -- it is
    // acknowledged and retried, so it reached us on purpose, unlike a telemetry
    // frame that merely happened to arrive. The silence clock has to be told,
    // because the phase this report is about to advance also switches which
    // limit that clock is judged against.
    //
    // Without this the opening arrival is fatal. A drone cannot report while the
    // mission thread sits inside arm() and take_off(), so it climbs in silence;
    // that silence is forgiven only while the phase is `starting`. This report
    // moves it to `holding`, and the next watchdog tick then measures the whole
    // pre-takeoff gap against the airborne limit and lands a drone that has just
    // reported a perfectly good arrival. On 2026-08-10 that took 0.3 s.
    _lastFix[droneId] = DateTime.now();

    if (p.phase == DemoPhase.starting) {
      _reachBarrier(droneId, p, 'airborne and holding');
      return;
    }

    final expected = p.targetIn(p.figure);
    if (expected == null) return;
    final vertex = p.steps % p.figure.length;

    final drift = _distance(arrived.target, expected);
    if (drift > _targetMatchMeters) {
      // A report naming the step we have just credited is our own lost ACK
      // coming back, not a drone that flew backwards: it is retried until
      // acknowledged, so repeats are ordinary traffic rather than a fault.
      // [AppState] drops them earlier, but this must not be the only thing
      // standing between a routine retransmission and a landed drone -- that
      // dedup is keyed on a sequence number the drone resets when it restarts.
      final previous = p.steps > 0
          ? p.figure[(p.steps - 1) % p.figure.length]
          : null;
      if (previous != null &&
          _distance(arrived.target, previous) <= _targetMatchMeters) {
        logTrace(_tag, 'drone $droneId re-reported vertex '
            '${(p.steps - 1) % p.figure.length} - already credited, ignoring');
        return;
      }
      _landInPlace(droneId,
          'reported arriving somewhere it was not sent: '
          '${drift.toStringAsFixed(1)}m from vertex $vertex');
      return;
    }

    final off = _distance(arrived.at, expected);
    if (off > arrivalToleranceMeters) {
      _landInPlace(droneId,
          'stopped ${off.toStringAsFixed(1)}m off vertex $vertex');
      return;
    }
    _reachBarrier(droneId, p, 'on vertex $vertex');
  }

  /// Remind every active drone that we are still here.
  ///
  /// Untracked on purpose: a lost keepalive is not a drone fault, and the next
  /// one is a few seconds away, which is a better retry than the tracker's. The
  /// drone answers `STATUS` with an ACK and a fresh `TELEM`, so one cheap frame
  /// buys both the drone's idle timer and our own view of where it is.
  void _sendKeepalives(DateTime now) {
    final last = _lastKeepalive;
    if (last != null && now.difference(last) < keepaliveInterval) return;
    _lastKeepalive = now;
    for (final id in _formation.toList()) {
      unawaited(_tracker.ping(id, (q) => StatusMessage(seq: q)));
    }
  }

  /// A drone is overdue at its vertex. Ask it where it is instead of landing it.
  ///
  /// Silence on the `ARRIVED` path proves nothing on its own -- that report is
  /// the drone's to retransmit, and at the loss rates measured on 2026-08-10 two
  /// consecutive attempts vanishing is an ordinary event. `STATUS` is the
  /// opposite kind of question: it goes through [CommandTracker], so it is
  /// acknowledged and retried, and the drone answers it with an ACK *and* a fresh
  /// `TELEM` -- one frame that says both "I am still here" and "here is where".
  ///
  /// Three things can happen, and all three are informative where waiting was
  /// not. The `TELEM` shows it standing on the vertex, so the arrival happened
  /// and only the report was lost ([_confirmArrivalFromPosition]). It shows the
  /// drone still under way, so it is genuinely slow and [legTimeout] owns it.
  /// Or nothing comes back at all after every retry, which is real evidence of a
  /// drone that cannot be reached -- see [_onFailed].
  void _probeStraggler(int droneId, DemoProgress p, DateTime now) {
    // One question at a time. A probe lives for `ackTimeout * maxAttempts` -- on
    // 2026-08-11 that was 32 s against a 4 s probe interval, so eight retrying
    // STATUS chains piled onto one drone and the log shows four of them
    // overlapping. Asking more often cannot help a link that is already dropping
    // frames; it is the thing that makes it drop more.
    if (_tracker.isAwaitingAck(droneId)) return;

    final last = _lastProbe[droneId];
    if (last != null && now.difference(last) < stragglerProbeInterval) return;
    _lastProbe[droneId] = now;

    final vertex = p.figure.isEmpty ? 0 : p.steps % p.figure.length;
    final waited = now.difference(_steppingSince[droneId]!);
    logWarn('Drone $droneId has not reported reaching vertex $vertex in '
        '${waited.inMilliseconds / 1000}s - asking it directly (STATUS) rather '
        'than assuming it never got there', _tag);
    unawaited(_tracker.send((q) => StatusMessage(seq: q), dest: droneId));
  }

  /// Credit an overdue arrival from a fresh position, when a position can carry
  /// that weight.
  ///
  /// Deliberately *not* part of ordinary stepping -- the formation still moves on
  /// `ARRIVED` and nothing else. A drone reports `HOVER` the instant its goto
  /// returns, which on a tight figure can be centimetres into the leg, so a
  /// position that merely looks right is not an arrival. This is a repair path,
  /// gated on the report already being overdue.
  ///
  /// To stand in for `ARRIVED` a position has to make all the same claims:
  ///
  /// 1. **On the vertex** -- within [arrivalToleranceMeters] of the target, the
  ///    same test [handleArrived] applies to `ARRIVED.at`.
  /// 2. **Stopped** -- `ARRIVED` means reached *and* standing still, and the
  ///    formation's geometry depends on the second half as much as the first.
  ///    Taken from the drone's own EKF velocity, not inferred from position
  ///    differences, which read zero exactly when two fixes land on one spot.
  /// 3. **Nearer the vertex than the one it set out from** -- the part `ARRIVED`
  ///    gets for free, by echoing the `MOVE`'s `to`.
  ///
  ///    A position cannot name a vertex: on any figure tight enough to be worth
  ///    flying, neighbouring vertices sit inside [arrivalToleranceMeters] of one
  ///    another (eight vertices at 5 m are 3.83 m apart against a 2 m tolerance),
  ///    so "within tolerance of vertex k" does not even imply "not also within
  ///    tolerance of k-1". But naming it is not what this needs. There are only
  ///    two hypotheses -- still back at the vertex the leg started from, or
  ///    arrived at the one it was sent to -- because we never commanded anywhere
  ///    else. Two hypotheses are told apart by which is closer, and that stays
  ///    decidable however tight the figure gets.
  bool _confirmArrivalFromPosition(int droneId, DemoProgress p, TelemMessage t) {
    final left = _steppingSince[droneId];
    if (left == null || DateTime.now().difference(left) <= barrierTimeout) {
      return false;
    }
    final target = p.targetIn(p.figure);
    if (target == null) return false;
    final vertex = p.steps % p.figure.length;

    final off = _distance(t.position, target);
    if (off > arrivalToleranceMeters) return false;

    final speed = t.groundSpeed;
    if (speed == null) {
      logTrace(_tag, 'drone $droneId looks parked on vertex $vertex but reported '
          'no velocity - cannot tell standing still from passing through');
      return false;
    }
    if (speed > stationarySpeedMeters) return false;

    // At the formation's height, not merely above its vertex. On 2026-08-11 this
    // check was missing and the repair credited a drone reporting `alt: -0.04`
    // with `st: HOVER` -- sitting on the ground under a pilot who had taken
    // LOITER. Horizontal position said vertex 0; altitude said the drone was not
    // in the formation at all, and altitude was right.
    if ((t.altitude - _altitude).abs() > altitudeToleranceMeters) {
      logWarn('Drone $droneId is over vertex $vertex but at '
          '${t.altitude.toStringAsFixed(2)}m, not the formation\'s '
          '${_altitude.toStringAsFixed(1)}m - not crediting an arrival for a '
          'drone that is not at the formation\'s height', _tag);
      return false;
    }

    final from = _legOrigin(p);
    final back = _distance(t.position, from);
    if (back <= off) {
      logTrace(_tag, 'drone $droneId is ${off.toStringAsFixed(1)}m from vertex '
          '$vertex but ${back.toStringAsFixed(1)}m from where the leg started - '
          'it has not crossed over yet, so not crediting the arrival');
      return false;
    }

    logWarn('Drone $droneId is standing ${off.toStringAsFixed(1)}m from vertex '
        '$vertex at ${speed.toStringAsFixed(1)}m/s, and ${back.toStringAsFixed(1)}m '
        'from where it set out - it did arrive and its ARRIVED was lost. '
        'Crediting the step; not landing it', _tag);
    _reachBarrier(droneId, p, 'on vertex $vertex (confirmed by STATUS - its '
        'ARRIVED never reached us)');
    return true;
  }

  /// Where the leg in progress started: the previous vertex, or the anchor for
  /// the first step off the muster.
  LatLng _legOrigin(DemoProgress p) => p.steps > 0
      ? p.figure[(p.steps - 1) % p.figure.length]
      : _anchorOf(p);

  /// A drone has reached the vertex it was sent to and is now standing still.
  void _reachBarrier(int droneId, DemoProgress p, String why) {
    _steppingSince.remove(droneId);
    _lastProbe.remove(droneId);
    _progress[droneId] = p.copyWith(phase: DemoPhase.holding, detail: why);
    _heldSince[droneId] = DateTime.now();
    _conflicts.setTarget(droneId, null);   // parked, so it is not going anywhere
    logInfo('Drone $droneId holding ($why)', _tag);
    notifyListeners();
    _releaseBarrier();
  }

  void _releaseBarrier() {
    // Nobody leaves the anchor until the operator says the roster is complete.
    if (!_flying) return;
    if (_lockedLockstep) {
      _releaseLockstep();
    } else {
      _releaseIndependently();
    }
  }

  /// Release the mustered drones onto the figure.
  ///
  /// Returns why it refused, or null if the formation is away.
  String? beginFormation() {
    if (!isRunning) return 'no demo is running';
    if (_flying) return null;
    final ready = mustered.toList();
    if (ready.isEmpty) return 'no drone is airborne and holding yet';

    final fault = separationFault;
    if (fault != null) {
      logError('Formation not released: $fault', _tag);
      return fault;
    }

    // Whoever has not made it up is not coming with us. Dropping them here, at
    // the operator's explicit go-ahead, is what stops the barrier timeout from
    // treating a drone that is still climbing as a straggler the moment the
    // figure starts moving.
    for (final id in pending.toList()) {
      final p = _progress[id]!;
      _progress[id] = p.copyWith(
          phase: DemoPhase.stopped, detail: 'not airborne when the figure began');
      logWarn('Drone $id left behind - it was not holding when the formation '
          'was released', _tag);
    }

    _flying = true;
    logInfo('Formation released with ${ready.length} drone(s): '
        '${ready.join(", ")}', _tag);
    notifyListeners();
    _releaseBarrier();
    return null;
  }

  /// Lockstep: step the whole formation, but only once every drone is still.
  void _releaseLockstep() {
    // A drone still climbing is not in the figure yet, so it neither holds the
    // barrier nor counts as late for one. Without this a mid-flight joiner would
    // freeze the whole formation for its 15-45 s arm-and-climb -- the very thing
    // the offset altitude exists to avoid.
    final formation = _inFigure.toList();
    if (formation.isEmpty) return;
    if (!formation.every((id) => _progress[id]!.isWaiting)) return;

    // The formation leaves together, so it leaves when the last one to arrive
    // has settled.
    final wait = formation
        .map(_settleRemaining)
        .reduce((a, b) => a > b ? a : b);
    if (wait > Duration.zero) {
      _scheduleSettle(wait);
      return;
    }

    final steps = _progress[formation.first]!.steps + 1;
    if (steps >= maxSteps) {
      logWarn('Formation hit the $maxSteps-step cap - landing', _tag);
      for (final id in formation) {
        _landInPlace(id, 'step cap reached');
      }
      return;
    }

    for (final id in formation) {
      _dispatch(id, steps);
    }
    logInfo('Formation -> vertex ${steps % vertexCount} '
        '(${formation.length} drone(s))', _tag);
    notifyListeners();
  }

  /// Off-step: each drone goes when it is ready, if the way is clear.
  ///
  /// A step that would bring two drones inside clearance is not sent. The drone
  /// keeps hovering on its vertex -- which is safe, and usually resolves itself
  /// within a leg or two as the other drone moves on.
  void _releaseIndependently() {
    var moved = false;
    var soonest = Duration.zero;
    for (final id in _formation.toList()) {
      final p = _progress[id]!;
      if (!p.isWaiting) continue;

      final wait = _settleRemaining(id);
      if (wait > Duration.zero) {
        if (soonest == Duration.zero || wait < soonest) soonest = wait;
        continue;
      }

      final steps = p.steps + 1;
      if (steps >= maxSteps) {
        _landInPlace(id, 'step cap reached');
        continue;
      }
      if (p.figure.isEmpty) {
        // No anchor yet, so there is nowhere to send it -- but the opening
        // `ARRIVED` carries the anchor too, and it is retried until we take it.
        // Leave it hovering and let adoption anchor it.
        logWarn('Drone $id has no anchor yet - holding it out of the figure until '
            'its arrival report gives us one', _tag);
        continue;
      }

      final target = p.figure[steps % p.figure.length];
      final blocker = _conflicts.blockerFor(id, target, _formation);
      if (blocker != null) {
        final reason = 'holding: vertex ${steps % p.figure.length} would close '
            'on drone $blocker';
        if (p.detail != reason) {
          _progress[id] = p.copyWith(detail: reason);
          logWarn('Drone $id $reason', _tag);
          moved = true;
        }
        continue;
      }
      _dispatch(id, steps);
      moved = true;
    }
    if (soonest > Duration.zero) _scheduleSettle(soonest);
    if (moved) notifyListeners();
  }

  /// How much longer this drone has to stand still before it may be stepped.
  Duration _settleRemaining(int droneId) {
    if (settleDelay <= Duration.zero) return Duration.zero;
    final since = _heldSince[droneId];
    if (since == null) return Duration.zero;
    final left = settleDelay - DateTime.now().difference(since);
    return left.isNegative ? Duration.zero : left;
  }

  /// Come back when the settle is over. The watchdog would get there anyway,
  /// but only to its own resolution, which is coarser than the delays worth
  /// setting here.
  void _scheduleSettle(Duration wait) {
    _settleTimer?.cancel();
    _settleTimer = Timer(wait, () {
      _settleTimer = null;
      if (isRunning) _releaseBarrier();
    });
  }

  /// Commit one drone to its next vertex.
  void _dispatch(int droneId, int steps) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) return;
    if (p.figure.isEmpty) {
      // Nowhere to send it, because we never learned its anchor. That is missing
      // data on our side, not a fault of the aircraft, and the drone's opening
      // `ARRIVED` still carries the anchor -- so wait for it rather than land a
      // drone that is hovering perfectly well.
      logWarn('Drone $droneId has no anchor yet - not stepping it until its '
          'arrival report gives us one', _tag);
      return;
    }
    final vertex = steps % p.figure.length;
    final target = p.figure[vertex];

    _heldSince.remove(droneId);
    _conflicts.setTarget(droneId, target);
    _steppingSince[droneId] = DateTime.now();
    _lastProbe.remove(droneId);
    _progress[droneId] = p.copyWith(
        phase: DemoPhase.stepping, steps: steps, detail: 'to vertex $vertex');

    // The drone was seen standing on the previous vertex, so that MOVE has
    // already done its job whether or not its ACK ever reached us.
    final superseded = _pendingMove.remove(droneId);
    if (superseded != null) _tracker.withdraw(superseded);

    unawaited(_tracker
        .send(
            (q) => MoveMessage(
                seq: q, target: target, altitude: _altitudeOverride[droneId]),
            dest: droneId)
        .then((seq) {
      // Anything that happened while this was going out wins: by the time we
      // learn the `q`, the drone may already have been stepped again or landed,
      // and in both cases this MOVE is the stale one.
      final current = _progress[droneId];
      if (current == null || !current.isActive || current.steps != steps) {
        _tracker.withdraw(seq);
        return;
      }
      _pendingMove[droneId] = seq;
    }));
  }

  /// Still somewhere it could plausibly be, given the leg it was sent on?
  void _checkOnCourse(int droneId, DemoProgress p, LatLng position) {
    final target = p.targetIn(p.figure);
    if (target == null) return;
    final limit = p.phase == DemoPhase.stepping
        ? segmentMeters + arrivalToleranceMeters
        : arrivalToleranceMeters;
    final off = _distance(position, target);
    if (off > limit) {
      _landInPlace(droneId,
          '${off.toStringAsFixed(1)}m from vertex ${p.steps % p.figure.length}, '
          'limit ${limit.toStringAsFixed(1)}m');
    }
  }

  /// Watchdog: catches the failures that produce no message at all.
  void _tick() {
    if (!isRunning) {
      _watchdog?.cancel();
      _watchdog = null;
      return;
    }
    final now = DateTime.now();
    _sendKeepalives(now);

    for (final id in _formation.toList()) {
      final p = _progress[id]!;

      // Under way to a vertex for too long. Independent of telemetry, so this
      // is what holds the floor when the operator turns TELEM down or off.
      final left = _steppingSince[id];
      if (p.phase == DemoPhase.stepping &&
          left != null &&
          now.difference(left) > legTimeout) {
        // Not landed. By now this drone has been probed repeatedly, so one of two
        // things is true: it answered and something outside our control has it --
        // on 2026-08-11 that was the pilot taking LOITER, and landing a drone the
        // pilot is flying is the worst thing the app could do -- or it answered
        // nothing, and a LAND would not arrive either.
        _dropFromFormation(id,
            'no arrival within ${legTimeout.inSeconds}s',
            'Drone $id never reported reaching vertex '
                '${p.steps % (p.figure.isEmpty ? 1 : p.figure.length)} in '
                '${legTimeout.inSeconds}s');
        continue;
      }

      final limit = _silenceLimitFor(p);
      final since = _lastFix[id];
      if (limit == null) continue;   // telemetry is advisory; legTimeout covers it
      if (since == null) continue;   // not heard from yet; ACK timeouts cover it
      final silent = now.difference(since);
      if (silent > limit) {
        _landInPlace(id, 'no position for ${silent.inMilliseconds / 1000}s');
      }
    }

    if (!_flying) {
      // Nothing below applies to a muster. Probing in particular would be
      // pointless: a drone still climbing is not overdue at anything, and it
      // cannot report from inside arm() and take_off() anyway.
      return;
    }

    if (_lockedLockstep) {
      // Overdue at a vertex, measured from this drone's OWN dispatch. The clock
      // used to start when the *first* drone reached its vertex, which charged
      // every straggler for how quickly the others flew: a drone that landed on
      // its vertex three seconds after the leader had three seconds left to get
      // an `ARRIVED` through, not six.
      for (final id in _inFigure.toList()) {
        final p = _progress[id]!;
        if (p.isWaiting) continue;
        final left = _steppingSince[id];
        if (left == null) continue;   // never dispatched; nothing is overdue
        if (now.difference(left) <= barrierTimeout) continue;
        _probeStraggler(id, p, now);
      }
      _releaseBarrier();
      return;
    }

    // Both of a conflicting pair are landed: at this fix quality we cannot say
    // which one is the mover, and guessing wrong does not degrade gracefully.
    for (final conflict in _conflicts.conflicts(_formation)) {
      final gap = conflict.separationMeters.toStringAsFixed(1);
      final limit = clearanceMeters.toStringAsFixed(1);
      _landInPlace(conflict.a,
          'predicted ${gap}m from drone ${conflict.b}, clearance ${limit}m');
      _landInPlace(conflict.b,
          'predicted ${gap}m from drone ${conflict.a}, clearance ${limit}m');
    }

    // A drone held back by traffic must not wait for ever.
    for (final entry in _heldSince.entries.toList()) {
      final p = _progress[entry.key];
      if (p == null || !p.isWaiting) {
        _heldSince.remove(entry.key);
        continue;
      }
      // The settle is time it is meant to be standing there, so it does not
      // count against the drone.
      if (now.difference(entry.value) > barrierTimeout + settleDelay) {
        // It is hovering exactly where we told it to and waiting for us to find
        // it a clear step. The deadlock is ours; it is not a fault of the
        // aircraft, so it does not earn a landing.
        _dropFromFormation(entry.key,
            'held ${barrierTimeout.inSeconds}s with no clear step',
            'Drone ${entry.key} waited ${barrierTimeout.inSeconds}s for a step '
                'that never cleared');
      }
    }

    _releaseBarrier();
  }

  void _onAcknowledged(int droneId, MissionMessage command, AckMessage ack) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) return;
    if (command is! StartDemoMessage) return;   // MOVE acks are not arrivals

    final anchor = ack.position;
    if (anchor == null) {
      // The one thing this ACK was for, missing. Not fatal: the drone's opening
      // `ARRIVED` echoes its anchor as `to` and is retried until acknowledged,
      // which is a sturdier carrier than a single unrepeated ACK.
      logWarn('Drone $droneId acknowledged START_DEMO without a position - '
          'waiting for its arrival report to anchor the figure', _tag);
      return;
    }

    final n = _lockedVertexCount ?? vertexCount;
    final r = _lockedRadius ?? radiusMeters;
    final figure = [
      for (var i = 0; i < n; i++) offsetLatLng(anchor, i * 360.0 / n, r),
    ];
    logInfo('Drone $droneId anchored at ${anchor.latitude},${anchor.longitude} - '
        '$n vertices at ${r}m, waiting for the formation', _tag);

    _progress[droneId] = p.copyWith(figure: figure);
    notifyListeners();
  }

  void _onFailed(AckFailure failure) {
    final p = _progress[failure.droneId];
    if (p == null) return;

    if (failure.message is LandMessage) {
      // BAD_STATE is the drone saying it is already coming down -- it refuses
      // LAND in LANDING, and it lands itself on its own idle timeout. That is
      // the outcome the LAND was asking for, so it is not a reason to abort
      // anyone: treating it as unreachability would land a whole healthy
      // formation because one drone got there first.
      if (failure.kind == AckFailureKind.rejected &&
          failure.reason == NackError.badState) {
        logInfo('Drone ${failure.droneId} was already landing - LAND not needed',
            _tag);
        _tracker.dismissFailure(failure.droneId);
        return;
      }
      // Unreachable and still at the formation's altitude, so nothing is
      // guaranteed for anyone: everybody comes down.
      _escalate(failure.droneId, failure.description);
      return;
    }
    if (!p.isActive) return;

    // BUSY answering a START_DEMO for a drone that is already in THIS run means
    // "already doing what you asked". It is the drone agreeing with us, and
    // landing it for that is perverse. [CommandTracker] now settles the command
    // outright on BUSY, so this is the belt to that braces.
    if (failure.kind == AckFailureKind.rejected &&
        failure.reason == NackError.busy &&
        failure.message is StartDemoMessage) {
      logWarn('Drone ${failure.droneId} answered BUSY - it is already running '
          'this demo, so nothing needs starting', _tag);
      _tracker.dismissFailure(failure.droneId);
      return;
    }

    // Everything past here is a command we could not confirm, and NONE of it
    // lands a drone.
    //
    // The two cases are exhaustive and neither is helped by a LAND. Either the
    // drone is fine and the ACK was lost -- landing destroys a good flight, which
    // is what happened three times on 2026-08-11 -- or the drone genuinely cannot
    // be reached, in which case a LAND cannot reach it either, and the honest
    // thing is to say so rather than to send a frame into the dark and mark the
    // drone as landing. Its own no-contact timer covers the second case.
    //
    // Landing stays for drones that are reachable AND misbehaving: off a vertex,
    // grounded mid-formation, converging with a neighbour. Those we can see, and
    // there a LAND both arrives and helps.
    if (failure.message is StatusMessage) {
      // The probe was the recovery attempt. It failing means the state is not
      // recoverable by any means we have.
      _dropFromFormation(failure.droneId,
          'unreachable while overdue at its vertex: ${failure.description}',
          'Drone ${failure.droneId} is overdue at its vertex and answered '
              'nothing at all (${failure.description})');
      return;
    }

    if (failure.message is! StartDemoMessage && failure.message is! MoveMessage) {
      return;
    }

    // A drone that is up, anchored and in contact has told us more about itself
    // than the missing ACK ever would. Keep it.
    //
    // Silence only. A NACK is the drone *refusing* -- positive evidence that the
    // command was not obeyed, from the drone's own mouth -- and there is nothing
    // to recover: it will not fly the leg, it knows it, and it can hear us. That
    // belongs with the reachable-and-misbehaving cases, which still land.
    if (failure.kind != AckFailureKind.rejected &&
        _everAirborne.contains(failure.droneId) &&
        p.figure.isNotEmpty &&
        _hasRecentContact(failure.droneId)) {
      logWarn('Drone ${failure.droneId}: ${failure.description}, but it is '
          'airborne, anchored and still in contact - keeping it in the formation. '
          'A missing ACK is not a missing drone.', _tag);
      _tracker.dismissFailure(failure.droneId);
      return;
    }

    if (failure.kind == AckFailureKind.rejected) {
      _landInPlace(failure.droneId, failure.description);
      return;
    }

    _dropFromFormation(failure.droneId, failure.description,
        'Drone ${failure.droneId}: ${failure.description}');
  }

  /// Have we heard anything from this drone recently enough to believe in it?
  ///
  /// Deliberately generous, and deliberately *any* frame rather than a position:
  /// this decides whether we still have a working relationship with the drone,
  /// not whether we know where it is to the metre.
  bool _hasRecentContact(int droneId) {
    final last = _lastFix[droneId];
    if (last == null) return false;
    return DateTime.now().difference(last) < legTimeout;
  }

  /// Stop commanding this drone, and stop claiming to know what it is doing.
  ///
  /// The alternative to landing, and the right answer whenever the reason we lost
  /// confidence is our own -- a command we could not confirm, a report that never
  /// came -- rather than something the drone did wrong. It keeps flying, it keeps
  /// whatever position it had, and it stops being part of the formation's
  /// geometry, so nobody waits at a barrier for it.
  ///
  /// It is not abandoned. Keepalives only go to active drones, so a drone dropped
  /// here stops receiving them and lands itself on the mission's own 30 s
  /// no-contact timer -- which is drone-side, needs no radio, and was observed
  /// working on 2026-08-11 (`raspi4.log` 17:13:47, "Brak łączności od 30s -
  /// ląduję"). That gives the pilot half a minute with an aircraft that is still
  /// exactly where it was, and it is the outcome an unreachable drone gets
  /// anyway: a `LAND` we cannot deliver is a `LAND` that does not happen.
  void _dropFromFormation(int droneId, String detail, String announcement) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) return;

    _progress[droneId] = p.copyWith(phase: DemoPhase.stopped, detail: detail);
    _heldSince.remove(droneId);
    _steppingSince.remove(droneId);
    _lastProbe.remove(droneId);
    _conflicts.setTarget(droneId, null);
    final abandoned = _pendingMove.remove(droneId);
    if (abandoned != null) _tracker.withdraw(abandoned);
    _tracker.dismissFailure(droneId);
    logError('$announcement - dropped from the formation, NOT landed. It is '
        'still flying: take it manually, or let it land itself when the '
        'keepalives stop.', _tag);
    notifyListeners();
    _releaseBarrier();
  }

  /// Drop this drone out of the shared altitude, where it stands.
  ///
  /// Reserved for a drone that is doing something wrong and can still hear us --
  /// off its vertex, on the ground mid-formation, converging with a neighbour.
  /// A command we could not confirm is *not* one of those cases: see
  /// [_dropFromFormation], and [CommandTracker.confirm] for why an unconfirmed
  /// command usually means a lost ACK rather than a lost drone.
  ///
  /// Straight down, never `RTH`: a return home would fly it horizontally across
  /// the other circles at exactly the altitude they are using.
  void _landInPlace(int droneId, String reason) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) return;

    if (!_everAirborne.contains(droneId)) {
      // Never left the ground -- usually a drone that is switched off, which a
      // broadcast START_DEMO still addresses. A LAND nobody answers would
      // escalate into aborting the drones that ARE flying.
      _dropFromFormation(droneId, 'never airborne: $reason',
          'Drone $droneId never took off ($reason)');
      return;
    }

    _progress[droneId] = p.copyWith(phase: DemoPhase.landing, detail: reason);
    _heldSince.remove(droneId);
    _steppingSince.remove(droneId);
    _lastProbe.remove(droneId);
    _conflicts.setTarget(droneId, null);
    // A MOVE still being chased would fly it off the spot it is coming down on.
    final abandoned = _pendingMove.remove(droneId);
    if (abandoned != null) _tracker.withdraw(abandoned);
    logError('Drone $droneId out of formation: $reason - landing in place', _tag);
    notifyListeners();

    _landCommanded.add(droneId);
    unawaited(_tracker.send((q) => LandMessage(seq: q), dest: droneId));

    // Whoever is left must not wait at a barrier for a drone that has gone.
    _releaseBarrier();
  }

  void _escalate(int droneId, String reason) {
    if (_escalating) return;
    _escalating = true;
    logError('Drone $droneId could not be landed ($reason) - landing the '
        'whole formation', _tag);
    for (final id in _formation.toList()) {
      _landInPlace(id, 'formation abort: drone $droneId is unreachable');
    }
    notifyListeners();
  }

  void _finishIfIdle() {
    if (isRunning) return;
    _watchdog?.cancel();
    _watchdog = null;
    _settleTimer?.cancel();
    _settleTimer = null;
  }

  /// How long this drone may go quiet before we stop believing its position,
  /// or null when telemetry is advisory and silence proves nothing.
  Duration? _silenceLimitFor(DemoProgress p) => !_telemetryIsLoadBearing
      ? null
      : (p.phase == DemoPhase.starting ? groundTelemetryTimeout : telemetryTimeout);

  /// Whether a missing or stale position is a reason to bring a drone down.
  ///
  /// Off-step, yes: separation there *is* the measurement. [ConflictMonitor]
  /// predicts from these positions, so once they stop arriving there is nothing
  /// keeping the drones apart and the honest response is to land.
  ///
  /// In lockstep, no. Separation is geometric -- identical figures on the same
  /// vertex index stay their anchors apart -- and the index comes from `ARRIVED`,
  /// which is acknowledged and retried. Telemetry contributes nothing the
  /// guarantee rests on; it draws the map. Landing a drone because the map went
  /// quiet destroys a flight to protect nothing, and it is guaranteed to happen
  /// the moment the rate is turned down: at 0.2 Hz there are five seconds
  /// between healthy frames against a four second limit, and at 0 Hz there is
  /// nothing to be silent.
  ///
  /// What still covers a lockstep drone that has genuinely died: [legTimeout]
  /// while it is under way, [barrierTimeout] while the others wait for it, and
  /// an unacknowledged command either way.
  bool get _telemetryIsLoadBearing => !_lockedLockstep;

  static bool _isGrounded(DroneState state) =>
      state == DroneState.idle ||
      state == DroneState.landed ||
      state == DroneState.landing ||
      state == DroneState.rth ||
      state == DroneState.error ||
      state == DroneState.killed;

  @override
  void dispose() {
    _watchdog?.cancel();
    _watchdog = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    _tracker.onAcknowledged = null;
    _tracker.onFailed = null;
    super.dispose();
  }
}
