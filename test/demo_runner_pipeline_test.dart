import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/pathfinding/local_frame.dart' show offsetLatLng;
import 'package:flutter_esp_android_communication/services/command_tracker.dart';
import 'package:flutter_esp_android_communication/services/demo_runner.dart';

/// Records what went on the wire instead of sending it.
class _Wire {
  final sent = <({int dest, MissionMessage msg})>[];

  Future<bool> call(int dest, MissionMessage msg) async {
    sent.add((dest: dest, msg: msg));
    return true;
  }

  List<MoveMessage> movesTo(int dest) => sent
      .where((e) => e.dest == dest && e.msg is MoveMessage)
      .map((e) => e.msg as MoveMessage)
      .toList();

  void clear() => sent.clear();
}

const _anchorA = LatLng(50.0, 19.0);
const _anchorB = LatLng(50.0005, 19.0);   // ~55 m apart, no separation grumbles
const _radius = 5.0;
const _vertices = 8;

LatLng _vertexOf(LatLng anchor, int index) =>
    offsetLatLng(anchor, (index % _vertices) * 360.0 / _vertices, _radius);

/// The opening report: its `to` IS the anchor.
ArrivedMessage _opening(LatLng anchor) =>
    ArrivedMessage(seq: 1, target: anchor, at: anchor);

/// A drone reporting it reached [step] of its figure.
ArrivedMessage _arrivedAt(LatLng anchor, int step) {
  final v = _vertexOf(anchor, step);
  return ArrivedMessage(seq: 100 + step, target: v, at: v);
}

Future<DemoRunner> _airborne(_Wire wire, {required int lookahead}) async {
  final tracker = CommandTracker(sender: wire.call, knownDrones: const [1, 2]);
  final demo = DemoRunner(
    tracker: tracker,
    vertexCount: _vertices,
    radiusMeters: _radius,
    lookahead: lookahead,
  );
  await demo.start([1, 2], 3.0);
  demo.handleArrived(1, _opening(_anchorA));
  demo.handleArrived(2, _opening(_anchorB));
  expect(demo.beginFormation(), isNull, reason: 'formation should release');
  // NOT cleared: releasing the formation is itself the first dispatch, and how
  // many vertices it puts out is exactly what the lookahead tests are about.
  return demo;
}

