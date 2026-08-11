import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/pathfinding/local_frame.dart';
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

  List<MoveMessage> movesTo(int dest) => to(dest).whereType<MoveMessage>().toList();
}

const _timeout = Duration(milliseconds: 60);

/// Two anchors 8 m apart -- close enough that the circles intersect (2R = 10 m),
/// which is the whole point: only phase keeps these two drones apart.
const _anchorA = LatLng(50.062975, 19.9157);
final _anchorB = offsetLatLng(_anchorA, 90, 8.0);
final _anchorC = offsetLatLng(_anchorA, 180, 8.0);
final _anchors = {1: _anchorA, 2: _anchorB, 3: _anchorC, 4: _anchorC};

({CommandTracker tracker, DemoRunner runner}) build(
  FakeSender sender, {
  List<int> drones = const [1, 2],
  int maxSteps = 200,
  Duration barrierTimeout = const Duration(seconds: 30),
  Duration? telemetryTimeout = const Duration(seconds: 30),
  Duration? groundTelemetryTimeout = const Duration(seconds: 30),
  Duration legTimeout = const Duration(seconds: 30),
  Duration watchdogPeriod = const Duration(milliseconds: 15),
  bool lockstep = true,
  double clearanceMeters = 4.0,
  Duration settleDelay = Duration.zero,
}) {
  final tracker = CommandTracker(
    sender: sender.call,
    knownDrones: drones,
    ackTimeout: _timeout,
    maxAttempts: 3,
  );
  return (
    tracker: tracker,
    runner: DemoRunner(
      tracker: tracker,
      maxSteps: maxSteps,
      lockstep: lockstep,
      clearanceMeters: clearanceMeters,
      settleDelay: settleDelay,
      barrierTimeout: barrierTimeout,
      telemetryTimeout: telemetryTimeout,
      groundTelemetryTimeout: groundTelemetryTimeout,
      legTimeout: legTimeout,
      watchdogPeriod: watchdogPeriod,
    ),
  );
}

void ackLast(CommandTracker tracker, FakeSender sender, int drone,
    {LatLng? position}) {
  tracker.handleIncoming(
    drone,
    AckMessage(
      seq: 9000,
      respondingTo: sender.lastTo(drone).seq,
      position: position ?? _anchors[drone],
    ),
  );
}

var _sample = 1000;

void telem(DemoRunner runner, int drone, DroneState state, LatLng position,
    {int? sampleMs}) {
  _sample += 1000;
  runner.handleTelemetry(
    drone,
    TelemMessage(
      seq: 9100,
      position: position,
      altitude: 3.0,
      state: state,
      sampleMs: sampleMs ?? _sample,
    ),
  );
}

/// The drone's arrival report -- the only thing that moves the formation.
///
/// [target] is the `MOVE`'s `to` echoed back, [at] where it actually stopped.
/// They differ when the point of the test is a drone that ended up somewhere
/// other than where it was sent.
void arrive(DemoRunner runner, int drone, LatLng target,
    {LatLng? at, double speed = 0.0}) {
  runner.handleArrived(
    drone,
    ArrivedMessage(seq: 9300, target: target, at: at ?? target, speed: speed),
  );
}

/// Fly a leg: in transit, stopped on the vertex, then the report that says so.
void flyTo(DemoRunner runner, int drone, LatLng vertex) {
  telem(runner, drone, DroneState.demo, vertex);
  telem(runner, drone, DroneState.hover, vertex);
  arrive(runner, drone, vertex);
}

/// Point [n] metres north and [e] metres east of [from].
LatLng ne(LatLng from, double n, double e) =>
    offsetLatLng(offsetLatLng(from, 0, n), 90, e);

/// Take off and reach the opening barrier -- which is an ARRIVED at the anchor,
/// like every later step, rather than a telemetry state change.
void becomeAirborne(DemoRunner runner, int drone) {
  telem(runner, drone, DroneState.takeoff, _anchors[drone]!);
  telem(runner, drone, DroneState.hover, _anchors[drone]!);
  arrive(runner, drone, _anchors[drone]!);
}

Future<void> pump() => Future<void>.delayed(Duration.zero);
Future<void> settle([int ms = 400]) => Future<void>.delayed(Duration(milliseconds: ms));

/// Both drones started, anchored and airborne, formation on vertex 0.
Future<({CommandTracker tracker, DemoRunner runner})> launched(
  FakeSender sender, {
  Duration barrierTimeout = const Duration(seconds: 30),
  Duration telemetryTimeout = const Duration(seconds: 30),
  bool lockstep = true,
  double clearanceMeters = 4.0,
  Duration settleDelay = Duration.zero,
}) async {
  final built = build(sender,
      barrierTimeout: barrierTimeout,
      telemetryTimeout: telemetryTimeout,
      lockstep: lockstep,
      clearanceMeters: clearanceMeters,
      settleDelay: settleDelay);
  await built.runner.start([1, 2], 3.0);
  ackLast(built.tracker, sender, 1);
  ackLast(built.tracker, sender, 2);
  becomeAirborne(built.runner, 1);
  becomeAirborne(built.runner, 2);
  await pump();
  // Both are up and holding over their anchors. Everything below this point is
  // about flying the figure, so release it.
  final refusal = built.runner.beginFormation();
  expect(refusal, isNull, reason: 'the muster should be releasable');
  await pump();
  return built;
}

