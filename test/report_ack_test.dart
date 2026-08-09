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
}
