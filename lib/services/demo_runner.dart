import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/mission_message.dart';
import 'command_tracker.dart';
import 'global_log.dart';

const _tag = 'demo';

enum DemoPhase { starting, stepping, returning, finished, stopped }

class DemoProgress {
  final int droneId;
  final DemoPhase phase;
  final int steps;
  final String? detail;

  const DemoProgress({
    required this.droneId,
    required this.phase,
    this.steps = 0,
    this.detail,
  });

  DemoProgress copyWith({DemoPhase? phase, int? steps, String? detail}) =>
      DemoProgress(
        droneId: droneId,
        phase: phase ?? this.phase,
        steps: steps ?? this.steps,
        detail: detail ?? this.detail,
      );

  bool get isActive => phase == DemoPhase.starting || phase == DemoPhase.stepping;
}

class DemoRunner extends ChangeNotifier {
  DemoRunner({required CommandTracker tracker, this.maxSteps = 200})
      : _tracker = tracker {
    _tracker.onAcknowledged = _onAcknowledged;
    _tracker.onFailed = _onFailed;
  }

  final CommandTracker _tracker;
  final int maxSteps;

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
    }
  }

  void _onAcknowledged(int droneId, MissionMessage command) {
    final p = _progress[droneId];
    if (p == null || !p.isActive) return;
    if (command is! StartDemoMessage && command is! NextStepMessage) return;

    final steps = command is NextStepMessage ? p.steps + 1 : p.steps;

    if (steps >= maxSteps) {
      logWarn('Drone $droneId hit the $maxSteps-step cap — returning home', _tag);
      _returnHome(droneId, p.copyWith(steps: steps), 'step cap reached');
      return;
    }

    _progress[droneId] = p.copyWith(phase: DemoPhase.stepping, steps: steps);
    logTrace(_tag, 'drone $droneId acked ${command.type}, advancing to step ${steps + 1}');
    notifyListeners();

    unawaited(_tracker.send((q) => NextStepMessage(seq: q), dest: droneId));
  }

  void _onFailed(AckFailure failure) {
    final p = _progress[failure.droneId];
    if (p == null || !p.isActive) return;
    if (failure.message is! StartDemoMessage && failure.message is! NextStepMessage) {
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
