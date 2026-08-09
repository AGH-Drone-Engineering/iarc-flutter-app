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
final _anchors = {1: _anchorA, 2: _anchorB};

({CommandTracker tracker, DemoRunner runner}) build(
  FakeSender sender, {
  List<int> drones = const [1, 2],
  int maxSteps = 200,
  Duration barrierTimeout = const Duration(seconds: 30),
  Duration telemetryTimeout = const Duration(seconds: 30),
  Duration watchdogPeriod = const Duration(milliseconds: 15),
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
      barrierTimeout: barrierTimeout,
      telemetryTimeout: telemetryTimeout,
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

/// Fly a leg in telemetry: in transit, then stopped on the vertex.
void flyTo(DemoRunner runner, int drone, LatLng vertex) {
  telem(runner, drone, DroneState.demo, vertex);
  telem(runner, drone, DroneState.hover, vertex);
}

/// Take off and reach the opening barrier.
void becomeAirborne(DemoRunner runner, int drone) {
  telem(runner, drone, DroneState.takeoff, _anchors[drone]!);
  telem(runner, drone, DroneState.hover, _anchors[drone]!);
}

Future<void> pump() => Future<void>.delayed(Duration.zero);
Future<void> settle([int ms = 400]) => Future<void>.delayed(Duration(milliseconds: ms));

/// Both drones started, anchored and airborne, formation on vertex 0.
Future<({CommandTracker tracker, DemoRunner runner})> launched(
  FakeSender sender, {
  Duration barrierTimeout = const Duration(seconds: 30),
  Duration telemetryTimeout = const Duration(seconds: 30),
}) async {
  final built = build(sender,
      barrierTimeout: barrierTimeout, telemetryTimeout: telemetryTimeout);
  await built.runner.start([1, 2], 3.0);
  ackLast(built.tracker, sender, 1);
  ackLast(built.tracker, sender, 2);
  becomeAirborne(built.runner, 1);
  becomeAirborne(built.runner, 2);
  await pump();
  return built;
}

void main() {
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
    // and holds 4 m short of the vertex.
    flyTo(runner, 1, figureA[0]);
    telem(runner, 2, DroneState.demo, _anchorB);
    telem(runner, 2, DroneState.hover, offsetLatLng(figureB[0], 180, 4.0));
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

  test('a drone that goes silent is landed', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender,
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

  test('a position that was already stale on arrival is not trusted', () async {
    final sender = FakeSender();
    final (:tracker, :runner) = await launched(sender,
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
