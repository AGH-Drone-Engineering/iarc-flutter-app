import 'dart:math';

import 'package:latlong2/latlong.dart';

/// Predicts whether two drones are about to get too close, from position alone.
///
/// Stands in for the lockstep barrier when drones advance independently: there
/// is no geometric guarantee off-step, so every step is checked.
///
/// Each drone is treated as a disc sized by three things -- its reported `acc`,
/// how far it could have moved since that fix was taken, and its speed -- then
/// both discs are run forward along their commanded legs and the closest
/// approach compared against [clearanceMeters].
///
/// `acc` is the GPS receiver's own 1-sigma, taken before the EKF fuses IMU and
/// flow, so it bounds the error rather than measuring it. ArduPilot does not
/// publish the filter's own figure at all (`EKF_STATUS_REPORT` carries
/// dimensionless test ratios, and `ESTIMATOR_STATUS` is not sent), so
/// [clearanceMeters] stays as the operator's margin on top.
class ConflictMonitor {
  ConflictMonitor({
    this.clearanceMeters = 4.0,
    this.horizon = const Duration(seconds: 4),
    this.stepCount = 16,
  });

  /// Separation the operator wants kept between any two drones.
  double clearanceMeters;

  /// How far ahead to look. Long enough to see a crossing develop, short enough
  /// that a constant-velocity guess is still worth something.
  final Duration horizon;

  final int stepCount;

  // roundResult defaults to TRUE in latlong2: without this every separation
  // is quantised to whole metres, and a clearance check works in exactly the
  // range where that matters.
  static const _distance = Distance(roundResult: false);

  /// Speed we assume when we have no measurement yet -- a drone that has only
  /// just been heard from could already be moving.
  static const double _assumedSpeed = 2.0;

  final Map<int, _Track> _tracks = {};

  /// Record where a drone is, how fast it is going, and how old the fix was.
  ///
  /// [reportedSpeed] is preferred over differencing positions, which lags by
  /// half a sample and reads zero when two fixes land on the same spot. Omitted
  /// values contribute nothing rather than being guessed at.
  void observe(int droneId, LatLng position, DateTime at,
      {Duration? sampleAge, double? reportedSpeed, double? accuracyMeters}) {
    final previous = _tracks[droneId];
    var speed = previous?.speed ?? _assumedSpeed;

    if (reportedSpeed != null) {
      speed = reportedSpeed;
    } else if (previous != null) {
      final dt = at.difference(previous.at).inMilliseconds / 1000.0;
      if (dt > 0.05) {
        final observed = _distance(previous.position, position) / dt;
        // Smoothed, but biased upwards: a speed that reads too low shrinks the
        // predicted travel and hides a conflict, so jumps up are taken whole
        // and only decreases are averaged down.
        speed = observed > speed ? observed : (speed * 0.5 + observed * 0.5);
      }
    }

    _tracks[droneId] = _Track(
      position: position,
      at: at,
      speed: speed,
      measured: reportedSpeed != null,
      age: sampleAge ?? Duration.zero,
      accuracy: accuracyMeters ?? 0.0,
      target: previous?.target,
    );
  }

  /// Where this drone has been told to go, or null if it is holding.
  void setTarget(int droneId, LatLng? target) {
    final track = _tracks[droneId];
    if (track != null) track.target = target;
  }

  void forget(int droneId) => _tracks.remove(droneId);

  void clear() => _tracks.clear();

  bool knows(int droneId) => _tracks.containsKey(droneId);

  /// Closest the two drones are predicted to get, in metres, or null when
  /// either has never been heard from.
  ///
  /// [proposedFor]/[proposedTarget] substitute a target we are *considering*
  /// sending, so a step can be checked before it is committed.
  double? closestApproach(int a, int b, {int? proposedFor, LatLng? proposedTarget}) {
    final ta = _tracks[a];
    final tb = _tracks[b];
    if (ta == null || tb == null) return null;

    final targetA = proposedFor == a ? proposedTarget : ta.target;
    final targetB = proposedFor == b ? proposedTarget : tb.target;

    var worst = double.infinity;
    final horizonSeconds = horizon.inMilliseconds / 1000.0;
    for (var i = 0; i <= stepCount; i++) {
      final t = horizonSeconds * i / stepCount;
      // The clock starts before now: each drone has already been flying for as
      // long as its fix spent in transit.
      final pa = _advance(ta.position, targetA, ta.speed * (t + ta.ageSeconds));
      final pb = _advance(tb.position, targetB, tb.speed * (t + tb.ageSeconds));
      final margin = ta.uncertaintyMeters + tb.uncertaintyMeters;
      final separation = _distance(pa, pb) - margin;
      if (separation < worst) worst = separation;
    }
    return worst;
  }

  /// Every pair predicted to break clearance, worst first.
  List<Conflict> conflicts(Iterable<int> drones) {
    final ids = drones.toList()..sort();
    final found = <Conflict>[];
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final separation = closestApproach(ids[i], ids[j]);
        if (separation == null || separation >= clearanceMeters) continue;
        found.add(Conflict(a: ids[i], b: ids[j], separationMeters: separation));
      }
    }
    found.sort((x, y) => x.separationMeters.compareTo(y.separationMeters));
    return found;
  }

  /// Would sending [droneId] to [target] bring it inside clearance of anyone?
  ///
  /// Returns the drone it would conflict with, or null when the step is clear.
  int? blockerFor(int droneId, LatLng target, Iterable<int> others) {
    for (final other in others) {
      if (other == droneId) continue;
      final separation = closestApproach(droneId, other,
          proposedFor: droneId, proposedTarget: target);
      if (separation != null && separation < clearanceMeters) return other;
    }
    return null;
  }

  /// Straight-line travel of [metres] from [from] toward [target], stopping
  /// there. A drone with no target is holding, so it does not move.
  static LatLng _advance(LatLng from, LatLng? target, double metres) {
    if (target == null || metres <= 0) return from;
    final total = _distance(from, target);
    if (total <= 0.01) return target;
    final fraction = min(1.0, metres / total);
    return LatLng(
      from.latitude + (target.latitude - from.latitude) * fraction,
      from.longitude + (target.longitude - from.longitude) * fraction,
    );
  }
}

class Conflict {
  const Conflict({
    required this.a,
    required this.b,
    required this.separationMeters,
  });

  final int a;
  final int b;
  final double separationMeters;

  @override
  String toString() =>
      'drones $a and $b closing to ${separationMeters.toStringAsFixed(1)}m';
}

class _Track {
  _Track({
    required this.position,
    required this.at,
    required this.speed,
    required this.age,
    this.measured = false,
    this.accuracy = 0.0,
    this.target,
  });

  final LatLng position;
  final DateTime at;
  final double speed;

  /// True when [speed] came from the drone rather than from differencing our
  /// own view of its positions.
  final bool measured;

  final Duration age;

  /// Reported horizontal accuracy in metres; 0 when the drone reports none.
  final double accuracy;

  LatLng? target;

  double get ageSeconds => age.inMilliseconds / 1000.0;

  /// How far from the reported point the drone could already be.
  ///
  /// A guessed speed gets a margin on top: if we are inferring motion from 1 Hz
  /// fixes we can be a whole sample behind, and being wrong in the direction of
  /// "it is closer than I think" is the one that hurts.
  /// Where the drone could be: how far it may have travelled since the fix was
  /// taken, plus how wrong the fix itself may be.
  double get uncertaintyMeters =>
      speed * ageSeconds * (measured ? 1.0 : _guessPenalty) + accuracy;

  static const double _guessPenalty = 1.5;
}
