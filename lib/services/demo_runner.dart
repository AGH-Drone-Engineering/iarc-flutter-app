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
    this.barrierTimeout = const Duration(seconds: 6),
    this.telemetryTimeout = const Duration(seconds: 4),
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

  /// How long the drones already at a vertex will wait for the stragglers.
  /// Whoever has not arrived by then is landed.
  final Duration barrierTimeout;

  /// A position this old is not evidence of anything. Airborne telemetry is
  /// 1 Hz, so this is several missed frames, not a hair trigger.
  final Duration telemetryTimeout;

  final Duration watchdogPeriod;

  final Map<int, DemoProgress> _progress = {};
  final Map<int, DroneState> _lastState = {};
  final Map<int, DateTime> _lastFix = {};
  final DroneClock _clock = DroneClock();

  final Map<int, DateTime> _heldSince = {};

  Timer? _watchdog;
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
    _clock.clear();
    _conflicts.clear();
    _watchdog?.cancel();
    _watchdog = null;
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

    // WAYPOINT_REACHED is not what advances the formation any more. It is sent
    // once and never acknowledged -- one lost frame on the radio and a drone
    // silently stops stepping -- and it carries no position, so it cannot show
    // that the drone is where the formation needs it to be. Telemetry answers
    // both: it repeats, and it says where. The event stays as an operator hint.
    if (event == MissionEvent.waypointReached) {
      logTrace(_tag, 'drone $droneId reported WAYPOINT_REACHED');
    }
  }

  /// Telemetry is the only thing that moves the formation.
  void handleTelemetry(int droneId, TelemMessage telemetry) {
    final now = DateTime.now();
    _clock.observe(droneId, telemetry, now);

    final previous = _lastState[droneId];
    _lastState[droneId] = telemetry.state;

    final p = _progress[droneId];
    if (p == null || !p.isActive) return;

    // Age the fix by when the drone SAMPLED it, not when it reached us: on a
    // polled radio a frame can sit in a queue, and a position that just arrived
    // may describe where the drone was several seconds ago.
    final age = _clock.ageOf(droneId, telemetry, now);
    if (age != null && age > telemetryTimeout) {
      _landInPlace(droneId, 'position was ${age.inMilliseconds / 1000}s old on arrival');
      return;
    }
    _lastFix[droneId] = now;
    _conflicts.observe(droneId, telemetry.position, now,
        sampleAge: age, reportedSpeed: telemetry.groundSpeed);

    if (_isGrounded(telemetry.state)) {
      _landInPlace(droneId, 'reported ${telemetry.state.wire} mid-formation');
      return;
    }

    if (telemetry.state != DroneState.hover) {
      _checkOnCourse(droneId, p, telemetry.position);
      return;
    }
    if (previous == DroneState.hover) {
      // A run of HOVER, not the edge into one. Still worth checking it has not
      // drifted off the vertex while the formation waits for the others.
      _checkOnCourse(droneId, p, telemetry.position);
      return;
    }

    if (p.phase == DemoPhase.starting) {
      if (p.figure.isEmpty) return;   // START_DEMO ACK still in flight
      _reachBarrier(droneId, p, 'airborne and holding');
      return;
    }

    final target = p.targetIn(p.figure);
    if (target == null) return;
    final off = _distance(telemetry.position, target);
    if (off > arrivalToleranceMeters) {
      // Stopped, but not where we sent it. A leg that ended early -- a pilot
      // takeover, or a goto that gave up -- leaves the drone out of formation.
      _landInPlace(droneId,
          'stopped ${off.toStringAsFixed(1)}m off vertex ${p.steps % p.figure.length}');
      return;
    }
    _reachBarrier(droneId, p, 'on vertex ${p.steps % p.figure.length}');
  }

  /// A drone has reached the vertex it was sent to and is now standing still.
  void _reachBarrier(int droneId, DemoProgress p, String why) {
    _progress[droneId] = p.copyWith(phase: DemoPhase.holding, detail: why);
    _heldSince[droneId] = DateTime.now();
    _conflicts.setTarget(droneId, null);   // parked, so it is not going anywhere
    if (_lockedLockstep) _barrierSince ??= DateTime.now();
    logTrace(_tag, 'drone $droneId holding ($why)');
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

    _barrierSince = null;
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
    logTrace(_tag, 'formation -> vertex ${steps % vertexCount} '
        '(${formation.length} drone(s))');
    notifyListeners();
  }

  /// Off-step: each drone goes when it is ready, if the way is clear.
  ///
  /// A step that would bring two drones inside clearance is not sent. The drone
  /// keeps hovering on its vertex -- which is safe, and usually resolves itself
  /// within a leg or two as the other drone moves on.
  void _releaseIndependently() {
    var moved = false;
    for (final id in _formation.toList()) {
      final p = _progress[id]!;
      if (!p.isWaiting) continue;

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
    if (moved) notifyListeners();
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
    _progress[droneId] = p.copyWith(
        phase: DemoPhase.stepping, steps: steps, detail: 'to vertex $vertex');
    unawaited(
        _tracker.send((q) => MoveMessage(seq: q, target: target), dest: droneId));
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
      final since = _lastFix[id];
      if (since == null) continue;   // not heard from yet; ACK timeouts cover it
      final silent = now.difference(since);
      if (silent > telemetryTimeout) {
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

    // Off-step: nothing guarantees separation, so it has to be watched. A pair
    // predicted inside clearance has both drones landed -- with fixes this
    // stale we cannot reliably say which one is the mover, and guessing wrong
    // is the one mistake that does not degrade gracefully.
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
      if (now.difference(entry.value) > barrierTimeout) {
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
      // We could not tell it to come down and it is still at the formation's
      // altitude. Nothing about the rest of the formation is guaranteed any
      // more, so everybody comes down.
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

    _progress[droneId] = p.copyWith(phase: DemoPhase.landing, detail: reason);
    _heldSince.remove(droneId);
    _conflicts.setTarget(droneId, null);
    logError('Drone $droneId out of formation: $reason - landing in place', _tag);
    notifyListeners();

    unawaited(_tracker.send((q) => LandMessage(seq: q), dest: droneId));

    // The rest keep their lockstep, so they are still safe -- but whoever is
    // left must not sit waiting at a barrier for a drone that has left it.
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
    _barrierSince = null;
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
    _watchdog?.cancel();
    _watchdog = null;
    _tracker.onAcknowledged = null;
    _tracker.onFailed = null;
    super.dispose();
  }
}
