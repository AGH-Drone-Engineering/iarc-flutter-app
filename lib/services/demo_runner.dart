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
/// barrier: nobody is sent to vertex k+1 until every drone has reported standing
/// on vertex k. Let one drone slip a vertex and the guarantee is gone.
///
/// The barrier has no timeout. It waits for the report and nothing else, so a
/// lost one leaves the formation hovering where it is -- which is the safe way to
/// be wrong, and it corrects itself if the report arrives late. When it does not,
/// [forceNextStep] hands the judgement to the operator, who can see the
/// aircraft.
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
///
/// What this class will NOT do is land a drone for being quiet. Nothing here is
/// on a clock: no keepalives, no silence limit, no leg timeout, no barrier
/// timeout. A drone that stops reporting is dropped from the formation and left
/// flying for its pilot. A drone the pilot lands is dropped too, and rejoins on
/// its next `START_DEMO` like any other. `STATUS` is sent only when the operator
/// asks for it.
class DemoRunner extends ChangeNotifier {
  DemoRunner({
    required CommandTracker tracker,
    this.maxSteps = 200,
    this.vertexCount = 8,
    this.radiusMeters = 5.0,
    this.lockstep = true,
    this.lookahead = 1,
    double clearanceMeters = 4.0,
    this.settleDelay = Duration.zero,
  })  : _tracker = tracker,
        _conflicts = ConflictMonitor(clearanceMeters: clearanceMeters) {
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

  /// How many vertices may be in flight ahead of the last confirmed arrival.
  ///
  /// This is the smoothness dial, and it buys smoothness with the barrier.
  ///
  /// **0 -- strict barrier.** Nobody is sent vertex k+1 until every drone has
  /// reported standing on k. The drone therefore has an empty command queue as
  /// it arrives, so it decelerates to a stop, reports, and waits a radio
  /// round-trip before it moves again. That stop is the lurch: it is not the
  /// autopilot, it is this barrier.
  ///
  /// **1 or more -- pipelined.** Vertex k+1 is sent while the drone is still
  /// flying to k, so its queue is never empty. The drone's `fly_to` sees the
  /// queued MOVE when it reaches the arrival radius, reports `ARRIVED` for k
  /// without waiting to decelerate, and rolls straight into the next leg. The
  /// figure is flown as a continuous curve rather than a series of hops.
  ///
  /// What it costs: with N vertices in flight the app is confirming positions N
  /// steps behind the aircraft, so two drones flying at different speeds can
  /// drift up to N vertices apart in phase, and lockstep's separation guarantee
  /// holds only while every drone shares a vertex index. At 1 the drift is
  /// bounded by one leg and the anchors still dominate the geometry; beyond 2 it
  /// stops meaning very much. The pilots are the backstop either way.
  int lookahead;

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

  // There are no timeouts in this class. Not shorter ones, not more forgiving
  // ones -- none.
  //
  // Every clock it used to keep answered the same question, "has it been long
  // enough to assume the worst", and each got it wrong in the field: a six second
  // barrier landed drones whose arrival report was merely slow, a four second
  // silence limit landed a formation between telemetry frames, a thirty second
  // leg timeout could not tell a stuck drone from one the pilot had taken. The
  // information was never in the elapsed time.
  //
  // So the sequence is driven only by things that actually happened. Muster, and
  // wait for each drone to report that it is up. Send one step, wait for the
  // arrival report, send the next. If a report never comes the formation stands
  // still -- which is safe, visible, and undoes itself the moment the report
  // turns up. If it never does, the operator has [forceNextStep] and the pilots
  // have their sticks.

  final Map<int, DemoProgress> _progress = {};
  final Map<int, DroneState> _lastState = {};

  /// Newest position each drone reported in `TELEM`, whatever its phase.
  ///
  /// The figure is normally anchored from the opening `ARRIVED`, whose `to` IS
  /// the anchor. That report is the single point of failure in getting a drone
  /// into the run, so this is the second source: telemetry is unacknowledged,
  /// repeats at 1 Hz, and a drone holding over its anchor is *at* its anchor.
  final Map<int, LatLng> _lastPosition = {};
  final Map<int, DateTime> _lastFix = {};
  final DroneClock _clock = DroneClock();

  final Map<int, DateTime> _heldSince = {};

  /// Drones seen airborne at least once. A drone that never got off the ground
  /// cannot be landed, and must not drag the others down when we try.
  final Set<int> _everAirborne = {};

  Timer? _settleTimer;

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

  /// Hover altitude of the run in progress, so a drone added to the muster later
  /// is sent to the same height as the ones already up there.
  double _altitude = 3.0;

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
  int _lockedLookahead = 1;

  /// Highest step index each drone has *confirmed* arriving at, -1 for none.
  ///
  /// Distinct from `DemoProgress.steps`, which is the newest step DISPATCHED.
  /// With a strict barrier the two never differ by more than one and the
  /// distinction is invisible; pipelining is exactly the act of letting them
  /// differ, so the gap between them is what [lookahead] bounds.
  final Map<int, int> _confirmed = {};

  /// Steps dispatched to this drone but not yet confirmed arrived.
  int inFlightFor(int droneId) {
    final p = _progress[droneId];
    if (p == null) return 0;
    return p.steps - (_confirmed[droneId] ?? -1);
  }

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

  /// How tight the anchor spacing is, as text for the operator, or null if there
  /// is nothing to say.
  ///
  /// **Advisory only.** This used to refuse to release the formation, and that
  /// was wrong for the way the drones are actually flown: they are put up close
  /// together on purpose, and the operator can see the aircraft. It now informs
  /// and never blocks -- [beginFormation] does not consult it.
  ///
  /// The measurement is on **anchor spacing**, and deliberately not on the figure.
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
  String? get separationNotice {
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
    _lastPosition.clear();
    _lastFix.clear();
    _heldSince.clear();
    _everAirborne.clear();
    _clock.clear();
    _conflicts.clear();
    _flying = false;
    _altitudeOverride.clear();
    _sentHome.clear();
    _landCommanded.clear();
    _offCourse.clear();
    _strays.clear();
    _converging.clear();
    _confirmed.clear();
    _lockedVertexCount = vertexCount;
    _lockedRadius = radiusMeters;
    _lockedLockstep = lockstep;
    _lockedLookahead = lookahead < 0 ? 0 : lookahead;

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
      _strays.remove(id);
      _confirmed.remove(id);
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

  /// Credit this drone with reaching the vertex it was sent to, on the
  /// operator's word rather than on an `ARRIVED`.
  ///
  /// The per-drone counterpart to [forceNextStep], and the one to reach for
  /// first. An arrival report goes missing often enough to matter -- it is the
  /// one message the whole barrier hangs on -- and when it does, the choice used
  /// to be between leaving the formation frozen and stepping *everybody*, which
  /// puts the drones that had not arrived a vertex out of phase. This releases
  /// only the drone the operator can see standing on its vertex, so the barrier
  /// clears with the lockstep guarantee intact.
  ///
  /// It asserts nothing about position: the operator is looking at the aircraft,
  /// which is a better instrument than a report that never came.
  String? markArrived(int droneId) {
    var p = _progress[droneId];
    if (p == null || !p.isActive) return 'drone $droneId is not in this run';
    if (p.isWaiting) return 'drone $droneId has already reported arriving';

    if (p.figure.isEmpty) {
      // No anchor yet, because the opening `ARRIVED` never arrived. That report
      // is normally the only thing that carries the anchor, and losing it used
      // to be unrecoverable: the drone was up and holding, the operator could
      // see it, and there was no way to say so.
      //
      // Telemetry is the way out. It is unacknowledged, repeats at 1 Hz, and a
      // drone that is up and holding is sitting ON the anchor its figure should
      // be laid around -- so its last reported position is the same coordinate
      // the missing report would have carried. Anchoring from it is exactly what
      // the operator is asserting by pressing the button.
      final here = _lastPosition[droneId];
      if (here == null) {
        // Nothing has ever been heard from this drone -- no ARRIVED, no TELEM.
        // There is no position to anchor on and none to invent.
        return 'drone $droneId has not reported at all - no position to '
            'anchor its figure on';
      }
      final n = _lockedVertexCount ?? vertexCount;
      final r = _lockedRadius ?? radiusMeters;
      p = p.copyWith(
        figure: [for (var i = 0; i < n; i++) offsetLatLng(here, i * 360.0 / n, r)],
      );
      _progress[droneId] = p;
      logWarn('Drone $droneId anchored at ${here.latitude},${here.longitude} '
          'from TELEM on the operator\'s word - its arrival report never came',
          _tag);
      _tracker.dismissFailure(droneId);
    }

    _everAirborne.add(droneId);
    _lastFix[droneId] = DateTime.now();
    _offCourse.remove(droneId);

    final where = p.phase == DemoPhase.starting
        ? 'airborne and holding (operator)'
        : 'on vertex ${p.steps % p.figure.length} (operator)';
    logWarn('Operator marked drone $droneId as arrived without a report - '
        '$where', _tag);
    _reachBarrier(droneId, p, where);
    return null;
  }

  /// Land this one drone, at the operator's request.
  ///
  /// Routed through the runner rather than sent straight from [AppState] so the
  /// formation is told: a drone coming down must stop holding the barrier, or
  /// everybody else waits at their vertex for an aircraft that is on the ground.
  String? landDrone(int droneId) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) {
      // Not ours to account for, so just send it. A drone outside the run still
      // has to be landable from the same button.
      logWarn('Operator LAND for drone $droneId, which is not in this run - '
          'sending it anyway', _tag);
      _landCommanded.add(droneId);
      unawaited(_tracker.send((q) => LandMessage(seq: q), dest: droneId));
      return null;
    }
    _landInPlace(droneId, 'operator sent LAND');
    return null;
  }

