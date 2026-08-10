import '../models/mission_message.dart';

/// Ages a drone's position fixes without a shared clock.
///
/// TELEM carries `ts`: milliseconds on the drone's own monotonic clock, taken
/// when it read the position. A Pi in the field has no RTC, so its calendar
/// time is meaningless to us -- but age is recoverable. `receivedAt - ts` is the
/// clock offset plus that frame's queueing delay; queueing is never negative, so
/// the smallest value ever seen is the best estimate of the pure offset, and
/// anything above it is transit delay.
///
/// This matters because arrival time lies on a polled link: a frame can sit in
/// the ESP's queue for seconds, so a position that arrives "just now" may
/// describe where the drone was several seconds ago.
class DroneClock {
  DroneClock({this.rebootSlack = const Duration(seconds: 30)});

  /// How far `ts` may run backwards before we call it a restart rather than a
  /// frame that queued. Generous on purpose: reading a late frame as a reboot
  /// throws away a good offset estimate, while reading a reboot as a late frame
  /// only makes positions look stale, which fails safe.
  final Duration rebootSlack;

  final Map<int, _Estimate> _byDrone = {};

  /// Fold in one telemetry frame. [receivedAt] should be the moment it was
  /// parsed. Frames without `ts` are ignored -- [ageOf] falls back to arrival.
  void observe(int droneId, TelemMessage telemetry, DateTime receivedAt) {
    final sampleMs = telemetry.sampleMs;
    if (sampleMs == null) return;

    final previous = _byDrone[droneId];
    if (previous == null) {
      _byDrone[droneId] = _Estimate.from(sampleMs, receivedAt);
      return;
    }

    if (sampleMs < previous.lastSampleMs - rebootSlack.inMilliseconds) {
      // Far enough back that no queue explains it: the drone restarted and the
      // offset we learned describes a clock that no longer exists.
      _byDrone[droneId] = _Estimate.from(sampleMs, receivedAt);
      return;
    }

    // A smaller step backwards is ordinary: a frame that waited its turn on the
    // radio arrives after fresher ones. That is exactly what we want to be able
    // to see, so it must not be mistaken for a reboot.
    if (sampleMs > previous.lastSampleMs) previous.lastSampleMs = sampleMs;

    final offsetMs = receivedAt.millisecondsSinceEpoch - sampleMs;
    if (offsetMs < previous.minOffsetMs) previous.minOffsetMs = offsetMs;
  }

  /// How old [telemetry] is as of [now], or null when it cannot be established.
  ///
  /// Null means "unknown", never "fine" -- a caller deciding whether a drone is
  /// where it should be must treat that as loss of knowledge, not as consent.
  Duration? ageOf(int droneId, TelemMessage telemetry, DateTime now) {
    final sampleMs = telemetry.sampleMs;
    final estimate = _byDrone[droneId];
    if (sampleMs == null || estimate == null) return null;
    return Duration(
      milliseconds: now.millisecondsSinceEpoch - (sampleMs + estimate.minOffsetMs),
    );
  }

  /// True once this drone has sent a usable `ts`.
  bool knows(int droneId) => _byDrone.containsKey(droneId);

  void forget(int droneId) => _byDrone.remove(droneId);

  void clear() => _byDrone.clear();
}

class _Estimate {
  _Estimate({required this.minOffsetMs, required this.lastSampleMs});

  factory _Estimate.from(int sampleMs, DateTime receivedAt) => _Estimate(
        minOffsetMs: receivedAt.millisecondsSinceEpoch - sampleMs,
        lastSampleMs: sampleMs,
      );

  int minOffsetMs;
  int lastSampleMs;
}
