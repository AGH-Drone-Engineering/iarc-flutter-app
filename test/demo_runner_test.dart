import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/services/command_tracker.dart';
import 'package:flutter_esp_android_communication/services/demo_runner.dart';

class FakeSender {
  final sent = <({int dest, MissionMessage message})>[];
  bool accept = true;

  Future<bool> call(int dest, MissionMessage message) async {
    sent.add((dest: dest, message: message));
    return accept;
  }

  List<MissionMessage> to(int dest) =>
      sent.where((s) => s.dest == dest).map((s) => s.message).toList();

  MissionMessage lastTo(int dest) => to(dest).last;
}

const _timeout = Duration(milliseconds: 40);

({CommandTracker tracker, DemoRunner runner}) build(
  FakeSender sender, {
  List<int> drones = const [1, 2],
  int maxSteps = 200,
}) {
  final tracker = CommandTracker(
    sender: sender.call,
    knownDrones: drones,
    ackTimeout: _timeout,
    maxAttempts: 3,
  );
  return (tracker: tracker, runner: DemoRunner(tracker: tracker, maxSteps: maxSteps));
}

/// Simulates the drone acknowledging whatever it was last sent.
void ackLast(CommandTracker tracker, FakeSender sender, int drone) {
  tracker.handleIncoming(
    drone,
    AckMessage(seq: 9000, respondingTo: sender.lastTo(drone).seq),
  );
}

Future<void> settle([int multiplier = 10]) =>
    Future<void>.delayed(_timeout * multiplier);

void main() {
  test('an ACK advances the sequence to NEXT_STEP', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);

    await runner.start([1], 3.0);
    expect(sender.lastTo(1), isA<StartDemoMessage>());
    expect(runner.progressFor(1)!.phase, DemoPhase.starting);

    ackLast(tracker, sender, 1);
    await Future<void>.microtask(() {});

    expect(sender.lastTo(1), isA<NextStepMessage>());
    expect(runner.progressFor(1)!.phase, DemoPhase.stepping);
    expect(runner.progressFor(1)!.steps, 0);

    ackLast(tracker, sender, 1);
    await Future<void>.microtask(() {});

    expect(sender.to(1).whereType<NextStepMessage>(), hasLength(2));
    expect(runner.progressFor(1)!.steps, 1);

    runner.dispose();
    tracker.dispose();
  });

  test('the sequence keeps advancing while ACKs keep arriving', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);

    await runner.start([1], 3.0);
    for (var i = 0; i < 6; i++) {
      ackLast(tracker, sender, 1);
      await Future<void>.microtask(() {});
    }

    expect(runner.progressFor(1)!.steps, 5);
    expect(runner.progressFor(1)!.phase, DemoPhase.stepping);
    expect(runner.isRunning, isTrue);

    runner.dispose();
    tracker.dispose();
  });

  test('a missing ACK sends RTH to that drone only', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender, drones: [1, 2]);

    await runner.start([1, 2], 3.0);

    // Drone 1 stays responsive throughout; drone 2 never answers at all.
    final keepAlive = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (runner.progressFor(1)?.isActive ?? false) ackLast(tracker, sender, 1);
    });
    await settle();
    keepAlive.cancel();

    expect(sender.lastTo(2), isA<RthMessage>(),
        reason: 'the silent drone must be sent home');
    expect(runner.progressFor(2)!.phase, DemoPhase.returning);

    expect(runner.progressFor(1)!.phase, DemoPhase.stepping,
        reason: 'the responsive drone must keep going');
    expect(sender.to(1).whereType<RthMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('a NACK sends RTH, same as silence', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);

    await runner.start([1], 3.0);
    tracker.handleIncoming(
      1,
      NackMessage(
        seq: 1,
        respondingTo: sender.lastTo(1).seq,
        error: NackError.noGps,
      ),
    );
    await Future<void>.microtask(() {});

    expect(sender.lastTo(1), isA<RthMessage>());
    expect(runner.progressFor(1)!.phase, DemoPhase.returning);
    expect(runner.progressFor(1)!.detail, contains('NO_GPS'));

    runner.dispose();
    tracker.dispose();
  });

  test('a returning drone is not advanced further', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);

    await runner.start([1], 3.0);
    await settle();
    expect(runner.progressFor(1)!.phase, DemoPhase.returning);

    final countAfterRth = sender.to(1).length;
    await settle();

    expect(sender.to(1).whereType<NextStepMessage>(), isEmpty);
    expect(sender.to(1).length, lessThanOrEqualTo(countAfterRth + 3),
        reason: 'only RTH retries, no new steps');

    runner.dispose();
    tracker.dispose();
  });

  test('MISSION_DONE ends the sequence without an RTH', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);

    await runner.start([1], 3.0);
    ackLast(tracker, sender, 1);
    await Future<void>.microtask(() {});

    runner.handleEvent(1, MissionEvent.missionDone);
    expect(runner.progressFor(1)!.phase, DemoPhase.finished);
    expect(runner.isRunning, isFalse);

    final count = sender.to(1).length;
    ackLast(tracker, sender, 1);
    await Future<void>.microtask(() {});

    expect(sender.to(1).length, count, reason: 'a finished drone must not advance');
    expect(sender.to(1).whereType<RthMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('the step cap sends the drone home', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender, maxSteps: 3);

    await runner.start([1], 3.0);
    for (var i = 0; i < 5; i++) {
      ackLast(tracker, sender, 1);
      await Future<void>.microtask(() {});
      if (runner.progressFor(1)!.phase == DemoPhase.returning) break;
    }

    expect(runner.progressFor(1)!.phase, DemoPhase.returning);
    expect(runner.progressFor(1)!.detail, contains('cap'));
    expect(sender.lastTo(1), isA<RthMessage>());

    runner.dispose();
    tracker.dispose();
  });

  test('stop halts advancing without sending RTH', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);

    await runner.start([1], 3.0);
    ackLast(tracker, sender, 1);
    await Future<void>.microtask(() {});

    runner.stop();
    expect(runner.progressFor(1)!.phase, DemoPhase.stopped);
    expect(runner.isRunning, isFalse);

    final count = sender.to(1).length;
    ackLast(tracker, sender, 1);
    await Future<void>.microtask(() {});

    expect(sender.to(1).length, count);
    expect(sender.to(1).whereType<RthMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('a manual command ACK does not advance the sequence', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);

    await runner.start([1], 3.0);
    ackLast(tracker, sender, 1);
    await Future<void>.microtask(() {});
    final count = sender.to(1).length;

    // Operator drives a manual MOVE alongside the running sequence.
    await tracker.send(
      (q) => MoveMessage(seq: q, direction: MoveDirection.left, distance: 2.0),
      dest: 1,
    );
    ackLast(tracker, sender, 1);
    await Future<void>.microtask(() {});

    expect(sender.to(1).length, count + 1,
        reason: 'only the MOVE itself, no extra NEXT_STEP');

    runner.dispose();
    tracker.dispose();
  });

  test('each drone advances on its own ACKs', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender, drones: [1, 2]);

    await runner.start([1, 2], 3.0);

    for (var i = 0; i < 3; i++) {
      ackLast(tracker, sender, 1);
      await Future<void>.microtask(() {});
    }
    ackLast(tracker, sender, 2);
    await Future<void>.microtask(() {});

    expect(runner.progressFor(1)!.steps, 2);
    expect(runner.progressFor(2)!.steps, 0);

    runner.dispose();
    tracker.dispose();
  });
}
