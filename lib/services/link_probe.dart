import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/drone.dart';
import '../models/mission_message.dart';
import 'command_tracker.dart';
import 'global_log.dart';

const _tag = 'probe';

/// Measures the radio with the reliability layer switched off.
///
/// Sends numbered `PING`s at a fixed rate and reads the `PONG`s the drone emits
/// on its own timer. Nothing is acknowledged, retried or deduped in either
/// direction, which is the entire point: every loss figure we had until now came
/// from missing ACKs, and a missing ACK cannot tell
///
///   * the command never arrived, from
///   * the command arrived and its answer was lost
///
/// while the answer itself costs a transmission — so asking the question changed
/// the thing being measured. On 2026-08-10 that ambiguity was the difference
/// between "the link is broken" and "we are asking too often".
///
/// [DebugTraffic] is the opposite instrument and both are worth having: it puts
/// `STATUS` through [CommandTracker] deliberately, so it measures the link *plus*
/// the machinery. This measures the link alone. Run them in turn and the gap
/// between the two numbers is what the machinery costs.
class LinkProbe extends ChangeNotifier {
  LinkProbe({required CommandTracker tracker}) : _tracker = tracker;

  final CommandTracker _tracker;

  /// Gap between pings. Small enough to gather a sample quickly, large enough
  /// not to be the cause of what it measures — at SF7/BW500 a frame is ~50 ms on
  /// air, so anything under about 100 ms is measuring self-collision.
  Duration interval = const Duration(milliseconds: 250);

  Timer? _timer;
  int _dest = 1;

  /// Pings put on the wire. Not "delivered" — nothing here claims that.
  int sent = 0;

  /// PONGs that reached us.
  int pongs = 0;

  /// Newest counters the drone reported.
  int? droneRx;
  int? droneTx;
  int? droneLastSeen;

  DateTime? _startedAt;
  DateTime? lastPongAt;

  bool get isRunning => _timer != null;
  int get dest => _dest;

  /// Fraction of our pings the drone never saw, or null before it has told us.
  ///
  /// Read from the drone's own count rather than inferred, so it is a
  /// measurement rather than a deduction.
  double? get uplinkLoss {
    final rx = droneRx;
    if (rx == null || sent == 0) return null;
    return ((sent - rx) / sent).clamp(0.0, 1.0);
  }

  /// Fraction of the drone's PONGs that never reached us.
  double? get downlinkLoss {
    final tx = droneTx;
    if (tx == null || tx == 0) return null;
    return ((tx - pongs) / tx).clamp(0.0, 1.0);
  }

  Duration? get elapsed =>
      _startedAt == null ? null : DateTime.now().difference(_startedAt!);

  void start({required int dest}) {
    stop();
    _dest = dest;
    sent = 0;
    pongs = 0;
    droneRx = null;
    droneTx = null;
    droneLastSeen = null;
    lastPongAt = null;
    _startedAt = DateTime.now();
    logInfo('Link probe -> ${Drone.nameFor(dest)} every '
        '${interval.inMilliseconds} ms, nothing acknowledged either way', _tag);
    _timer = Timer.periodic(interval, (_) => _tick());
    notifyListeners();
  }

  void stop() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    logInfo('Link probe stopped. ${summary()}', _tag);
    notifyListeners();
  }

  void _tick() {
    // Counted as sent before the await: this is a measure of what we asked the
    // radio to do. Whether the USB write itself succeeded is a different fault
    // and shows up in the transport's own log.
    final n = ++sent;
    unawaited(_tracker.ping(_dest, (q) => PingMessage(seq: q, n: n)));
    notifyListeners();
  }

  /// Feed a `PONG`. Ignores ones from other drones so two probes cannot mix.
  void handlePong(int from, PongMessage pong) {
    if (from != _dest) return;
    pongs++;
    droneRx = pong.rx;
    droneTx = pong.tx;
    droneLastSeen = pong.last;
    lastPongAt = DateTime.now();
    notifyListeners();
  }

  String summary() {
    String pct(double? v) => v == null ? '?' : '${(v * 100).toStringAsFixed(0)}%';
    return 'sent=$sent droneSaw=${droneRx ?? "?"} (up ${pct(uplinkLoss)} lost) | '
        'pongs=$pongs droneSent=${droneTx ?? "?"} (down ${pct(downlinkLoss)} lost)';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
