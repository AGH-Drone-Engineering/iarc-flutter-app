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
    this.telemetryTimeout = const Duration(seconds: 4),
    this.groundTelemetryTimeout = const Duration(seconds: 12),
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

  /// How long the drones already at a vertex will wait for the stragglers.
  /// Whoever has not arrived by then is landed. [settleDelay] is added on top
  /// off-step, where the same clock is what limits a drone held by traffic.
  final Duration barrierTimeout;

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
  /// Separate because the cadence is: PROTOCOL.md §6 has the drone report every
  /// 5 s while IDLE or LANDED against 1 s airborne, so [telemetryTimeout] is
  /// shorter than the gap between two perfectly on-schedule frames from a drone
  /// sitting on the ground waiting to arm. Using it there declares a healthy
  /// drone stale a second before its next frame is even due.
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

  Timer? _watchdog;
  Timer? _settleTimer;
  DateTime? _barrierSince;
  bool _escalating = false;
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
  double get segmentMeters => 2 * radiusMeters * sin(pi / vertexCount);

  Map<int, DemoProgress> get progress => Map.unmodifiable(_progress);
  bool get isRunning => _progress.values.any((p) => p.isActive);

  DemoProgress? progressFor(int droneId) => _progress[droneId];

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
    _everAirborne.clear();
    _clock.clear();
    _conflicts.clear();
    _barrierSince = null;
    _escalating = false;
    _lockedVertexCount = vertexCount;
    _lockedRadius = radiusMeters;
    _lockedLockstep = lockstep;

    for (final id in drones) {
      _progress[id] = DemoProgress(droneId: id, phase: DemoPhase.starting);
    }
    logInfo(
        'Demo sequence started for ${drones.length} drone(s), '
        '${lockstep ? "in lockstep" : "off-step with "
            "${clearanceMeters.toStringAsFixed(1)}m clearance"}',
        _tag);
    notifyListeners();

    _watchdog?.cancel();
    _watchdog = Timer.periodic(watchdogPeriod, (_) => _tick());
    _settleTimer?.cancel();
    _settleTimer = null;

    for (final id in drones) {
      await _tracker.send((q) => StartDemoMessage(seq: q, altitude: altitude), dest: id);
    }
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
    _clock.clear();
    _conflicts.clear();
    _watchdog?.cancel();
    _watchdog = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    notifyListeners();
  }

  void handleEvent(int droneId, MissionEvent event) {
    final p = _progress[droneId];
    if (p == null) return;

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

    if (telemetry.state.isAirborne) _everAirborne.add(droneId);

    // Only a fault once it should be flying: between START_DEMO and the climb
    // IDLE and ARMING are correct, and those frames can arrive late.
    if (p.phase != DemoPhase.starting && _isGrounded(telemetry.state)) {
      _landInPlace(droneId, 'reported ${telemetry.state.wire} mid-formation');
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
    final p = _progress[droneId];
    if (p == null || !p.isActive) return;
    if (p.figure.isEmpty) return;   // START_DEMO ACK still in flight

    _everAirborne.add(droneId);

    if (p.phase == DemoPhase.starting) {
      _reachBarrier(droneId, p, 'airborne and holding');
      return;
    }

    final expected = p.targetIn(p.figure);
    if (expected == null) return;
    final vertex = p.steps % p.figure.length;

    final drift = _distance(arrived.target, expected);
    if (drift > _targetMatchMeters) {
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

  /// A drone has reached the vertex it was sent to and is now standing still.
  void _reachBarrier(int droneId, DemoProgress p, String why) {
    _steppingSince.remove(droneId);
    _progress[droneId] = p.copyWith(phase: DemoPhase.holding, detail: why);
    _heldSince[droneId] = DateTime.now();
    _conflicts.setTarget(droneId, null);   // parked, so it is not going anywhere
    if (_lockedLockstep) _barrierSince ??= DateTime.now();
    logInfo('Drone $droneId holding ($why)', _tag);
    notifyListeners();
    _releaseBarrier();
  }

  void _releaseBarrier() {
    if (_lockedLockstep) {
      _releaseLockstep();
    } else {
      _releaseIndependently();
    }
  }

  /// Lockstep: step the whole formation, but only once every drone is still.
  void _releaseLockstep() {
    final formation = _formation.toList();
    if (formation.isEmpty) {
      _barrierSince = null;
      return;
    }
    if (!formation.every((id) => _progress[id]!.isWaiting)) return;

    // Everybody is here, so nobody is a straggler any more, whatever happens
    // below.
    _barrierSince = null;

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
        _landInPlace(id, 'no anchor - START_DEMO ACK carried no position');
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
      _landInPlace(droneId, 'no anchor - START_DEMO ACK carried no position');
      return;
    }
    final vertex = steps % p.figure.length;
    final target = p.figure[vertex];

    _heldSince.remove(droneId);
    _conflicts.setTarget(droneId, target);
    _steppingSince[droneId] = DateTime.now();
    _progress[droneId] = p.copyWith(
        phase: DemoPhase.stepping, steps: steps, detail: 'to vertex $vertex');

    // The drone was seen standing on the previous vertex, so that MOVE has
    // already done its job whether or not its ACK ever reached us.
    final superseded = _pendingMove.remove(droneId);
    if (superseded != null) _tracker.withdraw(superseded);

    unawaited(_tracker
        .send((q) => MoveMessage(seq: q, target: target), dest: droneId)
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

    for (final id in _formation.toList()) {
      final p = _progress[id]!;

      // Under way to a vertex for too long. Independent of telemetry, so this
      // is what holds the floor when the operator turns TELEM down or off.
      final left = _steppingSince[id];
      if (p.phase == DemoPhase.stepping &&
          left != null &&
          now.difference(left) > legTimeout) {
        _landInPlace(id, 'no arrival reported within '
            '${legTimeout.inSeconds}s of being sent to vertex '
            '${p.steps % (p.figure.isEmpty ? 1 : p.figure.length)}');
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

    if (_lockedLockstep) {
      final waitingSince = _barrierSince;
      if (waitingSince != null && now.difference(waitingSince) > barrierTimeout) {
        final late = _formation.where((id) => !_progress[id]!.isWaiting).toList();
        _barrierSince = null;
        for (final id in late) {
          _landInPlace(id, 'did not reach the vertex within '
              '${barrierTimeout.inSeconds}s of the rest of the formation');
        }
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
        _landInPlace(entry.key,
            'held ${barrierTimeout.inSeconds}s waiting for a clear step');
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
      _landInPlace(droneId, 'START_DEMO ACK carried no position');
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
    if (failure.message is! StartDemoMessage && failure.message is! MoveMessage) {
      return;
    }
    _landInPlace(failure.droneId, failure.description);
  }

  /// Drop this drone out of the shared altitude, where it stands.
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
      _progress[droneId] =
          p.copyWith(phase: DemoPhase.stopped, detail: 'never airborne: $reason');
      _heldSince.remove(droneId);
      logWarn('Drone $droneId never took off ($reason) - dropped from the '
          'formation, not landed', _tag);
      notifyListeners();
      _releaseBarrier();
      return;
    }

    _progress[droneId] = p.copyWith(phase: DemoPhase.landing, detail: reason);
    _heldSince.remove(droneId);
    _steppingSince.remove(droneId);
    _conflicts.setTarget(droneId, null);
    // A MOVE still being chased would fly it off the spot it is coming down on.
    final abandoned = _pendingMove.remove(droneId);
    if (abandoned != null) _tracker.withdraw(abandoned);
    logError('Drone $droneId out of formation: $reason - landing in place', _tag);
    notifyListeners();

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
    _barrierSince = null;
  }

  /// How long this drone may go quiet before we stop believing its position,
  /// or null when telemetry is advisory and silence proves nothing.
  Duration? _silenceLimitFor(DemoProgress p) =>
      p.phase == DemoPhase.starting ? groundTelemetryTimeout : telemetryTimeout;

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
