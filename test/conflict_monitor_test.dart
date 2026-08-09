import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_esp_android_communication/pathfinding/local_frame.dart';
import 'package:flutter_esp_android_communication/services/conflict_monitor.dart';

const _origin = LatLng(50.062975, 19.9157);
final _t0 = DateTime.utc(2026, 8, 9, 12, 0, 0);
DateTime at(int ms) => _t0.add(Duration(milliseconds: ms));

/// Point [metres] from the origin on [bearing].
LatLng p(double bearing, double metres) => offsetLatLng(_origin, bearing, metres);

/// Feed two fixes so the monitor has a speed for this drone.
void track(ConflictMonitor m, int id, LatLng from, LatLng to,
    {int startMs = 0, int dtMs = 1000, Duration? age}) {
  m.observe(id, from, at(startMs), sampleAge: age);
  m.observe(id, to, at(startMs + dtMs), sampleAge: age);
}

void main() {
  test('a drone with a poor fix is given a wider berth', () {
    // Same geometry, same speed, same staleness. The only difference is what
    // the receivers say about themselves.
    ConflictMonitor build(double accuracy) {
      final m = ConflictMonitor(clearanceMeters: 4.0);
      for (final t in [0, 1000]) {
        m.observe(1, p(0, 0), at(t), reportedSpeed: 0.0, accuracyMeters: accuracy);
        m.observe(2, p(90, 8), at(t), reportedSpeed: 0.0, accuracyMeters: accuracy);
      }
      m.setTarget(1, null);
      m.setTarget(2, null);
      return m;
    }

    final good = build(0.3).closestApproach(1, 2)!;
    final poor = build(2.5).closestApproach(1, 2)!;

    expect(good, closeTo(8.0 - 0.6, 0.1));
    expect(poor, closeTo(8.0 - 5.0, 0.1),
        reason: 'both drones could be 2.5 m from where they claim');
    expect(build(2.5).conflicts([1, 2]), isNotEmpty,
        reason: '4 m of clearance is not met once the fixes are that loose');
    expect(build(0.3).conflicts([1, 2]), isEmpty);
  });

  test('a drone that reports no accuracy is not silently treated as perfect', () {
    // Absent accuracy contributes nothing, so clearance alone governs -- which
    // is exactly the behaviour from before the field existed.
    final m = ConflictMonitor(clearanceMeters: 3.0);
    for (final t in [0, 1000]) {
      m.observe(1, p(0, 0), at(t), reportedSpeed: 0.0);
      m.observe(2, p(90, 8), at(t), reportedSpeed: 0.0);
    }
    m.setTarget(1, null);
    m.setTarget(2, null);

    expect(m.closestApproach(1, 2), closeTo(8.0, 0.1));
    expect(m.conflicts([1, 2]), isEmpty);
  });

  test('a reported speed is used instead of guessing from positions', () {
    final m = ConflictMonitor(clearanceMeters: 4.0);
    // Two fixes 1 m apart a second apart say "1 m/s". The drone says it is
    // actually doing 4 m/s -- it accelerated between the samples, which is
    // exactly what differencing cannot see.
    m.observe(1, p(180, 10), at(0), reportedSpeed: 4.0);
    m.observe(1, p(180, 9), at(1000), reportedSpeed: 4.0);
    m.observe(2, p(0, 6), at(0), reportedSpeed: 0.0);
    m.observe(2, p(0, 6), at(1000), reportedSpeed: 0.0);
    m.setTarget(1, p(0, 6));      // heading for where drone 2 is parked
    m.setTarget(2, null);

    // At 4 m/s it covers the 15 m in under the horizon, so this is a conflict.
    expect(m.closestApproach(1, 2), lessThan(4.0));

    // Told 1 m/s -- the number differencing would have produced -- it looks
    // clear, and the drone would have been sent on its way.
    final slow = ConflictMonitor(clearanceMeters: 4.0);
    slow.observe(1, p(180, 10), at(0), reportedSpeed: 1.0);
    slow.observe(1, p(180, 9), at(1000), reportedSpeed: 1.0);
    slow.observe(2, p(0, 6), at(0), reportedSpeed: 0.0);
    slow.observe(2, p(0, 6), at(1000), reportedSpeed: 0.0);
    slow.setTarget(1, p(0, 6));
    slow.setTarget(2, null);
    expect(slow.closestApproach(1, 2), greaterThan(4.0));
  });

  test('a guessed speed is carried with more margin than a measured one', () {
    // Identical motion in both cases -- each drone really does move 2 m north
    // in 1 s, so the inferred speed works out to the same 2 m/s the drone would
    // have reported. The only thing that differs is whether it told us.
    ConflictMonitor build({required bool reported}) {
      final m = ConflictMonitor(clearanceMeters: 3.0);
      const stale = Duration(seconds: 2);
      final speed = reported ? 2.0 : null;
      final startA = offsetLatLng(_origin, 180, 2);
      final endA = _origin;
      final startB = offsetLatLng(p(90, 8), 180, 2);
      final endB = p(90, 8);

      m.observe(1, startA, at(0), sampleAge: stale, reportedSpeed: speed);
      m.observe(2, startB, at(0), sampleAge: stale, reportedSpeed: speed);
      m.observe(1, endA, at(1000), sampleAge: stale, reportedSpeed: speed);
      m.observe(2, endB, at(1000), sampleAge: stale, reportedSpeed: speed);
      m.setTarget(1, null);
      m.setTarget(2, null);
      return m;
    }

    final measured = build(reported: true).closestApproach(1, 2)!;
    final guessed = build(reported: false).closestApproach(1, 2)!;
    expect(guessed, lessThan(measured),
        reason: 'an inferred speed must cost margin, not be trusted equally');
  });

  test('drones running parallel keep their distance', () {
    final m = ConflictMonitor(clearanceMeters: 4.0);
    // 10 m apart, both heading north at 1 m/s. They never converge.
    track(m, 1, p(0, 0), p(0, 1));
    track(m, 2, p(90, 10), offsetLatLng(p(90, 10), 0, 1));
    m.setTarget(1, p(0, 20));
    m.setTarget(2, offsetLatLng(p(90, 10), 0, 20));

    expect(m.conflicts([1, 2]), isEmpty);
    expect(m.closestApproach(1, 2), greaterThan(9.0));
  });

  test('a crossing is caught before the drones are actually close', () {
    final m = ConflictMonitor(clearanceMeters: 4.0);
    // 16 m apart right now -- nowhere near each other -- but both doing 2 m/s
    // at the same point 8 m ahead of each.
    final meeting = p(0, 6);
    track(m, 1, p(180, 4), p(180, 2), dtMs: 1000);
    track(m, 2, p(0, 16), p(0, 14), dtMs: 1000);
    m.setTarget(1, meeting);
    m.setTarget(2, meeting);

    expect(const Distance(roundResult: false)(p(180, 2), p(0, 14)),
        greaterThan(15.0),
        reason: 'a check on current separation alone would see nothing wrong');
    expect(m.closestApproach(1, 2), lessThan(1.0));
    final found = m.conflicts([1, 2]);
    expect(found, hasLength(1));
    expect({found.first.a, found.first.b}, {1, 2});
  });

  test('a stale fix widens the drone, it does not vanish', () {
    final m = ConflictMonitor(clearanceMeters: 3.0);
    // Two drones 8 m apart, both parked. Fresh, that is comfortably clear.
    track(m, 1, p(0, 0), p(0, 0));
    track(m, 2, p(90, 8), p(90, 8));
    m.setTarget(1, null);
    m.setTarget(2, null);
    final whenFresh = m.closestApproach(1, 2)!;

    // Same positions, but each fix was 2 s old on arrival and the drones were
    // last seen doing 2 m/s: each could be 4 m from where it claims.
    final m2 = ConflictMonitor(clearanceMeters: 3.0);
    track(m2, 1, p(0, 0), p(0, 2), age: const Duration(seconds: 2));
    track(m2, 2, p(90, 8), offsetLatLng(p(90, 8), 0, 2),
        age: const Duration(seconds: 2));
    m2.setTarget(1, null);
    m2.setTarget(2, null);

    expect(whenFresh, greaterThan(7.0));
    expect(m2.closestApproach(1, 2)!, lessThan(whenFresh),
        reason: 'an old fix must cost margin, not be taken at face value');
  });

  test('a step can be vetoed before it is sent', () {
    final m = ConflictMonitor(clearanceMeters: 4.0);
    track(m, 1, p(180, 4), p(180, 2));
    track(m, 2, p(0, 2), p(0, 2));      // drone 2 parked 2 m north of origin
    m.setTarget(1, null);
    m.setTarget(2, null);

    // Sending drone 1 straight at where drone 2 is parked is refused ...
    expect(m.blockerFor(1, p(0, 2), [1, 2]), 2);
    // ... while a step the other way is fine.
    expect(m.blockerFor(1, p(180, 20), [1, 2]), isNull);
  });

  test('a drone we have never heard from blocks nothing and hides nothing', () {
    final m = ConflictMonitor(clearanceMeters: 4.0);
    track(m, 1, p(0, 0), p(0, 1));

    expect(m.closestApproach(1, 99), isNull);
    expect(m.conflicts([1, 99]), isEmpty,
        reason: 'unknown is reported as unknown, not as a conflict');
    expect(m.knows(99), isFalse);
  });
}