  /// Send this one drone home, at the operator's request.
  ///
  /// At [transitAltitude], never the formation's: `RTH` translates horizontally,
  /// so a return at the shared height would fly it across everybody else's
  /// circle. The drone reaches the transit height in place before it moves,
  /// which is what makes that safe -- the same argument as [_sendStrayHome].
  ///
  /// The drone is dropped from the formation, not landed: it is leaving under
  /// its own command and the barrier must not wait for it.
  String? returnDroneHome(int droneId) {
    final alt = transitAltitude;
    final p = _progress[droneId];
    if (p != null && p.isActive) {
      _dropFromFormation(droneId, 'operator sent RTH',
          'Drone $droneId sent home by the operator at '
          '${alt.toStringAsFixed(1)}m');
    } else {
      logWarn('Operator RTH for drone $droneId at ${alt.toStringAsFixed(1)}m',
          _tag);
    }
    _sentHome.add(droneId);   // so a late ARRIVED does not fire a second RTH
    _offCourse.remove(droneId);
    unawaited(
        _tracker.send((q) => RthMessage(seq: q, altitude: alt), dest: droneId));
    return null;
  }

  /// Aircraft the app has seen airborne with no place in the formation, so each
  /// is mentioned once rather than on every retried report.
  ///
  /// They used to be flown home automatically. Nothing does that now: an
  /// aircraft the app cannot account for is the one it has least business
  /// commanding, and the pilots are watching.
  final Set<int> _strays = {};

