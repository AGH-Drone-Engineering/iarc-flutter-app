import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_esp_android_communication/models/drone.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/state/app_state.dart';

import 'support/fake_transport.dart';

/// The ground station owes an ACK for every MINE and SCAN: the drone repeats
/// them until it gets one, because nothing else ever resends the minefield.
void main() {
  late AppState app;
  late FakeTransport link;

  setUp(() {
    Drone.ensureRegistered();
    app = AppState();
    link = FakeTransport();
    app.useTransportForTest(link);
  });

  tearDown(() => app.dispose());

  MineMessage mine(int seq, {int tag = 7, double lat = 50.062975}) =>
      MineMessage(seq: seq, tag: tag, position: LatLng(lat, 19.9157));

  ScanMessage scan(int seq) => ScanMessage(
        seq: seq,
        cornerA: const LatLng(50.062975, 19.9157),
        cornerB: const LatLng(50.063075, 19.9158),
      );

  List<AckMessage> acksTo(int drone) =>
      link.sent.where((s) => s.dest == drone).map((s) => s.message)
          .whereType<AckMessage>().toList();

  test('a MINE is acknowledged and recorded', () async {
    await link.deliver(4, mine(11));

    expect(app.mines, hasLength(1));
    expect(acksTo(4), hasLength(1));
    expect(acksTo(4).single.respondingTo, 11,
        reason: 'the ACK must name the report it answers');
  });

  test('a repeated MINE is acknowledged again but recorded once', () async {
    await link.deliver(4, mine(11));
    await link.deliver(4, mine(11));      // the drone never heard our first ACK
    await link.deliver(4, mine(11));

    expect(app.mines, hasLength(1), reason: 'one mine, not three');
    expect(acksTo(4), hasLength(3),
        reason: 'every repeat needs an answer, or the drone never stops');
    expect(acksTo(4).map((a) => a.respondingTo), everyElement(11));
  });

  test('a repeated SCAN is acknowledged again but recorded once', () async {
    await link.deliver(4, scan(21));
    await link.deliver(4, scan(21));

    expect(app.scans, hasLength(1));
    expect(acksTo(4), hasLength(2));
  });

  test('the same q from two drones is two different reports', () async {
    await link.deliver(4, mine(11, tag: 7, lat: 50.062975));
    await link.deliver(5, mine(11, tag: 8, lat: 50.063975));

    expect(app.mines, hasLength(2),
        reason: 'sequence numbers are per drone, not global');
    expect(acksTo(4), hasLength(1));
    expect(acksTo(5), hasLength(1));
  });

  test('accuracy and speed from TELEM reach the drone the UI renders', () async {
    // The UI reads Drone, not TelemMessage. Everything applyTelemetry drops is
    // invisible to the operator no matter what the wire carried.
    await link.deliver(4, TelemMessage(
      seq: 30,
      position: const LatLng(50.062975, 19.9157),
      altitude: 3.0,
      state: DroneState.demo,
      velocity: (north: 3.0, east: 4.0),
      accuracyMeters: 1.4,
    ));

    final drone = Drone.byId(4)!;
    expect(drone.accuracyMeters, 1.4);
    expect(drone.groundSpeed, closeTo(5.0, 1e-9));
    expect(app.worstReportedAccuracy, 1.4);
  });

  test('a drone that reports no accuracy shows unknown, not zero', () async {
    await link.deliver(4, TelemMessage(
      seq: 31,
      position: const LatLng(50.062975, 19.9157),
      altitude: 3.0,
      state: DroneState.hover,
    ));

    expect(Drone.byId(4)!.accuracyMeters, isNull);
    expect(app.worstReportedAccuracy, isNull);
  });

  test('two mines just outside the merge radius stay two mines', () async {
    // 3.4 m apart, against a 3 m merge threshold. This is the case that a
    // distance rounded to whole metres silently collapsed into one.
    await link.deliver(4, mine(11, lat: 50.062975));
    await link.deliver(4, MineMessage(
      seq: 12,
      tag: 7,
      position: const LatLng(50.062975 + 3.4 / 110540.0, 19.9157),
    ));

    expect(app.mines, hasLength(2));
  });

  // ---- ARRIVED is a report too, and it drives the formation ----------------

  ArrivedMessage arrived(int seq, LatLng target, {LatLng? at}) => ArrivedMessage(
        seq: seq,
        target: target,
        at: at ?? target,
        speed: 0.05,
      );

  test('an ARRIVED is acknowledged like any other report', () async {
    await link.deliver(4, arrived(31, const LatLng(50.062975, 19.9157)));

    expect(acksTo(4), hasLength(1));
    expect(acksTo(4).single.respondingTo, 31,
        reason: 'without this the drone resends the arrival for ever');
  });

  test('a repeated ARRIVED is acknowledged again but acted on once', () async {
    await app.demo.start([4], 3.0);
    // The START_DEMO ACK anchors the figure.
    final start = link.sent.last.message;
    app.tracker.handleIncoming(
      4,
      AckMessage(
        seq: 900,
        respondingTo: start.seq,
        position: const LatLng(50.062975, 19.9157),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final figure = app.demo.progressFor(4)!.figure;
    expect(figure, isNotEmpty, reason: 'anchored');

    // Airborne and holding over the anchor: the opening barrier.
    await link.deliver(4, arrived(31, const LatLng(50.062975, 19.9157)));
    await Future<void>.delayed(Duration.zero);
    expect(app.demo.progressFor(4)!.steps, 0);

    await link.deliver(4, arrived(32, figure[0]));
    await Future<void>.delayed(Duration.zero);
    expect(app.demo.progressFor(4)!.steps, 1);

    // Our ACK was lost, so the drone says vertex 0 again. It is still standing
    // there; stepping again would put the formation ahead of the airframe.
    await link.deliver(4, arrived(32, figure[0]));
    await Future<void>.delayed(Duration.zero);

    expect(app.demo.progressFor(4)!.steps, 1, reason: 'still walking to vertex 1');
    expect(acksTo(4).where((a) => a.respondingTo == 32), hasLength(2),
        reason: 'every repeat is answered');
  });

  test('a drone whose sequence counter restarts is not mistaken for a repeat',
      () async {
    // Exactly what phone.log 2026-08-10 shows at 14:02:25: the Pi script was
    // restarted mid-session and q went 119 -> 1 while the app kept running.
    await link.deliver(4, mine(118));
    await link.deliver(4, mine(119, tag: 8, lat: 50.063975));
    expect(app.mines, hasLength(2));

    await link.deliver(4, mine(1, tag: 9, lat: 50.064975));

    expect(app.mines, hasLength(3),
        reason: 'a restarted counter must not silence the drone that restarted');
  });
}
