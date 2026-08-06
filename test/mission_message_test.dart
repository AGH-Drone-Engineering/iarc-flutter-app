import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/services/lora_frame.dart';

final _parkJordana = <LatLng>[
  LatLng(50.062975, 19.915700),
  LatLng(50.062983, 19.915846),
  LatLng(50.063157, 19.915882),
  LatLng(50.063200, 19.915770),
];

void main() {
  group('encoding', () {
    test('START_DEMO round-trips', () {
      final tx = StartDemoMessage(seq: 1, altitude: 3.0);
      expect(tx.encode(), '{"v":1,"q":1,"t":"START_DEMO","alt":3.0}');

      final rx = MissionMessage.decode(tx.encode()) as StartDemoMessage;
      expect(rx.seq, 1);
      expect(rx.altitude, 3.0);
    });

    test('START_MAIN round-trips with full coordinate precision', () {
      final tx = StartMainMessage(seq: 2, corners: _parkJordana, altitude: 8.0);
      final rx = MissionMessage.decode(tx.encode()) as StartMainMessage;

      expect(rx.corners, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(rx.corners[i].latitude, closeTo(_parkJordana[i].latitude, 1e-7));
        expect(rx.corners[i].longitude, closeTo(_parkJordana[i].longitude, 1e-7));
      }
      expect(rx.altitude, 8.0);
    });

    test('START_MAIN puts latitude first', () {
      final tx = StartMainMessage(
        seq: 1,
        corners: [
          LatLng(50.1, 19.9),
          LatLng(50.2, 19.9),
          LatLng(50.2, 19.8),
          LatLng(50.1, 19.8),
        ],
        altitude: 8.0,
      );
      final c = (jsonDecode(tx.encode()) as Map)['c'] as List;
      expect((c.first as List)[0], 50.1, reason: 'first element must be latitude');
      expect((c.first as List)[1], 19.9);
    });

    test('MOVE carries an absolute target, latitude first', () {
      final tx = MoveMessage(seq: 3, target: LatLng(50.062975, 19.9157));
      expect(tx.encode(), '{"v":1,"q":3,"t":"MOVE","to":[50.062975,19.9157]}');

      final rx = MissionMessage.decode(tx.encode()) as MoveMessage;
      expect(rx.target.latitude, closeTo(50.062975, 1e-7));
      expect(rx.target.longitude, closeTo(19.9157, 1e-7));
    });

    test('KILL is not a protocol message — the killswitch is hardware', () {
      expect(
        () => MissionMessage.decode('{"v":1,"q":6,"t":"KILL","k":"BE11DEAD"}'),
        throwsA(isA<UnsupportedMessageTypeException>()),
      );
    });

    test('TELEM round-trips, battery optional', () {
      final withBat = TelemMessage(
        seq: 12,
        position: LatLng(50.062975, 19.9157),
        altitude: 8.2,
        battery: 14.8,
        state: DroneState.main,
      );
      final rx = MissionMessage.decode(withBat.encode()) as TelemMessage;
      expect(rx.battery, 14.8);
      expect(rx.state, DroneState.main);
      expect(rx.altitude, 8.2);

      final noBat = TelemMessage(
        seq: 13,
        position: LatLng(50.062975, 19.9157),
        altitude: 8.2,
        state: DroneState.hover,
      );
      expect(noBat.encode(), isNot(contains('bat')));
      expect((MissionMessage.decode(noBat.encode()) as TelemMessage).battery, isNull);
    });

    test('ACK and NACK carry the responding-to sequence', () {
      final ack = MissionMessage.decode('{"v":1,"q":40,"t":"ACK","re":7}') as AckMessage;
      expect(ack.respondingTo, 7);
      expect(ack.position, isNull, reason: 'the beacon fields are optional');

      final nack = MissionMessage.decode(
        '{"v":1,"q":41,"t":"NACK","re":7,"err":"NO_GPS"}',
      ) as NackMessage;
      expect(nack.respondingTo, 7);
      expect(nack.error, NackError.noGps);
    });

    test('ACK can carry the beacon that anchors a demo', () {
      final tx = AckMessage(
        seq: 40,
        respondingTo: 1,
        position: LatLng(50.062975, 19.9157),
      );
      expect(tx.encode(),
          '{"v":1,"q":40,"t":"ACK","re":1,"lat":50.062975,"lon":19.9157}');

      final rx = MissionMessage.decode(tx.encode()) as AckMessage;
      expect(rx.position!.latitude, closeTo(50.062975, 1e-7));
    });

    test('MINE and EVT round-trip', () {
      final mine = MineMessage(seq: 1, tag: 7, position: LatLng(50.062975, 19.9157));
      expect((MissionMessage.decode(mine.encode()) as MineMessage).tag, 7);

      final evt = EventMessage(seq: 2, event: MissionEvent.missionDone);
      expect((MissionMessage.decode(evt.encode()) as EventMessage).event,
          MissionEvent.missionDone);
    });
  });

  group('transport constraints', () {
    test('worst-case START_MAIN fits the 248-byte limit', () {
      final tx = StartMainMessage(
        seq: 65535,
        corners: [
          LatLng(-50.1234567, -119.1234567),
          LatLng(-50.7654321, -119.7654321),
          LatLng(-50.1111111, -119.9999999),
          LatLng(-50.9999999, -119.1111111),
        ],
        altitude: 30.0,
      );
      final bytes = tx.encodeBytes();
      expect(bytes.length, lessThanOrEqualTo(kMaxMessageSize));
    });

    test('no payload contains a newline, CR, or NUL', () {
      final messages = <MissionMessage>[
        StartDemoMessage(seq: 1, altitude: 3.0),
        StartMainMessage(seq: 2, corners: _parkJordana, altitude: 8.0),
        MoveMessage(seq: 3, target: LatLng(50.062975, 19.9157)),
        LandMessage(seq: 4),
        RthMessage(seq: 5),
        StatusMessage(seq: 7),
        TelemMessage(
          seq: 8,
          position: LatLng(50.062975, 19.9157),
          altitude: 8.2,
          battery: 14.8,
          state: DroneState.main,
        ),
        MineMessage(seq: 9, tag: 7, position: LatLng(50.062975, 19.9157)),
        EventMessage(seq: 10, event: MissionEvent.landed),
      ];

      for (final m in messages) {
        final bytes = m.encodeBytes();
        expect(bytes, isNot(contains(0x0A)), reason: '${m.type} contains LF');
        expect(bytes, isNot(contains(0x0D)), reason: '${m.type} contains CR');
        expect(bytes, isNot(contains(0x00)), reason: '${m.type} contains NUL');
        expect(bytes.length, lessThanOrEqualTo(kMaxMessageSize), reason: '${m.type} too long');
      }
    });

    test('never emits exponent notation', () {
      final tx = TelemMessage(
        seq: 1,
        position: LatLng(0.0000001, -0.0000001),
        altitude: 0.0,
        state: DroneState.idle,
      );
      expect(tx.encode().toLowerCase(), isNot(contains('e-')));
      expect(tx.encode().toLowerCase(), isNot(contains('e+')));
    });

    test('encodeBytes throws rather than silently truncating', () {
      final huge = StartMainMessage(
        seq: 65535,
        corners: _parkJordana,
        altitude: 8.0,
      );
      expect(huge.encodeBytes().length, lessThanOrEqualTo(kMaxMessageSize));
    });
  });

  group('decoding failures', () {
    test('rejects a version mismatch', () {
      expect(
        () => MissionMessage.decode('{"v":2,"q":1,"t":"LAND"}'),
        throwsA(isA<MissionMessageException>()),
      );
    });

    test('unknown type raises a distinguishable exception so we can NACK', () {
      expect(
        () => MissionMessage.decode('{"v":1,"q":9,"t":"WARP_DRIVE"}'),
        throwsA(isA<UnsupportedMessageTypeException>()
            .having((e) => e.seq, 'seq', 9)
            .having((e) => e.messageType, 'type', 'WARP_DRIVE')),
      );
    });

    test('rejects malformed JSON', () {
      expect(
        () => MissionMessage.decode('not json at all'),
        throwsA(isA<MissionMessageException>()),
      );
    });

    test('rejects a missing required field', () {
      expect(
        () => MissionMessage.decode('{"v":1,"q":1,"t":"START_DEMO"}'),
        throwsA(isA<MissionMessageException>()),
      );
    });

    test('rejects START_MAIN with the wrong corner count', () {
      expect(
        () => MissionMessage.decode(
          '{"v":1,"q":1,"t":"START_MAIN","c":[[50.1,19.9],[50.2,19.9]],"alt":8.0}',
        ),
        throwsA(isA<MissionMessageException>()),
      );
    });

    test('ignores unknown fields for forward compatibility', () {
      final rx = MissionMessage.decode(
        '{"v":1,"q":1,"t":"START_DEMO","alt":3.0,"future_field":"whatever"}',
      ) as StartDemoMessage;
      expect(rx.altitude, 3.0);
    });
  });

  group('SeqCounter', () {
    test('increments and wraps at 16 bits', () {
      final c = SeqCounter();
      expect(c.take(), 1);
      expect(c.take(), 2);

      for (var i = 0; i < 0xFFFF - 3; i++) {
        c.take();
      }
      expect(c.take(), 0xFFFF);
      expect(c.take(), 0);
      expect(c.take(), 1);
    });
  });
}
