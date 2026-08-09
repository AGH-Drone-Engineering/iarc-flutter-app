import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';

/// The protocol has two hand-written codecs — `comms/app_protocol.py` and
/// `mission_message.dart` — and nothing but discipline keeps their field names
/// in step. A typo in one direction is invisible until a drone is airborne.
///
/// These vectors are produced BY the Python encoder (see the generator in
/// test/support/python_vectors.json) and decoded here, so a field that only one
/// side knows about fails on the ground instead.
void main() {
  late Map<String, dynamic> vectors;

  setUpAll(() {
    vectors = jsonDecode(
      File('test/support/python_vectors.json').readAsStringSync(),
    ) as Map<String, dynamic>;
  });

  MissionMessage decode(String key) =>
      MissionMessage.decode(vectors[key] as String);

  test('a fully populated TELEM survives the crossing intact', () {
    final m = decode('telem_full') as TelemMessage;

    expect(m.seq, 42);
    expect(m.position.latitude, closeTo(50.062975, 1e-9));
    expect(m.position.longitude, closeTo(19.9157, 1e-9));
    expect(m.altitude, 3.0);
    expect(m.battery, 15.6);
    expect(m.batteryPercent, 88);
    expect(m.state, DroneState.demo);
    expect(m.sampleMs, 123456, reason: 'ts');
    expect(m.velocity?.north, 1.23, reason: 'vel[0] is north');
    expect(m.velocity?.east, -0.45, reason: 'vel[1] is east');
    expect(m.groundSpeed, closeTo(1.3096, 1e-3));
    expect(m.accuracyMeters, 0.85, reason: 'acc');
  });

  test('the optional fields are optional on both sides', () {
    final m = decode('telem_minimal') as TelemMessage;

    expect(m.state, DroneState.idle);
    expect(m.battery, isNull);
    expect(m.batteryPercent, isNull);
    expect(m.sampleMs, isNull);
    expect(m.velocity, isNull);
    expect(m.accuracyMeters, isNull,
        reason: 'absent accuracy must decode as unknown, not as zero');
    expect(m.groundSpeed, isNull);
  });

  test('an ACK carries the anchor position when the drone had one', () {
    final withPos = decode('ack_with_position') as AckMessage;
    expect(withPos.respondingTo, 1620);
    expect(withPos.position?.latitude, closeTo(50.062975, 1e-9));

    final bare = decode('ack_bare') as AckMessage;
    expect(bare.respondingTo, 1621);
    expect(bare.position, isNull);
  });

  test('NACK, MINE, SCAN and EVT all cross', () {
    final nack = decode('nack') as NackMessage;
    expect(nack.respondingTo, 1622);
    expect(nack.error, NackError.geofence);

    final mine = decode('mine') as MineMessage;
    expect(mine.tag, 7);
    expect(mine.position.latitude, closeTo(50.0631, 1e-9));

    final scan = decode('scan') as ScanMessage;
    expect(scan.cornerA.latitude, closeTo(50.0629, 1e-9));
    expect(scan.cornerB.longitude, closeTo(19.9159, 1e-9));

    final evt = decode('evt') as EventMessage;
    expect(evt.event, MissionEvent.waypointReached);
  });

  test('re-encoding in Dart produces the same fields Python sent', () {
    for (final key in vectors.keys) {
      final original = jsonDecode(vectors[key] as String) as Map<String, Object?>;
      final round = MissionMessage.decode(vectors[key] as String).toJson();

      expect(round.keys.toSet(), original.keys.toSet(),
          reason: '$key: field names must match exactly in both directions');
      for (final field in original.keys) {
        expect(round[field], original[field], reason: '$key.$field');
      }
    }
  });
}
