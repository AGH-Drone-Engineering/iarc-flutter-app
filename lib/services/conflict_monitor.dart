import 'dart:math';

import 'package:latlong2/latlong.dart';

/// Predicts whether two drones are about to get too close, from position alone.
///
/// This is what stands in for the lockstep barrier when the operator lets the
/// drones advance independently. Lockstep guarantees separation geometrically;
/// off-step there is no guarantee, so every step has to be checked.
///
/// ## Why a clearance number and not a computed accuracy
///
/// Nothing on the wire says how good a fix is. TELEM carries lat/lon/alt/state
/// and nothing else — the drone reads `eph` and satellite count from MAVLink and
/// gates arming on them, but never reports them. So the phone cannot derive a
/// position error, and pretending otherwise would be inventing a number. The
/// operator sets [clearanceMeters] instead: the separation they want kept,
/// covering GPS error, airframe size and how sloppily the drone tracks a line.
///
/// ## What it does compute
///
/// Two things it *can* know are used to inflate that number honestly:
///
///  * **Speed**, from consecutive fixes. With `ts` on TELEM the elapsed time
///    between two samples is the drone's own measurement, not our arrival times,
///    so a queued frame does not turn into a phantom acceleration.
///  * **Staleness**. A fix that is one second old, from a drone doing 2 m/s, has
///    the drone anywhere in a 2 m circle. That radius is added to the required
///    separation rather than hoped away.
///
/// Prediction is a straight run to the commanded vertex at the observed speed,
/// stopping there — which is what the drone actually does. Sampling that forward
/// beats a closed-form closest-approach because the stop at the vertex makes the
/// motion piecewise, and getting the corner case wrong here is not a rounding
/// error.
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

  static const _distance = Distance();

  /// Speed we assume when we have no measurement yet -- a drone that has only
  /// just been heard from could already be moving.
  static const double _assumedSpeed = 2.0;

  final Map<int, _Track> _tracks = {};

  /// Record where a drone is and when it sampled that.
  ///
  /// [sampleAge] is how old the fix was on arrival (from DroneClock); pass null
  /// when unknown, and it is treated as fresh — staleness is then somebody
  /// else's problem, not silently folded in as safety margin here.
  void observe(int droneId, LatLng position, DateTime at, {Duration? sampleAge}) {
    final previous = _tracks[droneId];
    var speed = previous?.speed ?? _assumedSpeed;

    if (previous != null) {
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
      age: sampleAge ?? Duration.zero,
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
      // Each drone has already been flying for however long its fix has been
      // in transit, so the clock starts before now, not at it.
      final pa = _advance(ta.position, targetA, ta.speed * (t + ta.ageSeconds));
      final pb = _advance(tb.position, targetB, tb.speed * (t + tb.ageSeconds));
      // Where it could be, not just where it says it is.
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
    this.target,
  });

  final LatLng position;
  final DateTime at;
  final double speed;
  final Duration age;
  LatLng? target;

  double get ageSeconds => age.inMilliseconds / 1000.0;

  /// How far from the reported point the drone could already be.
  double get uncertaintyMeters => speed * ageSeconds;
}
