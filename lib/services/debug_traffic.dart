import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/mission_message.dart';
import 'command_tracker.dart';
import 'global_log.dart';

const _tag = 'debug';

/// Puts STATUS on the link on a loop, to see how it holds up under sustained
/// traffic.
///
/// STATUS because it is the smallest message that expects an ACK and the only
/// one that moves nothing: the drone answers and stays where it is.
///
/// It goes out through [CommandTracker] rather than straight down the
/// transport so that it draws from the same sequence counter. A private
/// counter would hand out numbers the drones are already deduping against, and
/// the debug loop would start swallowing real commands. Sending it through the
/// tracker also means the ACK timeout and retry count on the link tab are the
/// ones being exercised -- set the attempts to 1 to make the interval the true
/// on-air rate.
class DebugTraffic extends ChangeNotifier {
  DebugTraffic({required CommandTracker tracker}) : _tracker = tracker;

  final CommandTracker _tracker;

  /// Gap between ticks. A tick landing while the previous message is still on
  /// its way out is skipped rather than queued, so this is a ceiling on the
  /// rate rather than a promise -- an unbounded queue would only measure how
  /// fast the app can fill memory.
  Duration interval = const Duration(milliseconds: 1000);

  Timer? _timer;
  bool _inFlight = false;
  int _dest = kBroadcastAddress;

  int sent = 0;
  int skipped = 0;

  bool get isRunning => _timer != null;
  int get dest => _dest;

  void start({required int dest}) {
    _dest = dest;
    sent = 0;
    skipped = 0;
    _arm();
    logWarn('Debug traffic started: STATUS every ${interval.inMilliseconds} ms '
        'to $dest', _tag);
    notifyListeners();
    // Straight away, rather than making the operator wait out the first gap.
    unawaited(_tick());
  }

  void stop() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    logWarn('Debug traffic stopped after $sent sent, $skipped skipped', _tag);
    notifyListeners();
  }

  void setInterval(Duration value) {
    if (value <= Duration.zero || value == interval) return;
    interval = value;
    if (isRunning) _arm();
    notifyListeners();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (_inFlight) {
      skipped++;
      notifyListeners();
      return;
    }
    _inFlight = true;
    sent++;
    notifyListeners();
    try {
      await _tracker.send((q) => StatusMessage(seq: q), dest: _dest);
    } finally {
      _inFlight = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
