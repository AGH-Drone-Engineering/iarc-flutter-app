import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/mission_message.dart';
import '../pathfinding/local_frame.dart' show offsetLatLng;
import 'command_tracker.dart';
import 'global_log.dart';

const _tag = 'demo';

enum DemoPhase { starting, stepping, returning, finished, stopped }

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
    this.steps = 0,
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

  bool get isActive => phase == DemoPhase.starting || phase == DemoPhase.stepping;
}

class DemoRunner extends ChangeNotifier {
  DemoRunner({
    required CommandTracker tracker,
    this.maxSteps = 200,
    this.vertexCount = 8,
    this.radiusMeters = 5.0,
  }) : _tracker = tracker {
    _tracker.onAcknowledged = _onAcknowledged;
    _tracker.onFailed = _onFailed;
  }

  final CommandTracker _tracker;
  final int maxSteps;

  /// The figure is a regular polygon around the anchor. The ground station owns
  /// it now: `MOVE` carries absolute coordinates, so the drone stores no routine
  /// and a changed shape needs no drone-side release -- which is why these are
  /// operator-settable rather than constants.
  int vertexCount;
  double radiusMeters;

  final Map<int, DemoProgress> _progress = {};

  Map<int, DemoProgress> get progress => Map.unmodifiable(_progress);
  bool get isRunning => _progress.values.any((p) => p.isActive);

  DemoProgress? progressFor(int droneId) => _progress[droneId];

  Future<void> start(List<int> drones, double altitude) async {
    if (drones.isEmpty) return;
    _progress.clear();
    for (final id in drones) {
      _progress[id] = DemoProgress(droneId: id, phase: DemoPhase.starting);
    }
    logInfo('Demo sequence started for ${drones.length} drone(s)', _tag);
    notifyListeners();

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
      notifyListeners();
    }
  }

  void clear() {
    if (_progress.isEmpty) return;
    _progress.clear();
    notifyListeners();
  }

  void handleEvent(int droneId, MissionEvent event) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) return;

    if (event == MissionEvent.missionDone || event == MissionEvent.landed) {
      _progress[droneId] =
          p.copyWith(phase: DemoPhase.finished, detail: event.wire.toLowerCase());
      logInfo('Drone $droneId finished the demo after ${p.steps} step(s)', _tag);
      notifyListeners();
      return;
    }

    // Arrival is what advances the sequence -- an ACK only means the MOVE was
    // accepted, and stepping on it would queue the next hop mid-flight.
    if (event == MissionEvent.waypointReached) _advance(droneId, p);
  }

  /// Telemetry is what opens the sequence: the first hop waits for `HOVER`.
  ///
  /// The `START_DEMO` ACK only says the drone accepted the mission -- it is
  /// still on the ground, and arming plus the climb take seconds. A `MOVE` sent
  /// on that ACK is refused with `BAD_STATE`, which aborts the demo before it
  /// begins. `HOVER` is the drone saying it is up and waiting for work.
  void handleTelemetry(int droneId, TelemMessage telemetry) {
    final p = _progress[droneId];
    if (p == null || p.phase != DemoPhase.starting) return;
    if (telemetry.state != DroneState.hover) return;
    // No anchor yet means the START_DEMO ACK is still in flight; telemetry
    // repeats at 1 Hz, so the next one will open the sequence.
    if (p.figure.isEmpty) return;

    _advance(droneId, p);
  }

  /// Send the next vertex, or return home once the step cap is hit.
  void _advance(int droneId, DemoProgress p) {
    if (p.figure.isEmpty) {
      _returnHome(droneId, p, 'no anchor - START_DEMO ACK carried no position');
      return;
    }
    final steps = p.steps + 1;
    if (steps >= maxSteps) {
      logWarn('Drone $droneId hit the $maxSteps-step cap - returning home', _tag);
      _returnHome(droneId, p.copyWith(steps: steps), 'step cap reached');
      return;
    }

    final target = p.figure[steps % p.figure.length];
    _progress[droneId] = p.copyWith(phase: DemoPhase.stepping, steps: steps);
    logTrace(_tag, 'drone $droneId -> vertex ${steps % p.figure.length} '
        '(${target.latitude},${target.longitude})');
    notifyListeners();

    unawaited(_tracker.send((q) => MoveMessage(seq: q, target: target), dest: droneId));
  }

  void _onAcknowledged(int droneId, MissionMessage command, AckMessage ack) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) return;
    if (command is! StartDemoMessage) return;   // MOVE acks are not arrivals

    final anchor = ack.position;
    if (anchor == null) {
      _returnHome(droneId, p, 'START_DEMO ACK carried no position');
      return;
    }

    final figure = [
      for (var i = 0; i < vertexCount; i++)
        offsetLatLng(anchor, i * 360.0 / vertexCount, radiusMeters),
    ];
    logInfo('Drone $droneId anchored at ${anchor.latitude},${anchor.longitude} - '
        '$vertexCount vertices at ${radiusMeters}m, waiting for HOVER', _tag);

    // steps starts at -1 so the first _advance lands on vertex 0. That advance
    // is handleTelemetry's job -- the drone has not left the ground yet.
    _progress[droneId] = p.copyWith(figure: figure, steps: -1);
    notifyListeners();
  }

  void _onFailed(AckFailure failure) {
    final p = _progress[failure.droneId];
    if (p == null || !p.isActive) return;
    if (failure.message is! StartDemoMessage && failure.message is! MoveMessage) {
      return;
    }
    _returnHome(failure.droneId, p, failure.description);
  }

  void _returnHome(int droneId, DemoProgress p, String reason) {
    _progress[droneId] =
        p.copyWith(phase: DemoPhase.returning, detail: reason);
    logError('Drone $droneId: $reason — sending RTH', _tag);
    notifyListeners();

    unawaited(_tracker.send((q) => RthMessage(seq: q), dest: droneId));
  }

  @override
  void dispose() {
    _tracker.onAcknowledged = null;
    _tracker.onFailed = null;
    super.dispose();
  }
}
