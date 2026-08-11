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

  // ---- BUSY answering our own retry is not a rejection ---------------------

  test('BUSY on a retried START_DEMO settles it - the ACK can never come',
      () async {
    final sender = FakeSender();
    final tracker = CommandTracker(
      sender: sender.call,
      knownDrones: [1],
      ackTimeout: const Duration(milliseconds: 50),
      maxAttempts: 5,
    );
    final failures = <AckFailure>[];
    tracker.onFailed = failures.add;
    final acked = <MissionMessage>[];
    tracker.onAcknowledged = (_, command, _) => acked.add(command);

    final seq = await tracker.send(
        (q) => StartDemoMessage(seq: q, altitude: 3.0), dest: 1);

    // The drone accepted attempt 1 but its ACK was lost, so it is no longer IDLE
    // when our retry arrives and it answers BUSY.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(sender.sent.length, greaterThan(1), reason: 'it retried');
    tracker.handleIncoming(
      1,
      NackMessage(seq: 500, respondingTo: seq, error: NackError.busy),
    );

    expect(failures, isEmpty,
        reason: 'aborting here lands a drone that is already climbing');
    expect(tracker.isAwaitingAck(1), isFalse,
        reason: 'the drone told us it holds the command, so it is settled; the '
            'ACK it would send has already been consumed and every future copy '
            'can only be answered BUSY again');

    // Nothing keeps ticking, so nothing can time out later and land a drone that
    // is by then flying the figure -- which is what happened on 2026-08-11.
    final before = sender.sent.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(sender.sent.length, before);
    expect(failures, isEmpty);

    // A late ACK is now a duplicate. It must not be reported as an acknowledgement
    // twice, and the anchor comes from the drone's arrival report instead.
    tracker.handleIncoming(
      1,
      AckMessage(seq: 501, respondingTo: seq, position: const LatLng(50.0, 19.0)),
    );
    expect(acked, isEmpty);

    tracker.dispose();
  });

  test('BUSY on a first attempt is still a real rejection', () async {
    final sender = FakeSender();
    final tracker = CommandTracker(
      sender: sender.call,
      knownDrones: [1],
      ackTimeout: const Duration(seconds: 30),
      maxAttempts: 3,
    );
    final failures = <AckFailure>[];
    tracker.onFailed = failures.add;

    final seq = await tracker.send(
        (q) => StartDemoMessage(seq: q, altitude: 3.0), dest: 1);
    tracker.handleIncoming(
      1,
      NackMessage(seq: 500, respondingTo: seq, error: NackError.busy),
    );

    expect(failures, hasLength(1),
        reason: 'nothing of ours could have caused this one');
    expect(failures.single.kind, AckFailureKind.rejected);

    tracker.dispose();
  });
}