  /// Drones reported airborne with no place in this formation.
  Iterable<int> get strays => _strays;

  /// Drones currently predicted to breach clearance with somebody, off-step.
  /// Advisory: nothing acts on it.
  final Set<int> _converging = {};

  bool isConverging(int droneId) => _converging.contains(droneId);

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
    _lastPosition.clear();
    _lastFix.clear();
    _heldSince.clear();
    _clock.clear();
    _conflicts.clear();
    _flying = false;
    _altitudeOverride.clear();
    _sentHome.clear();
    _landCommanded.clear();
    _offCourse.clear();
    _strays.clear();
    _converging.clear();
    _confirmed.clear();
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
      case MissionEvent.rthStart:
      case MissionEvent.landed:
      case MissionEvent.waypointReached:
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

    // Not an arrival: sent once, never acknowledged. The main mission now puts an
    // `at` on this event, but the formation still cannot step on it -- one lost
    // frame and the barrier never releases. Only a log trace here; AppState keeps
    // the position, and the formation moves on ARRIVED.
    if (event == MissionEvent.waypointReached) {
      logTrace(_tag, 'drone $droneId reported WAYPOINT_REACHED');
    }
  }

  /// Telemetry is the only thing that moves the formation.
  void handleTelemetry(int droneId, TelemMessage telemetry) {
    final now = DateTime.now();
    _clock.observe(droneId, telemetry, now);

    _lastState[droneId] = telemetry.state;
    // Kept for every drone, in flight or not: it is the fallback anchor when the
    // opening ARRIVED never turns up. See [markArrived].
    _lastPosition[droneId] = telemetry.position;

    final p = _progress[droneId];
    if (p == null || !p.isActive) return;

    // Aged by when the drone sampled it, not when it reached us -- a queued
    // frame arrives looking fresh. An old fix is not a fault: it is handed to
    // [ConflictMonitor] with its age, which widens the uncertainty around it
    // accordingly, and off-step that is what decides whether a step is safe.
    final age = _clock.ageOf(droneId, telemetry, now);
    _lastFix[droneId] = now;
    _conflicts.observe(droneId, telemetry.position, now,
        sampleAge: age,
        reportedSpeed: telemetry.groundSpeed,
        accuracyMeters: telemetry.accuracyMeters);

    if (telemetry.state.isAirborne) {
      _everAirborne.add(droneId);
      // Off the ground, so START_DEMO was obeyed whatever became of its ACK.
    }
    if (telemetry.state == DroneState.landing ||
        telemetry.state == DroneState.landed) {
    }

    // On the ground when it should be flying. Almost always the pilot: a mode
    // switch and a manual landing, which is exactly how an operator is meant to
    // take a drone out of a formation they do not like the look of.
    //
    // So it is not a fault and it earns no `LAND` -- there is nothing to land, it
    // is already down. It leaves the formation, the others carry on, and because
    // we never commanded it down it is not in [_landCommanded]: when it comes
    // back up, its own opening `ARRIVED` is adopted into the muster like any
    // other drone's and it rejoins.
    if (p.phase != DemoPhase.starting && _isGrounded(telemetry.state)) {
      _dropFromFormation(droneId, 'on the ground (${telemetry.state.wire})',
          'Drone $droneId reports ${telemetry.state.wire} mid-formation - the '
              'pilot has it. Restart it to rejoin');
      return;
    }

    // Off-step, separation IS this measurement, so a fresh position is exactly
    // when the answer can change.
    //
    // Reported, never acted on. Both of a converging pair used to be landed here
    // -- at this fix quality nothing says which one is the mover, so it had to be
    // both -- and that meant one optimistic extrapolation took two healthy
    // aircraft out of the display. The step that would have caused the
    // convergence is still refused before it is sent ([_releaseIndependently]),
    // which is the cheap, reversible half of the check; this half is now the
    // operator's warning, with the pilots as the backstop.
    if (!_lockedLockstep && _flying) {
      final conflicts = _conflicts.conflicts(_formation);
      final converging = <int>{};
      for (final conflict in conflicts) {
        converging..add(conflict.a)..add(conflict.b);
        final gap = conflict.separationMeters.toStringAsFixed(1);
        if (_converging.contains(conflict.a) &&
            _converging.contains(conflict.b)) {
          continue;   // already shouted about this pair
        }
        logError('Drones ${conflict.a} and ${conflict.b} predicted to close to '
            '${gap}m, under the ${clearanceMeters.toStringAsFixed(1)}m '
            'clearance - NOT landing them. Watch them.', _tag);
      }
      if (!setEquals(_converging, converging)) {
        _converging
          ..clear()
          ..addAll(converging);
        notifyListeners();
      }
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
    // An *uninvited* drone is only adopted while mustering. Adopting one into a
    // moving figure would put it over its anchor while the rest are on vertex k,
    // and the next step would send it to k+1 from the wrong place. Left alone it
    // hovers where it is, which is the safe outcome and the one a pilot can act
    // on.
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

      // Did we ask for this drone? [addDrones] enters a joiner as `starting`
      // with no figure, because the anchor is not known until this very report
      // arrives -- so an invited joiner is indistinguishable from a stray by
      // figure alone, and must be told apart by its `_progress` entry.
      //
      // Without this an invited joiner was strayed home by the `_flying` test
      // below, which is the whole of what "join the formation" did: on
      // 2026-08-12 a drone was started as a joiner at the transit altitude,
      // climbed, sent its opening ARRIVED, and was answered 0.7 s later with an
      // RTH that flew it straight back down. The `_flying` rule was written when
      // joining a moving figure was not a thing the app could do.
      final invited = p != null && p.isActive;

      if (!invited && (!isRunning || _flying)) {
        // Reported, not acted on. This used to answer with `RTH`, which is the
        // app flying an aircraft it has explicitly just said it knows nothing
        // about -- and it fired on any drone whose START_DEMO ACK went missing.
        // A drone the app has no place for is the pilot's, not ours.
        if (_strays.add(droneId)) {
          logWarn('Drone $droneId is airborne with no place in this formation. '
              'Leaving it alone - it is the pilot\'s. Restart it to bring it in.',
              _tag);
          notifyListeners();
        }
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
      logInfo(
          invited
              ? 'Drone $droneId anchored at ${anchor.latitude},'
                  '${anchor.longitude} from its opening arrival report - '
                  'joining the figure at '
                  '${(_altitudeOverride[droneId] ?? _altitude).toStringAsFixed(1)}m'
              : 'Drone $droneId adopted into the muster from its own arrival '
                  'report - anchored at ${anchor.latitude},${anchor.longitude}',
          _tag);
      _tracker.dismissFailure(droneId);
    }

    _everAirborne.add(droneId);

    // Flying to a point we named is proof we were heard, and this report says so
    // repeatedly -- it is retried until we acknowledge it, unlike the single ACK
    // that may already have been lost.

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

    if (p.steps < 0 || p.figure.isEmpty) return;

    // Which of the steps we have sent is this report about?
    //
    // Under a strict barrier there is only ever one candidate -- the step in
    // flight -- and this collapses to the old equality check. Pipelined there
    // are up to `lookahead + 1` of them outstanding at once, and the report for
    // vertex k routinely arrives AFTER we have already sent k+1. Matching only
    // against the newest step would then reject every arrival we get, so the
    // whole window from the last confirmation to the newest dispatch is
    // searched, newest first.
    //
    // The coordinate is ours, echoed back at the 7 decimal places the wire
    // carries, so a match is exact to about a centimetre and there is no
    // ambiguity to resolve between neighbouring vertices.
    final firstOpen = (_confirmed[droneId] ?? -1) + 1;
    int? matched;
    for (var s = p.steps; s >= firstOpen; s--) {
      if (_distance(arrived.target, p.figure[s % p.figure.length]) <=
          _targetMatchMeters) {
        matched = s;
        break;
      }
    }

    if (matched == null) {
      // Already credited, or never sent. A report naming a step behind the
      // window is our own lost ACK coming back -- ARRIVED is retried until
      // acknowledged, so repeats are ordinary traffic and not a fault.
      final credited = _confirmed[droneId] ?? -1;
      final isRepeat = credited >= 0 &&
          _distance(arrived.target, p.figure[credited % p.figure.length]) <=
              _targetMatchMeters;
      if (isRepeat) {
        logTrace(_tag,
            'drone $droneId re-reported vertex ${credited % p.figure.length} - '
            'already credited, ignoring');
        return;
      }
      logWarn('Drone $droneId reported arriving somewhere it was not sent '
          '(no match in steps $firstOpen..${p.steps}). Ignoring the report, '
          'leaving the drone alone.', _tag);
      return;
    }

    final vertex = matched % p.figure.length;
    final off = _distance(arrived.at, p.figure[vertex]);
    if (off > arrivalToleranceMeters) {
      // Credited anyway. The drone flew to the vertex we named and says it
      // stopped there; that it stopped wide is worth knowing and is not worth
      // grounding an aircraft over.
      logWarn('Drone $droneId stopped ${off.toStringAsFixed(1)}m off vertex '
          '$vertex (tolerance ${arrivalToleranceMeters.toStringAsFixed(1)}m) - '
          'crediting it anyway, NOT landing it', _tag);
    }
    _confirmArrival(droneId, p, matched,
        off > arrivalToleranceMeters
            ? 'vertex $vertex (${off.toStringAsFixed(1)}m off)'
            : 'vertex $vertex');
  }

  /// Credit [step] as reached, and let the formation move on.
  ///
  /// The drone only goes to `holding` if this was the LAST step it was sent.
  /// Pipelined it usually is not: the aircraft confirmed vertex k while already
  /// flying to k+1, so it never stops and must not be shown as though it had.
  void _confirmArrival(int droneId, DemoProgress p, int step, String where) {
    _confirmed[droneId] = step;
    _offCourse.remove(droneId);

    final stillFlying = step < p.steps;
    if (stillFlying) {
      _progress[droneId] =
          p.copyWith(detail: 'passed $where, on to ${p.steps % p.figure.length}');
      logInfo('Drone $droneId passed $where without stopping '
          '(flying to vertex ${p.steps % p.figure.length})', _tag);
    } else {
      _progress[droneId] = p.copyWith(phase: DemoPhase.holding, detail: where);
      _heldSince[droneId] = DateTime.now();
      _conflicts.setTarget(droneId, null);   // parked, not going anywhere
      logInfo('Drone $droneId holding ($where)', _tag);
    }
    notifyListeners();
    _releaseBarrier();
  }

  /// A drone has reached the vertex it was sent to and is now standing still.
  ///
  /// Only for arrivals with no step behind them -- the opening "airborne and
  /// holding", and the operator's [markArrived]. Ordinary vertex arrivals go
  /// through [_confirmArrival], which knows about pipelining.
  void _reachBarrier(int droneId, DemoProgress p, String why) {
    if (p.steps >= 0) _confirmed[droneId] = p.steps;
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

    // Anchor spacing is reported, not enforced. It used to refuse the release,
    // and on 2026-08-11 that stopped a run where both drones were already in the
    // air: they are deliberately put up close together, and 4 m of "worst case"
    // arithmetic is not a better judge of that than the operator watching them.
    final notice = separationNotice;
    if (notice != null) logWarn('Releasing anyway: $notice', _tag);

    // Whoever has not made it up is not coming with us. Dropped here, at the
    // operator's explicit go-ahead, so the barrier is not left waiting for a
    // report from a drone that never took off.
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

  /// Step the formation now, whether or not every drone has reported arriving.
  ///
  /// The escape hatch that replaces the barrier timeout. A barrier waits for a
  /// report; if that report is lost the formation stands still for ever, which is
  /// safe but not useful. The old answer was a six second clock that landed the
  /// drones it had given up on -- and it was usually wrong, because a slow report
  /// and a stopped drone look identical from here and only one of them is a
  /// problem.
  ///
  /// So the judgement moves to the operator, who can see the aircraft. This sends
  /// the next vertex to every drone in the figure regardless of what they have
  /// reported, and nothing is landed.
  ///
  /// The risk is real and worth stating: a drone that had NOT arrived is now a
  /// vertex out of phase with the rest, and lockstep's separation guarantee holds
  /// only while every drone shares a vertex index. Use it when you can see the
  /// formation is standing still and the drones are where they should be.
  String? forceNextStep() {
    if (!isRunning) return 'no demo is running';
    if (!_flying) return 'the formation has not been released yet';
    final formation = _inFigure.toList();
    if (formation.isEmpty) return 'no drone is flying the figure';

    final late = formation.where((id) => !_progress[id]!.isWaiting).toList();
    if (late.isEmpty) {
      logInfo('Operator forced the next step; every drone had reported arriving '
          'anyway', _tag);
    } else {
      logWarn('Operator forced the next step with ${late.length} drone(s) not '
          'reporting arrival: ${late.join(", ")}. They may now be a vertex out '
          'of phase with the rest', _tag);
    }
    _stepFormation(formation, forced: true);
    return null;
  }

  /// Lockstep: keep every drone supplied with vertices, in step with the rest.
  ///
  /// The rule is one line: **the formation may be dispatched up to
  /// `slowest confirmed arrival + 1 + lookahead`.** Everything else falls out of
  /// it.
  ///
  /// At `lookahead == 0` that is `minConfirmed + 1`, which is precisely the old
  /// barrier -- nothing is sent until the slowest drone has reported the current
  /// vertex. Above zero it lets each drone hold that many un-confirmed vertices
  /// in its queue, which is what stops it decelerating on every corner, while
  /// still pinning the whole formation to the SLOWEST drone's confirmed
  /// progress. A drone that stops reporting still halts the figure within
  /// `lookahead` steps rather than running away with it.
  void _releaseLockstep() {
    // A drone still climbing is not in the figure yet, so it neither holds the
    // barrier nor counts as late for one. Without this a mid-flight joiner would
    // freeze the whole formation for its 15-45 s arm-and-climb -- the very thing
    // the offset altitude exists to avoid.
    final formation = _inFigure.toList();
    if (formation.isEmpty) return;

    final minConfirmed = formation
        .map((id) => _confirmed[id] ?? -1)
        .reduce((a, b) => a < b ? a : b);
    final ceiling = minConfirmed + 1 + _lockedLookahead;

    // Only drones that are actually standing still need to settle. Pipelined,
    // the drone is still moving when it reports, so there is nothing to settle
    // and waiting would reintroduce the stop this exists to remove.
    final holding = formation.where((id) => _progress[id]!.isWaiting).toList();
    if (holding.isNotEmpty) {
      final wait =
          holding.map(_settleRemaining).reduce((a, b) => a > b ? a : b);
      if (wait > Duration.zero) {
        _scheduleSettle(wait);
        return;
      }
    }

    // Sequential, never skipping: a drone is only ever sent the vertex after the
    // one it was last sent. Its queue keeps them in order, and the drone rejects
    // any that arrive out of order (`_seq_is_newer` in link.py).
    //
    // Looped, so the pipeline is filled to the ceiling in one go rather than one
    // vertex per arrival. It matters most at the very start: a single pass would
    // send only vertex 0 at release, leaving the queue empty for the first leg,
    // and the drone would stop on the first corner before the pipeline caught
    // up. Terminates because every pass advances at least one drone's `steps`
    // toward a ceiling that does not move inside this call.
    while (true) {
      final due = formation
          .where((id) => _progress[id]!.steps + 1 <= ceiling)
          .toList();
      if (due.isEmpty) return;
      _stepFormation(due);
    }
  }

  /// Send the next vertex to each of these drones.
  ///
  /// Each gets *its own* `steps + 1` rather than one shared index. Under a strict
  /// barrier that is the same number for everybody, so nothing changes; pipelined
  /// it is what stops a drone being skipped past a vertex it has not been sent
  /// yet, because the queue on the aircraft only preserves the order we send in.
  ///
  /// [forced] is the exception: it levels everyone up to the furthest-along
  /// drone's next index, which is the entire point of the button -- a drone that
  /// missed a step is caught up rather than left behind.
  void _stepFormation(List<int> formation, {bool forced = false}) {
    final furthest = formation
        .map((id) => _progress[id]!.steps)
        .reduce((a, b) => a > b ? a : b);

    if (furthest + 1 >= maxSteps) {
      // Stop stepping, do not land. The cap is a runaway guard on this app's own
      // loop, not a statement about the aircraft, and the drones are hovering
      // safely on their vertices when it trips.
      logWarn('Formation hit the $maxSteps-step cap - holding position. '
          'Stop the demo or land the drones from the Demo tab.', _tag);
      for (final id in formation) {
        final p = _progress[id]!;
        _progress[id] = p.copyWith(detail: 'step cap reached - holding');
      }
      notifyListeners();
      return;
    }

    final sent = <int>[];
    for (final id in formation) {
      final steps = forced ? furthest + 1 : _progress[id]!.steps + 1;
      _dispatch(id, steps);
      sent.add(steps % (_lockedVertexCount ?? vertexCount));
    }
    final vertices = sent.toSet().toList()..sort();
    logInfo(
        'Formation -> vertex ${vertices.join("/")} '
        '(${formation.length} drone(s))${forced ? " [forced]" : ""}'
        '${_lockedLookahead > 0 && !forced ? " [pipelined]" : ""}',
        _tag);
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
      // Off-step there is no formation to stay level with, so a drone may be
      // topped up whenever it has fewer than `lookahead` legs outstanding --
      // that is what keeps its queue non-empty and its motion continuous. With
      // lookahead 0 this is the old rule: step only a drone that is standing
      // still, having reported.
      final outstanding = p.steps - (_confirmed[id] ?? -1);
      if (outstanding > _lockedLookahead) continue;
      if (!p.isWaiting && _lockedLookahead == 0) continue;

      // Only a drone that is actually parked has anything to settle.
      if (p.isWaiting) {
        final wait = _settleRemaining(id);
        if (wait > Duration.zero) {
          if (soonest == Duration.zero || wait < soonest) soonest = wait;
          continue;
        }
      }

      final steps = p.steps + 1;
      if (steps >= maxSteps) {
        // Holds, never lands -- see [_stepFormation].
        if (p.detail != 'step cap reached - holding') {
          _progress[id] = p.copyWith(detail: 'step cap reached - holding');
          logWarn('Drone $id hit the $maxSteps-step cap - holding position', _tag);
          moved = true;
        }
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
    _offCourse.remove(droneId);   // new leg, so the old excursion is spent
    _conflicts.setTarget(droneId, target);
    _progress[droneId] = p.copyWith(
        phase: DemoPhase.stepping, steps: steps, detail: 'to vertex $vertex');

    // One transmission, and nothing keeps chasing it. A superseded MOVE used to
    // need withdrawing, because a retry reuses the original `q` and could land
    // outside the drone's dedupe window as a fresh order -- flying it back to a
    // vertex the formation left several steps ago. With no retries there is no
    // stale copy to come back.
    unawaited(_tracker.send(
        (q) => MoveMessage(
            seq: q, target: target, altitude: _altitudeOverride[droneId]),
        dest: droneId));
  }

  /// Still somewhere it could plausibly be, given the leg it was sent on?
  ///
  /// Reports and does not act. This used to land the drone, and the judgement
  /// was wrong often enough to be dangerous: a drone joining a figure that is
  /// already moving is legitimately most of a leg away from the vertex it is
  /// walking to, so on 2026-08-11 a healthy joiner measured itself 7 m out and
  /// put itself on the ground mid-catch-up. Being out of position is not by
  /// itself a reason to come down -- the joiner is a metre off the formation's
  /// altitude the whole time it is out there ([_altitudeOverride]), so it is
  /// separated from everybody regardless of where it is horizontally. The
  /// operator can see the aircraft and has [landDrone] if it needs to come down.
  void _checkOnCourse(int droneId, DemoProgress p, LatLng position) {
    final target = p.targetIn(p.figure);
    if (target == null) return;
    final limit = p.phase == DemoPhase.stepping
        ? segmentMeters + arrivalToleranceMeters
        : arrivalToleranceMeters;
    final off = _distance(position, target);

    if (off <= limit) {
      // Back where it should be: drop the flag so a later excursion is reported
      // afresh rather than swallowed as "already known".
      if (_offCourse.remove(droneId)) {
        logInfo('Drone $droneId back on course '
            '(${off.toStringAsFixed(1)}m from its vertex)', _tag);
        notifyListeners();
      }
      return;
    }

    // Telemetry is 1 Hz, so log the excursion once rather than every frame.
    if (!_offCourse.add(droneId)) return;
    logError(
        'Drone $droneId is ${off.toStringAsFixed(1)}m from vertex '
        '${p.steps % p.figure.length} (limit ${limit.toStringAsFixed(1)}m) - '
        'reporting only, NOT landing it',
        _tag);
    notifyListeners();
  }

  /// Drones currently measured off their leg, so the excursion is logged once.
  final Set<int> _offCourse = {};

  /// Whether this drone is currently further off its leg than [_checkOnCourse]
  /// expects. Advisory: nothing acts on it.
  bool isOffCourse(int droneId) => _offCourse.contains(droneId);

  /// Watchdog: catches the failures that produce no message at all.
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
      // A LAND that did not land it. Worth shouting about, but it no longer
      // brings the rest of the formation down with it: landing three healthy
      // aircraft because a fourth refused one message is a bigger event than the
      // one it is trying to prevent, and the pilots can see all four.
      logError('Drone ${failure.droneId} did not take LAND '
          '(${failure.description}). It may still be at the formation altitude - '
          'the rest are being left up. Take it manually.', _tag);
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

    if (failure.message is! StartDemoMessage && failure.message is! MoveMessage) {
      return;
    }

    // Only two failures can reach here now, and they are both something that
    // happened rather than something that did not.
    //
    // A NACK is the drone refusing -- it will not fly the step, it knows it, and
    // it can hear us -- so it comes down. A refused write is this phone's own
    // transport failing, which says nothing about the aircraft, so the drone is
    // dropped from the formation and left flying.
    // A NACK used to land the drone here. It no longer does: the drone refusing
    // a step is a drone that is NOT flying anywhere, hovering where it already
    // was, which is the safe state. It leaves the formation so the barrier stops
    // waiting for it, and stays up for its pilot.
    _dropFromFormation(failure.droneId, failure.description,
        'Drone ${failure.droneId}: ${failure.description}');
  }

  /// Stop commanding this drone, and stop claiming to know what it is doing.
  ///
  /// The alternative to landing, and the right answer whenever the reason we lost
  /// confidence is our own -- a command we could not confirm, a report that never
  /// came -- rather than something the drone did wrong. It keeps flying, it keeps
  /// whatever position it had, and it stops being part of the formation's
  /// geometry, so nobody waits at a barrier for it.
  ///
  /// It stays in the air, and that is deliberate. The drone's own no-contact
  /// auto-land is off by default now (`demo_mission_with_app.py --idle-timeout`),
  /// because with no keepalives silence is the normal state of a formation waiting
  /// at a barrier, and a 30 s clock would have killed every muster.
  ///
  /// So a dropped drone hovers where it is until a pilot takes it. That is the
  /// trade the operator asked for: the aircraft stays predictable and under human
  /// control, rather than descending somewhere on a timer nobody was watching.
  void _dropFromFormation(int droneId, String detail, String announcement) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) return;

    _progress[droneId] = p.copyWith(phase: DemoPhase.stopped, detail: detail);
    _heldSince.remove(droneId);
    _conflicts.setTarget(droneId, null);
    _tracker.dismissFailure(droneId);
    logError('$announcement - dropped from the formation, NOT landed. If it is '
        'still flying it will stay up: take it manually.', _tag);
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
    _conflicts.setTarget(droneId, null);
    logError('Drone $droneId out of formation: $reason - landing in place', _tag);
    notifyListeners();

    _landCommanded.add(droneId);
    unawaited(_tracker.send((q) => LandMessage(seq: q), dest: droneId));

    // Whoever is left must not wait at a barrier for a drone that has gone.
    _releaseBarrier();
  }

  void _finishIfIdle() {
    if (isRunning) return;
    _settleTimer?.cancel();
    _settleTimer = null;
  }

  static bool _isGrounded(DroneState state) =>
      state == DroneState.idle ||
      state == DroneState.landed ||
      state == DroneState.landing ||
      state == DroneState.rth ||
      state == DroneState.error ||
      state == DroneState.killed;

  @override
  void dispose() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _tracker.onFailed = null;
    super.dispose();
  }
}