void main() {
  group('strict barrier (lookahead 0)', () {
    test('nobody is sent step k+1 until both have confirmed k', () async {
      final wire = _Wire();
      final demo = await _airborne(wire, lookahead: 0);

      // Release sends vertex 0 to both.
      expect(wire.movesTo(1).length, 1);
      expect(wire.movesTo(2).length, 1);
      wire.clear();

      // Drone 1 arrives. Nothing may move: drone 2 has not reported.
      demo.handleArrived(1, _arrivedAt(_anchorA, 0));
      expect(wire.sent, isEmpty,
          reason: 'the barrier must hold until every drone confirms');

      // Drone 2 arrives. Now both step, together, to vertex 1.
      demo.handleArrived(2, _arrivedAt(_anchorB, 0));
      expect(wire.movesTo(1).length, 1);
      expect(wire.movesTo(2).length, 1);
      expect(wire.movesTo(1).single.target, _vertexOf(_anchorA, 1));
      expect(wire.movesTo(2).single.target, _vertexOf(_anchorB, 1));
    });
  });

  group('pipelined (lookahead 1)', () {
    test('release puts two vertices in flight, so the queue is never empty',
        () async {
      final wire = _Wire();
      await _airborne(wire, lookahead: 1);

      // minConfirmed is -1 after the opening hold... the ceiling is
      // -1 + 1 + 1 = 1, so vertices 0 AND 1 go out before anyone has moved.
      expect(wire.movesTo(1).map((m) => m.target),
          [_vertexOf(_anchorA, 0), _vertexOf(_anchorA, 1)]);
      expect(wire.movesTo(2).map((m) => m.target),
          [_vertexOf(_anchorB, 0), _vertexOf(_anchorB, 1)]);
    });

    test('an ARRIVED for a vertex already stepped past is still credited',
        () async {
      final wire = _Wire();
      final demo = await _airborne(wire, lookahead: 1);
      wire.clear();

      // Both drones are flying to vertex 1 with vertex 0 unconfirmed. The
      // report for vertex 0 lands now -- behind the newest dispatch. Under the
      // old equality check this was "arrived somewhere it was not sent".
      demo.handleArrived(1, _arrivedAt(_anchorA, 0));
      expect(demo.inFlightFor(1), 1, reason: 'vertex 0 credited, 1 still out');
      expect(demo.progressFor(1)!.phase, DemoPhase.stepping,
          reason: 'it never stopped, so it must not be shown as holding');
      expect(wire.sent, isEmpty, reason: 'drone 2 has confirmed nothing yet');

      // Drone 2 catches up: minConfirmed becomes 0, ceiling 2, so both are
      // topped up to vertex 2 and neither ever ran dry.
      demo.handleArrived(2, _arrivedAt(_anchorB, 0));
      expect(wire.movesTo(1).single.target, _vertexOf(_anchorA, 2));
      expect(wire.movesTo(2).single.target, _vertexOf(_anchorB, 2));
    });

    test('the formation stalls within lookahead of a silent drone', () async {
      final wire = _Wire();
      final demo = await _airborne(wire, lookahead: 1);
      wire.clear();

      // Drone 2 goes quiet. Drone 1 keeps reporting.
      for (var step = 0; step < 6; step++) {
        demo.handleArrived(1, _arrivedAt(_anchorA, step));
      }

      // It is pinned to the slowest CONFIRMED arrival, which is still -1, so
      // drone 1 never gets past the two vertices it already had.
      expect(wire.movesTo(1), isEmpty,
          reason: 'a silent drone must still halt the figure');
      expect(demo.progressFor(1)!.steps, 1);
    });

    test('operator marking the silent drone arrived releases the figure',
        () async {
      final wire = _Wire();
      final demo = await _airborne(wire, lookahead: 1);
      demo.handleArrived(1, _arrivedAt(_anchorA, 0));
      wire.clear();

      expect(demo.markArrived(2), isNull);
      expect(wire.movesTo(1).single.target, _vertexOf(_anchorA, 2));
    });
  });

  group('mark arrived with no report at all', () {
    test('anchors the figure from telemetry when ARRIVED never came', () async {
      final wire = _Wire();
      final tracker = CommandTracker(sender: wire.call, knownDrones: const [1, 2]);
      final demo = DemoRunner(
          tracker: tracker,
          vertexCount: _vertices,
          radiusMeters: _radius,
          lookahead: 0);
      await demo.start([1, 2], 3.0);

      // Drone 1 reports normally. Drone 2's opening ARRIVED is lost, but its
      // telemetry is coming through -- it is up and holding over its anchor.
      demo.handleArrived(1, _opening(_anchorA));
      demo.handleTelemetry(
          2, TelemMessage(seq: 5, position: _anchorB, altitude: 3.0,
              state: DroneState.hover));

      expect(demo.progressFor(2)!.figure, isEmpty,
          reason: 'no ARRIVED, so nothing has anchored it yet');
      expect(demo.mustered, isNot(contains(2)));

      expect(demo.markArrived(2), isNull,
          reason: 'the operator can see it holding; telemetry gives the anchor');
      expect(demo.mustered, containsAll([1, 2]));
      expect(demo.progressFor(2)!.figure.first, _vertexOf(_anchorB, 0));

      // And it now flies the figure like any other drone.
      wire.clear();
      expect(demo.beginFormation(), isNull);
      expect(wire.movesTo(2).single.target, _vertexOf(_anchorB, 0));
    });

    test('refuses only when nothing has ever been heard from the drone',
        () async {
      final wire = _Wire();
      final tracker = CommandTracker(sender: wire.call, knownDrones: const [1, 2]);
      final demo = DemoRunner(
          tracker: tracker, vertexCount: _vertices, radiusMeters: _radius);
      await demo.start([1, 2], 3.0);

      expect(demo.markArrived(2), isNotNull,
          reason: 'no ARRIVED and no TELEM means there is no position at all');
    });
  });

  group('safeguards are gone', () {
    test('an arrival well off the vertex is credited, not landed', () async {
      final wire = _Wire();
      final demo = await _airborne(wire, lookahead: 0);
      wire.clear();

      // Reports the right target, but stopped 7 m away -- the case that used to
      // land a joiner mid-catch-up.
      final v = _vertexOf(_anchorA, 0);
      demo.handleArrived(
          1,
          ArrivedMessage(
              seq: 7, target: v, at: offsetLatLng(v, 90, 7.0)));

      expect(wire.sent.where((e) => e.msg is LandMessage), isEmpty,
          reason: 'nothing may land a drone for stopping wide');
      expect(demo.progressFor(1)!.phase, DemoPhase.holding,
          reason: 'the arrival is credited anyway');
    });

    test('an unknown airborne drone is not flown home', () async {
      final wire = _Wire();
      final demo = await _airborne(wire, lookahead: 0);
      wire.clear();

      demo.handleArrived(3, _opening(const LatLng(50.001, 19.001)));

      expect(wire.sent, isEmpty,
          reason: 'a drone we cannot account for is the pilot\'s');
      expect(demo.strays, contains(3));
    });
  });
}
