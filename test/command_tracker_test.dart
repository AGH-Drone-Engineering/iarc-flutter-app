import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/services/command_tracker.dart';

class FakeSender {
  final sent = <({int dest, MissionMessage message})>[];
  bool accept = true;

  Future<bool> call(int dest, MissionMessage message) async {
    sent.add((dest: dest, message: message));
    return accept;
  }
}

const _timeout = Duration(milliseconds: 40);

CommandTracker makeTracker(FakeSender sender, {List<int> drones = const [1, 2]}) =>
    CommandTracker(
      sender: sender.call,
      knownDrones: drones,
      ackTimeout: _timeout,
      maxAttempts: 3,
    );

Future<void> settle([int multiplier = 5]) =>
    Future<void>.delayed(_timeout * multiplier);

void main() {
  test('an ACK resolves the command with no failure', () async {
    final sender = FakeSender();
    final tracker = makeTracker(sender);

    await tracker.send((q) => LandMessage(seq: q), dest: 1);
    expect(tracker.isAwaitingAck(1), isTrue);

    final seq = sender.sent.single.message.seq;
    tracker.handleIncoming(1, AckMessage(seq: 99, respondingTo: seq));

    expect(tracker.isAwaitingAck(1), isFalse);
    expect(tracker.failures, isEmpty);

    await settle();
    expect(sender.sent, hasLength(1), reason: 'must not retry an acked command');
    tracker.dispose();
  });

  test('silence retries then raises a failure', () async {
    final sender = FakeSender();
    final tracker = makeTracker(sender);

    await tracker.send((q) => LandMessage(seq: q), dest: 1);
    await settle(10);

    expect(sender.sent, hasLength(3), reason: '1 initial + 2 retries');
    expect(
      sender.sent.map((s) => s.message.seq).toSet(),
      hasLength(1),
      reason: 'retries must reuse the sequence number so the drone can dedupe',
    );

    final failure = tracker.failureFor(1);
    expect(failure, isNotNull);
    expect(failure!.kind, AckFailureKind.silence);
    expect(failure.attempts, 3);
    expect(tracker.hasCriticalFailure, isTrue);
    tracker.dispose();
  });

  test('an ACK arriving mid-retry stops further attempts', () async {
    final sender = FakeSender();
    final tracker = makeTracker(sender);

    await tracker.send((q) => LandMessage(seq: q), dest: 1);
    await Future<void>.delayed(_timeout * 2); // let one retry happen

    final seq = sender.sent.first.message.seq;
    tracker.handleIncoming(1, AckMessage(seq: 99, respondingTo: seq));
    final countAtAck = sender.sent.length;

    await settle(10);
    expect(sender.sent, hasLength(countAtAck));
    expect(tracker.failures, isEmpty);
    tracker.dispose();
  });

  test('a NACK records the rejection reason', () async {
    final sender = FakeSender();
    final tracker = makeTracker(sender);

    await tracker.send((q) => StartDemoMessage(seq: q, altitude: 3.0), dest: 1);
    final seq = sender.sent.single.message.seq;

    tracker.handleIncoming(
      1,
      NackMessage(seq: 50, respondingTo: seq, error: NackError.noGps),
    );

    final failure = tracker.failureFor(1)!;
    expect(failure.kind, AckFailureKind.rejected);
    expect(failure.reason, NackError.noGps);
    expect(failure.description, contains('NO_GPS'));
    expect(tracker.isAwaitingAck(1), isFalse);
    tracker.dispose();
  });

  test('broadcast tracks each drone independently', () async {
    final sender = FakeSender();
    final tracker = makeTracker(sender, drones: [1, 2, 3]);

    await tracker.send(
      (q) => StartDemoMessage(seq: q, altitude: 3.0),
      dest: kBroadcastAddress,
    );
    expect(sender.sent, hasLength(1), reason: 'broadcast transmits once');

    final seq = sender.sent.single.message.seq;
    tracker.handleIncoming(1, AckMessage(seq: 90, respondingTo: seq));
    tracker.handleIncoming(3, AckMessage(seq: 91, respondingTo: seq));

    expect(tracker.isAwaitingAck(2), isTrue);
    expect(tracker.isAwaitingAck(1), isFalse);

    await settle(10);

    expect(tracker.failureFor(2), isNotNull, reason: 'the silent drone must alert');
    expect(tracker.failureFor(1), isNull);
    expect(tracker.failureFor(3), isNull);
    tracker.dispose();
  });

  test('a rejected transmission fails immediately without retrying', () async {
    final sender = FakeSender()..accept = false;
    final tracker = makeTracker(sender);

    await tracker.send((q) => LandMessage(seq: q), dest: 1);

    final failure = tracker.failureFor(1)!;
    expect(failure.kind, AckFailureKind.linkDown);
    expect(sender.sent, hasLength(1));
    tracker.dispose();
  });

  test('hearing from a silent drone clears its alert', () async {
    final sender = FakeSender();
    final tracker = makeTracker(sender);

    await tracker.send((q) => LandMessage(seq: q), dest: 1);
    await settle(10);
    expect(tracker.failureFor(1), isNotNull);

    tracker.handleIncoming(
      1,
      TelemMessage(
        seq: 1,
        position: LatLng(50.062975, 19.9157),
        altitude: 3.0,
        state: DroneState.hover,
      ),
    );

    expect(tracker.failureFor(1), isNull, reason: 'contact proves it is alive');
    tracker.dispose();
  });

  test('a rejection alert survives further telemetry until dismissed', () async {
    final sender = FakeSender();
    final tracker = makeTracker(sender);

    await tracker.send((q) => LandMessage(seq: q), dest: 1);
    final seq = sender.sent.single.message.seq;
    tracker.handleIncoming(
      1,
      NackMessage(seq: 5, respondingTo: seq, error: NackError.lowBatt),
    );

    tracker.handleIncoming(
      1,
      TelemMessage(
        seq: 6,
        position: LatLng(50.062975, 19.9157),
        altitude: 0.0,
        state: DroneState.idle,
      ),
    );
    expect(tracker.failureFor(1), isNotNull, reason: 'a considered refusal must persist');

    tracker.dismissFailure(1);
    expect(tracker.failureFor(1), isNull);
    tracker.dispose();
  });

  test('the attempt count can be changed while the app runs', () async {
    final sender = FakeSender();
    final tracker = makeTracker(sender);

    tracker.maxAttempts = 1;
    await tracker.send((q) => LandMessage(seq: q), dest: 1);
    await settle(10);

    expect(sender.sent, hasLength(1), reason: 'one attempt means no retry');
    expect(tracker.failureFor(1)!.attempts, 1);

    sender.sent.clear();
    tracker.dismissAll();
    tracker.maxAttempts = 2;
    await tracker.send((q) => LandMessage(seq: q), dest: 2);
    await settle(10);

    expect(sender.sent, hasLength(2), reason: '1 initial + 1 retry');
    tracker.dispose();
  });

  test('a longer ACK timeout holds the retry off', () async {
    final sender = FakeSender();
    final tracker = makeTracker(sender);

    tracker.ackTimeout = const Duration(seconds: 30);
    await tracker.send((q) => LandMessage(seq: q), dest: 1);
    await settle(10);

    expect(sender.sent, hasLength(1), reason: 'still well inside the timeout');
    expect(tracker.failures, isEmpty);
    tracker.dispose();
  });
}
