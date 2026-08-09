import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/services/command_tracker.dart';
import 'package:flutter_esp_android_communication/services/debug_traffic.dart';

class FakeSender {
  final sent = <MissionMessage>[];

  /// How long the transport takes to accept a message. Non-zero stands in for
  /// a link that cannot keep up with the requested interval.
  Duration latency = Duration.zero;

  Future<bool> call(int dest, MissionMessage message) async {
    sent.add(message);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    return true;
  }
}

const _interval = Duration(milliseconds: 20);

({CommandTracker tracker, DebugTraffic debug}) make(FakeSender sender) {
  final tracker = CommandTracker(
    sender: sender.call,
    knownDrones: const [1, 2],
    ackTimeout: const Duration(seconds: 30), // never retry during a test
  );
  return (tracker: tracker, debug: DebugTraffic(tracker: tracker)..interval = _interval);
}

void main() {
  test('sends STATUS on the interval until stopped', () async {
    final sender = FakeSender();
    final (: tracker, : debug) = make(sender);

    debug.start(dest: kBroadcastAddress);
    expect(sender.sent, hasLength(1), reason: 'first one goes out immediately');

    await Future<void>.delayed(_interval * 5);
    debug.stop();
    final atStop = sender.sent.length;

    expect(atStop, greaterThanOrEqualTo(4));
    expect(sender.sent.every((m) => m is StatusMessage), isTrue);
    expect(debug.sent, atStop);

    await Future<void>.delayed(_interval * 5);
    expect(sender.sent, hasLength(atStop), reason: 'stop must mean stop');

    debug.dispose();
    tracker.dispose();
  });

  test('never reuses a sequence number a real command could be holding',
      () async {
    final sender = FakeSender();
    final (: tracker, : debug) = make(sender);

    debug.start(dest: kBroadcastAddress);
    await tracker.send((q) => LandMessage(seq: q), dest: 1);
    await Future<void>.delayed(_interval * 5);
    debug.stop();

    final seqs = sender.sent.map((m) => m.seq).toList();
    expect(seqs.toSet(), hasLength(seqs.length),
        reason: 'a duplicate seq would make the drone dedupe away a real order');

    debug.dispose();
    tracker.dispose();
  });

  test('a link that cannot keep up skips ticks instead of queueing them',
      () async {
    final sender = FakeSender()..latency = _interval * 10;
    final (: tracker, : debug) = make(sender);

    debug.start(dest: kBroadcastAddress);
    await Future<void>.delayed(_interval * 5);
    debug.stop();

    expect(sender.sent, hasLength(1), reason: 'the first send is still in flight');
    expect(debug.skipped, greaterThanOrEqualTo(3));

    debug.dispose();
    tracker.dispose();
  });

  test('changing the interval keeps the run going and the counters intact',
      () async {
    final sender = FakeSender();
    final (: tracker, : debug) = make(sender);

    debug.start(dest: kBroadcastAddress);
    await Future<void>.delayed(_interval * 3);
    final before = debug.sent;

    debug.setInterval(const Duration(milliseconds: 5));
    expect(debug.isRunning, isTrue);
    expect(debug.sent, before, reason: 'a retune is not a restart');

    await Future<void>.delayed(_interval * 3);
    expect(debug.sent, greaterThan(before + 3), reason: 'the shorter gap took');

    debug.stop();
    debug.dispose();
    tracker.dispose();
  });
}