void main() {
  // ---- regressions from raspi.log 2026-08-10 03:12 ------------------------
  // One drone, lockstep on, no MOVE ever sent: the app landed it 4.5 s into the
  // demo, before it had even finished climbing.

  test('a drone still reporting IDLE just after START_DEMO is not landed',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender, drones: [1]);

    await runner.start([1], 3.0);
    ackLast(tracker, sender, 1);
    await pump();

    // The drone has not armed yet, so IDLE is the correct thing for it to say
    // -- and on a polled radio that frame can arrive seconds after we sent the
    // command. ARMING follows, still not airborne.
    telem(runner, 1, DroneState.idle, _anchorA);
    telem(runner, 1, DroneState.arming, _anchorA);
    await pump();

    expect(runner.progressFor(1)!.phase, DemoPhase.starting);
    expect(sender.to(1).whereType<LandMessage>(), isEmpty,
        reason: 'landing a drone for being on the ground before takeoff aborts '
            'every demo before it begins');

    // ... and it still runs normally once it is up and released.
    becomeAirborne(runner, 1);
    await pump();
    expect(runner.beginFormation(), isNull);
    await pump();
    expect(runner.progressFor(1)!.steps, 0);
    expect(sender.movesTo(1), hasLength(1));

    runner.dispose();
    tracker.dispose();
  });

  // ---- regression from phone.log 2026-08-10 18:48 --------------------------
  // Drone 1 climbed in silence (the mission thread cannot report from inside
  // arm()/take_off()), reported a good ARRIVED at 18:49:03.160, and was landed
  // 0.3 s later for "no position for 12.752s". The opening arrival had moved it
  // out of `starting`, so the pre-takeoff gap was judged against the airborne
  // limit -- a drone destroyed by silence that happened before it was flying.
  test('an arrival after a silent climb is not punished for the silence',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender,
        drones: [1],
        lockstep: false,           // telemetry load-bearing: the harsher case
        clearanceMeters: 1.0,
        telemetryTimeout: const Duration(milliseconds: 100),
        groundTelemetryTimeout: const Duration(seconds: 30));

    await runner.start([1], 3.0);
    ackLast(tracker, sender, 1);
    telem(runner, 1, DroneState.idle, _anchorA);
    await pump();

    // Arming and climbing, reporting nothing -- far longer than the airborne
    // limit, well inside the ground one.
    await settle(400);
    expect(runner.progressFor(1)!.phase, DemoPhase.starting);

    // Up, and says so.
    arrive(runner, 1, _anchorA);
    await pump();
    expect(runner.progressFor(1)!.phase, DemoPhase.holding,
        reason: 'up and holding over its anchor, waiting to be released');
    expect(runner.beginFormation(), isNull);
    await pump();
    expect(runner.progressFor(1)!.phase, DemoPhase.stepping);

    await settle(60);
    expect(runner.progressFor(1)!.phase, isNot(DemoPhase.landing),
        reason: 'silence from before takeoff must not be charged to the drone '
            'the instant its arrival moves it into the airborne limit');
    expect(sender.to(1).whereType<LandMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('the ground telemetry cadence is not mistaken for silence', () async {
    final sender = FakeSender();
    // PROTOCOL.md §6: 5 s between frames on the ground against 1 s airborne.
    // The airborne limit must not be applied to a drone that has not taken off.
    final (:tracker, :runner) = build(sender,
        drones: [1],
        telemetryTimeout: const Duration(milliseconds: 60),
        groundTelemetryTimeout: const Duration(milliseconds: 500));

    await runner.start([1], 3.0);
    ackLast(tracker, sender, 1);
    telem(runner, 1, DroneState.idle, _anchorA);
    await settle(200);        // longer than the airborne limit, well inside ground

    expect(runner.progressFor(1)!.phase, DemoPhase.starting);
    expect(sender.to(1).whereType<LandMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('drones that never answer do not take down the one that flies',
      () async {
    final sender = FakeSender();
    // A broadcast START_DEMO addresses all four even when three are switched
    // off. Their unanswerable LANDs used to escalate into landing the formation.
    final (:tracker, :runner) = build(sender, drones: [1, 2, 3, 4]);

    await runner.start([1, 2, 3, 4], 3.0);
    ackLast(tracker, sender, 1);
    becomeAirborne(runner, 1);
    await pump();
    expect(runner.progressFor(1)!.phase, DemoPhase.holding,
        reason: 'waiting at the barrier for three drones that do not exist');

    // Keep the real drone answering while the silent ones exhaust their
    // retries -- otherwise its own MOVE times out and the test lands it itself.
    final keepAlive = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (tracker.isAwaitingAck(1)) ackLast(tracker, sender, 1);
    });
    await settle(400);

    // It has been holding over its anchor the whole time, which is the point of
    // a muster: one drone that came up does not start the show on its own.
    expect(sender.movesTo(1), isEmpty);
    expect(runner.progressFor(1)!.phase, DemoPhase.holding);

    // The operator sees three drones that never made it and goes anyway.
    expect(runner.beginFormation(), isNull);
    await settle(200);
    keepAlive.cancel();

    for (final id in [2, 3, 4]) {
      expect(runner.progressFor(id)!.phase, DemoPhase.stopped,
          reason: 'drone $id never flew, so there is nothing to land');
      expect(sender.to(id).whereType<LandMessage>(), isEmpty);
    }

    expect(sender.to(1).whereType<LandMessage>(), isEmpty,
        reason: 'the drone that is actually flying must be left alone');
    expect(runner.progressFor(1)!.steps, greaterThanOrEqualTo(0));
    expect(sender.movesTo(1), isNotEmpty, reason: 'and it should be stepping');

    runner.dispose();
    tracker.dispose();
  });

  test('nobody steps until the whole formation is at the barrier', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);

    await runner.start([1, 2], 3.0);
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);
    await pump();

    // Drone 1 is up first. It must NOT start the figure on its own -- that is
    // exactly the phase slip the formation cannot survive.
    becomeAirborne(runner, 1);
    await pump();
    expect(sender.movesTo(1), isEmpty,
        reason: 'drone 2 is still on the ground');
    expect(runner.progressFor(1)!.phase, DemoPhase.holding);
    expect(runner.progressFor(2)!.phase, DemoPhase.starting);

    becomeAirborne(runner, 2);
    await pump();
    expect(sender.movesTo(1), isEmpty,
        reason: 'both are holding, but the operator has not released them');
    expect(runner.beginFormation(), isNull);
    await pump();

    expect(sender.movesTo(1), hasLength(1));
    expect(sender.movesTo(2), hasLength(1));
    expect(runner.progressFor(1)!.steps, 0);
    expect(runner.progressFor(2)!.steps, 0);

    runner.dispose();
    tracker.dispose();
  });

  test('the formation walks the figure one vertex at a time, together', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);

    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;
    expect(figureA, hasLength(8));

    for (var step = 0; step < 4; step++) {
      expect(runner.progressFor(1)!.steps, step);
      expect(runner.progressFor(2)!.steps, step);
      // Both were sent the SAME vertex index of their own figure.
      expect(sender.movesTo(1).last.target, figureA[step % 8]);
      expect(sender.movesTo(2).last.target, figureB[step % 8]);

      flyTo(runner, 1, figureA[step % 8]);
      await pump();
      expect(sender.movesTo(2), hasLength(step + 1),
          reason: 'drone 2 has not arrived; drone 1 must wait');

      flyTo(runner, 2, figureB[step % 8]);
      await pump();
      ackLast(tracker, sender, 1);
      ackLast(tracker, sender, 2);
    }

    expect(runner.progressFor(1)!.steps, 4);
    expect(sender.to(1).whereType<LandMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('a drone that stops off its vertex is landed, the rest keep going',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);
    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;

    // Drone 2 gives up mid-leg -- pilot takeover, or a goto that timed out --
    // and calls the right vertex arrived from 4 m short of it. The target it
    // echoes back is correct, so only checking `at` catches this.
    flyTo(runner, 1, figureA[0]);
    arrive(runner, 2, figureB[0], at: offsetLatLng(figureB[0], 180, 4.0));
    await pump();

    expect(runner.progressFor(2)!.phase, DemoPhase.landing);
    expect(sender.lastTo(2), isA<LandMessage>(),
        reason: 'straight down, never RTH across the other circles');
    expect(sender.to(2).whereType<RthMessage>(), isEmpty);

    // Drone 1 is alone now, still in phase with itself, and keeps stepping.
    expect(runner.progressFor(1)!.steps, 1);
    expect(sender.movesTo(1), hasLength(2));

    runner.dispose();
    tracker.dispose();
  });

  test('a straggler is landed once the barrier times out', () async {
    final sender = FakeSender();
    final (:tracker, :runner) =
        await launched(sender, barrierTimeout: const Duration(milliseconds: 80));
    final figureA = runner.progressFor(1)!.figure;

    flyTo(runner, 1, figureA[0]);          // drone 1 arrives, drone 2 never does
    await pump();
    expect(runner.progressFor(2)!.phase, DemoPhase.stepping);

    await settle(200);

    expect(runner.progressFor(2)!.phase, DemoPhase.landing);
    expect(runner.progressFor(2)!.detail, contains('did not reach the vertex'));
    expect(sender.lastTo(2), isA<LandMessage>());
    expect(runner.progressFor(1)!.steps, 1, reason: 'the rest are released');

    runner.dispose();
    tracker.dispose();
  });

  test('off-step: a drone that goes silent is landed', () async {
    final sender = FakeSender();
    // Off-step is where positions are load-bearing: ConflictMonitor predicts
    // from them, so once they stop there is nothing keeping the drones apart.
    final (:tracker, :runner) = await launched(sender,
        lockstep: false,
        clearanceMeters: 1.0,
        telemetryTimeout: const Duration(milliseconds: 80));
    final figureA = runner.progressFor(1)!.figure;

    // Drone 1 keeps reporting; drone 2 says nothing at all.
    for (var i = 0; i < 4; i++) {
      telem(runner, 1, DroneState.demo, figureA[0]);
      await settle(30);
    }

    expect(runner.progressFor(2)!.phase, DemoPhase.landing);
    expect(runner.progressFor(2)!.detail, contains('no position'));

    runner.dispose();
    tracker.dispose();
  });

  test('lockstep: a drone that goes silent is NOT landed', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender,
        telemetryTimeout: const Duration(milliseconds: 80));
    final figureA = runner.progressFor(1)!.figure;

    for (var i = 0; i < 4; i++) {
      telem(runner, 1, DroneState.demo, figureA[0]);
      await settle(30);
    }

    // In lockstep the guarantee is geometric and the vertex index comes from
    // ARRIVED, so telemetry draws the map and nothing else. Landing a drone
    // because the map went quiet destroys a flight to protect nothing -- and at
    // 0.2 Hz every healthy drone is 'silent' against a 4 s limit.
    expect(runner.progressFor(2)!.phase, isNot(DemoPhase.landing),
        reason: 'silence is not evidence of anything the formation relies on');
    expect(sender.to(2).whereType<LandMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('off-step: a position that was already stale on arrival is not trusted',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender,
        lockstep: false,
        clearanceMeters: 1.0,
        telemetryTimeout: const Duration(milliseconds: 400));
    final figureA = runner.progressFor(1)!.figure;
    ackLast(tracker, sender, 1);        // keep the ACK watchdog out of this test
    ackLast(tracker, sender, 2);

    // Telemetry keeps flowing, so nothing looks silent. Establish the offset.
    var stamp = 500000;
    for (var i = 0; i < 4; i++) {
      telem(runner, 1, DroneState.demo, figureA[0], sampleMs: stamp += 50);
      await settle(50);
    }
    expect(runner.progressFor(1)!.phase, DemoPhase.stepping);

    // Now one frame the radio had been sitting on: it arrives on time, but the
    // position in it is two seconds old. Arrival time would call this fresh.
    telem(runner, 1, DroneState.hover, figureA[0], sampleMs: stamp - 2000);
    await pump();

    expect(runner.progressFor(1)!.phase, DemoPhase.landing);
    expect(runner.progressFor(1)!.detail, contains('old on arrival'));

    runner.dispose();
    tracker.dispose();
  });

  test('WAYPOINT_REACHED on its own does not move the formation', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);

    runner.handleEvent(1, MissionEvent.waypointReached);
    runner.handleEvent(2, MissionEvent.waypointReached);
    await pump();

    expect(runner.progressFor(1)!.steps, 0);
    expect(sender.movesTo(1), hasLength(1),
        reason: 'an event carries no position, so it cannot prove phase');

    runner.dispose();
    tracker.dispose();
  });

  test('a drone that reports itself grounded mid-formation is landed', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);

    telem(runner, 2, DroneState.rth, _anchorB);
    await pump();

    expect(runner.progressFor(2)!.phase, DemoPhase.landing);
    expect(runner.progressFor(2)!.detail, contains('RTH'));

    runner.dispose();
    tracker.dispose();
  });

  test('a NACK lands that drone instead of sending it home', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);

    tracker.handleIncoming(
      2,
      NackMessage(
        seq: 1,
        respondingTo: sender.lastTo(2).seq,
        error: NackError.geofence,
      ),
    );
    await pump();

    expect(runner.progressFor(2)!.phase, DemoPhase.landing);
    expect(sender.lastTo(2), isA<LandMessage>());
    expect(sender.to(2).whereType<RthMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('a LAND we cannot deliver brings the whole formation down', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);

    telem(runner, 2, DroneState.error, _anchorB);   // -> land drone 2
    await pump();
    expect(runner.progressFor(2)!.phase, DemoPhase.landing);

    // Nobody ever ACKs that LAND: drone 2 is stuck at the formation altitude
    // and unreachable, so the guarantee for everyone else is gone too.
    await settle(400);

    expect(sender.to(1).whereType<LandMessage>(), isNotEmpty,
        reason: 'the reachable drones must come down too');
    expect(runner.progressFor(1)!.phase, DemoPhase.landing);
    expect(runner.isRunning, isFalse);

    runner.dispose();
    tracker.dispose();
  });

  // ---- regressions from phone.log 2026-08-10 14:02 ------------------------
  // MOVE q=14 (vertex 1) was ACKed but the ACK frame was lost, so its retry
  // timer stayed armed. It fired at 14:03:02, four steps later, re-sending the
  // vertex-1 coordinate; the drone was past the retransmission window, took it
  // as a new order, and flew 3.7 m back across the figure from vertex 4.
  test('a step the formation has walked past is never retried', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);
    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;

    // Vertex 0 goes out and drone 1's ACK never comes back -- only drone 2's.
    final staleTarget = sender.movesTo(1).single.target;
    expect(staleTarget, figureA[0]);

    for (var step = 0; step < 3; step++) {
      flyTo(runner, 1, figureA[step % 8]);
      flyTo(runner, 2, figureB[step % 8]);
      await pump();
      ackLast(tracker, sender, 2);
    }
    expect(runner.progressFor(1)!.steps, 3);

    // Only the live step is answered: every earlier one is still unacknowledged,
    // which is the situation that armed the stale retry in the first place.
    ackLast(tracker, sender, 1);

    // Long enough for every retry the vertex-0 group would ever have fired.
    await settle(400);

    expect(sender.movesTo(1).where((m) => m.target == staleTarget), hasLength(1),
        reason: 'vertex 0 must not go back on the wire once vertex 3 is live');
    expect(sender.movesTo(1).last.target, figureA[3],
        reason: 'the live step is the last thing the drone was told');
    expect(sender.to(1).whereType<LandMessage>(), isEmpty,
        reason: 'a withdrawn command is not a failure');
    expect(runner.progressFor(1)!.phase, isNot(DemoPhase.landing));

    runner.dispose();
    tracker.dispose();
  });

  // ---- regression from phone.log 2026-08-10 13:57:40 -----------------------
  // The drone landed itself on its 30 s idle timeout, so it refused our LAND
  // with BAD_STATE -- and that NACK escalated into landing the whole formation.
  test('a LAND refused because the drone is already landing spares the rest',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);
    // Drone 1 is mid-leg with its MOVE answered, so nothing of its own can land
    // it -- if it comes down, the escalation is the only thing that did it.
    ackLast(tracker, sender, 1);

    telem(runner, 2, DroneState.landing, _anchorB);
    await pump();
    expect(runner.progressFor(2)!.phase, DemoPhase.landing);

    final land = sender.to(2).whereType<LandMessage>().last;
    tracker.handleIncoming(
      2,
      NackMessage(seq: 9200, respondingTo: land.seq, error: NackError.badState),
    );
    await settle(400);

    expect(sender.to(1).whereType<LandMessage>(), isEmpty,
        reason: '"already landing" is the outcome we asked for, not a fault');
    expect(runner.progressFor(1)!.phase, isNot(DemoPhase.landing));
    expect(tracker.failureFor(2), isNull);

    runner.dispose();
    tracker.dispose();
  });

  // ---- ARRIVED is the gate, and it is checked ------------------------------

  test('an arrival at a vertex we are not waiting on lands the drone', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);
    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;

    // Both are walking to vertex 0. Drone 2 instead reports arriving at vertex 3
    // -- a report delayed on the link, or a drone acting on a stale order. It is
    // physically ON a vertex and standing still, so nothing about the position
    // alone is suspicious; only the echoed target gives it away.
    flyTo(runner, 1, figureA[0]);
    arrive(runner, 2, figureB[3]);
    await pump();

    expect(runner.progressFor(2)!.phase, DemoPhase.landing);
    expect(runner.progressFor(2)!.detail,
        contains('somewhere it was not sent'));
    expect(sender.lastTo(2), isA<LandMessage>());

    // Vertex 3 is neither the live step nor the one just credited, so the
    // repeat-tolerance above must not swallow it.
    expect(runner.progressFor(1)!.phase, isNot(DemoPhase.landing),
        reason: 'and the healthy drone is untouched');

    runner.dispose();
    tracker.dispose();
  });

  test('a repeated arrival does not step the formation twice', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);
    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;

    flyTo(runner, 1, figureA[0]);
    flyTo(runner, 2, figureB[0]);
    await pump();
    expect(runner.progressFor(1)!.steps, 1);

    // The drone never got our ACK and says it again. It is retried until
    // acknowledged, so this is ordinary traffic: it must neither step the
    // formation nor be mistaken for a drone that flew back to vertex 0.
    arrive(runner, 1, figureA[0]);
    await pump();

    expect(runner.progressFor(1)!.steps, 1, reason: 'still walking to vertex 1');
    expect(sender.movesTo(1), hasLength(2));
    expect(runner.progressFor(1)!.phase, DemoPhase.stepping,
        reason: 'a retransmission is not a reason to land a healthy drone');
    expect(sender.to(1).whereType<LandMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('with TELEM off the formation still walks, and silence is not a fault',
      () async {
    final sender = FakeSender();
    // telemetryTimeout: null is what an operator setting --telem-hz 0 means for
    // the ground station. Nothing will ever call handleTelemetry.
    final built = build(sender,
        telemetryTimeout: null,
        groundTelemetryTimeout: null,
        legTimeout: const Duration(seconds: 30));
    final (:tracker, :runner) = built;
    await runner.start([1, 2], 3.0);
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);

    // Opening barrier from ARRIVED at the anchor, no telemetry anywhere.
    arrive(runner, 1, _anchorA);
    arrive(runner, 2, _anchorB);
    await pump();
    expect(runner.beginFormation(), isNull);
    await pump();

    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;
    expect(runner.progressFor(1)!.steps, 0);

    for (var step = 0; step < 3; step++) {
      arrive(runner, 1, figureA[step % 8]);
      arrive(runner, 2, figureB[step % 8]);
      await pump();
      ackLast(tracker, sender, 1);
      ackLast(tracker, sender, 2);
    }

    expect(runner.progressFor(1)!.steps, 3);
    expect(sender.to(1).whereType<LandMessage>(), isEmpty,
        reason: 'no position for the whole flight must not land anyone');

    runner.dispose();
    tracker.dispose();
  });

  test('a leg that never reports an arrival is landed, telemetry or not',
      () async {
    final sender = FakeSender();
    final built = build(sender,
        drones: [1],
        telemetryTimeout: null,
        groundTelemetryTimeout: null,
        legTimeout: const Duration(milliseconds: 80));
    final (:tracker, :runner) = built;
    await runner.start([1], 3.0);
    ackLast(tracker, sender, 1);
    arrive(runner, 1, _anchorA);
    await pump();
    expect(runner.beginFormation(), isNull);
    await pump();
    expect(runner.progressFor(1)!.phase, DemoPhase.stepping);

    await settle(250);

    expect(runner.progressFor(1)!.phase, DemoPhase.landing);
    expect(runner.progressFor(1)!.detail, contains('no arrival reported within'));
    expect(sender.lastTo(1), isA<LandMessage>());

    runner.dispose();
    tracker.dispose();
  });

  // ---- the figure has to be measurable ------------------------------------

  // ---- mustering: getting a swarm airborne is not part of the choreography --

  test('a drone still climbing is not treated as a straggler during a muster',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender,
        barrierTimeout: const Duration(milliseconds: 80));
    await runner.start([1, 2], 3.0);
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);
    await pump();

    // Drone 1 is up and holding. Drone 2 is anchored but still climbing -- it
    // has answered, so nothing is wrong with it; it just is not up yet.
    becomeAirborne(runner, 1);
    await pump();
    expect(runner.progressFor(1)!.phase, DemoPhase.holding);
    expect(runner.progressFor(2)!.phase, DemoPhase.starting);

    // Several barrier timeouts' worth. The straggler rule lands every formation
    // member that is not holding, so if it ran here the first drone to reach its
    // anchor would start a countdown on every drone still in the air.
    await settle(400);

    expect(runner.progressFor(2)!.phase, DemoPhase.starting,
        reason: 'arming and climbing is not being late for a barrier');
    expect(sender.to(2).whereType<LandMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('a drone whose START_DEMO was never answered can be re-added',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);
    await runner.start([1, 2], 3.0);

    // Drone 1 comes up. Drone 2's START_DEMO goes unanswered and it is dropped.
    ackLast(tracker, sender, 1);
    becomeAirborne(runner, 1);
    final keepAlive = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (tracker.isAwaitingAck(1)) ackLast(tracker, sender, 1);
    });
    await settle(400);
    expect(runner.progressFor(2)!.isActive, isFalse);

    // Re-adding must not disturb drone 1 -- start() would have erased it, and an
    // erased drone is one flying with no watchdog and no way to be landed.
    expect(await runner.addDrones([2]), isNull);
    expect(runner.progressFor(1)!.phase, DemoPhase.holding,
        reason: 'the drone already up is untouched');
    expect(runner.progressFor(2)!.phase, DemoPhase.starting);
    expect(sender.to(2).whereType<StartDemoMessage>().length,
        greaterThanOrEqualTo(2), reason: 'it was asked again');

    ackLast(tracker, sender, 2);
    becomeAirborne(runner, 2);
    await pump();
    expect(runner.mustered, hasLength(2));
    keepAlive.cancel();

    runner.dispose();
    tracker.dispose();
  });

  test('a drone joins a moving figure a metre off it, without stopping it',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);
    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;

    // Formation at 3 m, so a joiner transits under it at 2 m.
    expect(runner.transitAltitude, 2.0);
    expect(await runner.addDrones([3]), isNull);
    expect(runner.altitudeOverrideFor(3), 2.0);
    expect(
        sender.to(3).whereType<StartDemoMessage>().single.altitude, 2.0,
        reason: 'it climbs straight to the offset height');

    // Drone 3 is still arming. The figure must NOT wait for it -- that is the
    // whole reason for the offset.
    final movesBefore = sender.movesTo(1).length;
    flyTo(runner, 1, figureA[0]);
    flyTo(runner, 2, figureB[0]);
    await pump();
    expect(sender.movesTo(1).length, movesBefore + 1,
        reason: 'the formation stepped while the joiner was still climbing');
    expect(runner.progressFor(3)!.phase, DemoPhase.starting);

    // Up. From the next barrier it walks the same vertex indices, one metre off.
    ackLast(tracker, sender, 3, position: _anchorC);
    arrive(runner, 3, _anchorC);
    await pump();
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);
    final figureC = runner.progressFor(3)!.figure;
    flyTo(runner, 1, figureA[1]);
    flyTo(runner, 2, figureB[1]);
    await pump();
    expect(sender.movesTo(3), isNotEmpty);
    expect(sender.movesTo(3).last.altitude, 2.0,
        reason: 'every step it takes stays off the formation altitude');

    // Merging is just dropping the field: no barrier, no pause.
    expect(runner.mergeIntoFormation(3), isNull);
    expect(runner.altitudeOverrideFor(3), isNull);
    flyTo(runner, 3, figureC[runner.progressFor(3)!.steps % 8]);
    flyTo(runner, 1, figureA[2]);
    flyTo(runner, 2, figureB[2]);
    await pump();
    expect(sender.movesTo(3).last.altitude, isNull,
        reason: 'back on the formation altitude from its next ordinary step');

    runner.dispose();
    tracker.dispose();
  });

  test('transit altitude goes under the formation, or over it when too low',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender, drones: [1]);

    for (final (formation, expected, why) in [
      (1.5, 2.5, 'over: 0.5 m would be too low to transit'),
      (1.8, 2.8, 'over: still no metre of room underneath'),
      (2.0, 1.0, 'under: exactly a metre of room'),
      (3.0, 2.0, 'under'),
    ]) {
      await runner.start([1], formation);
      expect(runner.transitAltitude, closeTo(expected, 1e-9), reason: why);
    }

    runner.dispose();
    tracker.dispose();
  });

  test('a stray near a moving figure is sent home clear of it', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender);

    // An aircraft the app has no phase relationship with, announcing itself
    // airborne. Letting it hover until its own idle timeout leaves something
    // unmanaged at the formation's altitude for half a minute.
    arrive(runner, 4, _anchorC);
    await pump();

    final rth = sender.to(4).whereType<RthMessage>();
    expect(rth, hasLength(1));
    expect(rth.single.altitude, 2.0,
        reason: 'clear of the 3 m the formation is using');
    expect(runner.progressFor(4), isNull, reason: 'it is not in the formation');

    // ARRIVED is retried until acknowledged, so repeats must not fire again.
    arrive(runner, 4, _anchorC);
    arrive(runner, 4, _anchorC);
    await pump();
    expect(sender.to(4).whereType<RthMessage>(), hasLength(1));

    runner.dispose();
    tracker.dispose();
  });

  test('a drone the app gave up on is adopted from its own arrival report',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);
    await runner.start([1, 2], 3.0);
    ackLast(tracker, sender, 1);
    becomeAirborne(runner, 1);

    final keepAlive = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (tracker.isAwaitingAck(1)) ackLast(tracker, sender, 1);
    });
    await settle(400);
    expect(runner.progressFor(2)!.isActive, isFalse,
        reason: 'its START_DEMO ACK never arrived');

    // ... but the drone did get the command, climbed, and says so. The opening
    // report's `to` IS its anchor, so nothing is lost with the missing ACK.
    // phone.log 2026-08-10 18:50 and 18:48 are both exactly this.
    arrive(runner, 2, _anchorB);
    await pump();
    keepAlive.cancel();

    expect(runner.progressFor(2)!.isActive, isTrue, reason: 'adopted');
    expect(runner.progressFor(2)!.figure, hasLength(8));
    expect(runner.mustered, containsAll([1, 2]));

    runner.dispose();
    tracker.dispose();
  });

  test('mustering drones are kept alive so they do not time out', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender, drones: [1]);
    await runner.start([1], 3.0);
    ackLast(tracker, sender, 1);
    becomeAirborne(runner, 1);
    await pump();

    // The drone lands itself after 30 s without contact. A muster can easily
    // last longer than that, so something has to keep talking to it.
    await settle(300);
    expect(sender.to(1).whereType<StatusMessage>(), isNotEmpty,
        reason: 'a hovering drone with nothing to do must still hear from us');

    runner.dispose();
    tracker.dispose();
  });

  // ---- the geometry that actually keeps drones apart ----------------------

  test('a formation whose anchors are too close together is not released',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);
    await runner.start([1, 2], 3.0);

    // Took off 3 m apart. With 2 m of position tolerance each they could close
    // to -1 m, so there is no figure and no vertex count that makes this safe --
    // and equally, none that makes it unsafe once they are far enough apart.
    const tight = LatLng(50.062975, 19.9157);
    ackLast(tracker, sender, 1, position: tight);
    ackLast(tracker, sender, 2, position: offsetLatLng(tight, 90, 3.0));
    await pump();
    arrive(runner, 1, tight);
    arrive(runner, 2, offsetLatLng(tight, 90, 3.0));
    await pump();

    expect(runner.mustered, hasLength(2), reason: 'both are up and holding');
    expect(runner.separationFault, contains('could close to'));

    final refusal = runner.beginFormation();
    expect(refusal, isNotNull);
    expect(runner.isFlying, isFalse);
    expect(sender.movesTo(1), isEmpty, reason: 'nobody was sent anywhere');

    runner.dispose();
    tracker.dispose();
  });

  test('a tight figure is fine as long as the anchors are far enough apart',
      () async {
    final sender = FakeSender();
    final (:tracker, :runner) = build(sender);
    // The figure the old guard would have refused: 8 vertices at 2 m, a 1.53 m
    // edge. Irrelevant in lockstep -- translated copies cancel out.
    runner.radiusMeters = 2.0;
    runner.vertexCount = 8;
    await runner.start([1, 2], 3.0);
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);
    await pump();
    becomeAirborne(runner, 1);
    becomeAirborne(runner, 2);
    await pump();

    expect(runner.separationFault, isNull,
        reason: 'anchors are 8 m apart; the figure size cancels out');
    expect(runner.beginFormation(), isNull);
    await pump();
    expect(sender.movesTo(1), hasLength(1));

    runner.dispose();
    tracker.dispose();
  });

  test('off-step: a drone advances without waiting for the others', () async {
    final sender = FakeSender();
    // Anchors are 8 m apart and the figures are radius 5, so a drone on its own
    // vertex is well clear of the other's -- there is nothing to hold it back.
    final (:tracker, :runner) =
        await launched(sender, lockstep: false, clearanceMeters: 1.0);
    final figureA = runner.progressFor(1)!.figure;

    flyTo(runner, 1, figureA[0]);
    await pump();

    expect(runner.progressFor(1)!.steps, 1,
        reason: 'off-step, drone 1 does not wait for drone 2');
    expect(sender.movesTo(1), hasLength(2));
    expect(sender.movesTo(2), hasLength(1), reason: 'drone 2 has not arrived');
    expect(runner.progressFor(2)!.phase, DemoPhase.stepping);

    runner.dispose();
    tracker.dispose();
  });

  test('off-step: a step that would break clearance is held, not sent', () async {
    final sender = FakeSender();
    // The anchors are 8 m apart, so drone 1's vertex 1 sits ~4.7 m from drone
    // 2's vertex 0 -- the two figures really do overlap. With 5 m of clearance
    // that step is not allowed while drone 2 is sitting there.
    final (:tracker, :runner) =
        await launched(sender, lockstep: false, clearanceMeters: 5.0);
    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);

    expect(const Distance(roundResult: false)(figureA[1], figureB[0]),
        lessThan(5.0),
        reason: 'the fixture must actually be a conflict');

    // Drone 2 is parked on its vertex 0 and stays there; drone 1 arrives and
    // wants vertex 1, which is right on top of it.
    telem(runner, 2, DroneState.demo, figureB[0]);
    flyTo(runner, 1, figureA[0]);
    await pump();

    expect(runner.progressFor(1)!.phase, DemoPhase.holding);
    expect(runner.progressFor(1)!.steps, 0, reason: 'the step was not taken');
    expect(sender.movesTo(1), hasLength(1));
    expect(runner.progressFor(1)!.detail, contains('would close on drone 2'));
    expect(sender.to(1).whereType<LandMessage>(), isEmpty,
        reason: 'holding on its own vertex is safe; landing would be an escalation');

    runner.dispose();
    tracker.dispose();
  });

  test('off-step: a drone held too long by traffic is landed', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender,
        lockstep: false,
        clearanceMeters: 5.0,
        barrierTimeout: const Duration(milliseconds: 100));
    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);

    flyTo(runner, 1, figureA[0]);
    await pump();
    expect(runner.progressFor(1)!.phase, DemoPhase.holding);

    // Drone 2 never leaves the vertex that is in the way, so the block never
    // clears. Hovering for ever is not an answer either.
    for (var i = 0; i < 8; i++) {
      telem(runner, 2, DroneState.demo, figureB[0]);
      await settle(30);
    }

    expect(runner.progressFor(1)!.phase, DemoPhase.landing);
    expect(runner.progressFor(1)!.detail, contains('waiting for a clear step'));

    runner.dispose();
    tracker.dispose();
  });

  test('off-step: a converging pair is landed, both of them', () async {
    final sender = FakeSender();
    final (:tracker, :runner) =
        await launched(sender, lockstep: false, clearanceMeters: 4.0);

    // Both are still plausibly flying their own leg -- neither is far enough
    // off its vertex to trip the on-course check -- but they are closing on the
    // same piece of air. Nothing about which one is at fault is knowable from
    // two 1 Hz position streams.
    telem(runner, 1, DroneState.demo, ne(_anchorA, 5, 2));
    telem(runner, 2, DroneState.demo, ne(_anchorA, 5, 6));
    telem(runner, 1, DroneState.demo, ne(_anchorA, 5, 4));
    telem(runner, 2, DroneState.demo, ne(_anchorA, 5, 4));
    await settle(120);

    expect(runner.progressFor(1)!.phase, DemoPhase.landing);
    expect(runner.progressFor(2)!.phase, DemoPhase.landing);
    expect(runner.progressFor(1)!.detail, contains('clearance'));
    expect(sender.to(1).whereType<RthMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('lockstep: the next step waits out the settle delay', () async {
    final sender = FakeSender();
    final (:tracker, :runner) =
        await launched(sender, settleDelay: const Duration(milliseconds: 250));

    expect(runner.progressFor(1)!.steps, -1,
        reason: 'the opening step settles over the anchor like any other');
    await settle(120);
    expect(runner.progressFor(1)!.steps, -1, reason: 'still settling');

    await settle(200);
    expect(runner.progressFor(1)!.steps, 0);
    expect(runner.progressFor(2)!.steps, 0);
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);

    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;
    flyTo(runner, 1, figureA[0]);
    flyTo(runner, 2, figureB[0]);
    await settle(120);

    expect(runner.progressFor(1)!.phase, DemoPhase.holding,
        reason: 'both are on the vertex, but the formation has not settled');
    expect(runner.progressFor(1)!.steps, 0);

    await settle(200);
    expect(runner.progressFor(1)!.steps, 1);
    expect(runner.progressFor(2)!.steps, 1);

    runner.dispose();
    tracker.dispose();
  });

  test('off-step: a drone settles on its vertex before stepping on', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender,
        lockstep: false,
        clearanceMeters: 1.0,
        settleDelay: const Duration(milliseconds: 250));
    await settle(320);
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);
    final figureA = runner.progressFor(1)!.figure;

    flyTo(runner, 1, figureA[0]);
    await settle(120);
    expect(runner.progressFor(1)!.steps, 0, reason: 'settling, not stepping');
    expect(runner.progressFor(1)!.phase, DemoPhase.holding);

    await settle(200);
    expect(runner.progressFor(1)!.steps, 1);

    runner.dispose();
    tracker.dispose();
  });

  test('off-step: the settle does not count as being held by traffic', () async {
    final sender = FakeSender();
    // Nothing is in this drone's way: the only reason it is standing still is
    // the settle, which must not be charged against the hold timeout.
    final (:tracker, :runner) = await launched(sender,
        lockstep: false,
        clearanceMeters: 1.0,
        barrierTimeout: const Duration(milliseconds: 200),
        settleDelay: const Duration(milliseconds: 300));
    await settle(400);
    ackLast(tracker, sender, 1);
    ackLast(tracker, sender, 2);
    final figureA = runner.progressFor(1)!.figure;

    flyTo(runner, 1, figureA[0]);
    await settle(400);

    expect(runner.progressFor(1)!.phase, isNot(DemoPhase.landing));
    expect(runner.progressFor(1)!.steps, 1);

    runner.dispose();
    tracker.dispose();
  });

  test('lockstep ignores clearance entirely - geometry is the guarantee', () async {
    final sender = FakeSender();
    // Same absurd clearance as the held test, but in lockstep it must not
    // interfere: separation there is the anchor spacing, by construction.
    final (:tracker, :runner) =
        await launched(sender, lockstep: true, clearanceMeters: 40.0);
    final figureA = runner.progressFor(1)!.figure;
    final figureB = runner.progressFor(2)!.figure;

    flyTo(runner, 1, figureA[0]);
    flyTo(runner, 2, figureB[0]);
    await pump();

    expect(runner.progressFor(1)!.steps, 1);
    expect(runner.progressFor(2)!.steps, 1);
    expect(sender.to(1).whereType<LandMessage>(), isEmpty);

    runner.dispose();
    tracker.dispose();
  });

  test('the step cap lands the formation rather than flying it home', () async {
    final sender = FakeSender();
    final built = build(sender, maxSteps: 2);
    final runner = built.runner;
    await runner.start([1, 2], 3.0);
    ackLast(built.tracker, sender, 1);
    ackLast(built.tracker, sender, 2);
    becomeAirborne(runner, 1);
    becomeAirborne(runner, 2);
    await pump();
    expect(runner.beginFormation(), isNull);
    await pump();

    for (var step = 0; step < 3; step++) {
      final a = runner.progressFor(1)!.figure;
      final b = runner.progressFor(2)!.figure;
      if (runner.progressFor(1)!.phase != DemoPhase.stepping) break;
      flyTo(runner, 1, a[step % 8]);
      flyTo(runner, 2, b[step % 8]);
      await pump();
    }

    expect(runner.progressFor(1)!.phase, DemoPhase.landing);
    expect(runner.progressFor(1)!.detail, contains('cap'));
    expect(sender.to(1).whereType<RthMessage>(), isEmpty);

    runner.dispose();
    built.tracker.dispose();
  });
}
