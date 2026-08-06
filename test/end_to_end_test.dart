import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/services/lora_frame.dart';

class FakeEsp {
  FakeEsp({this.address = 4});

  final int address;
  final _parser = LoraFrameParser();
  final _queue = <({int from, Uint8List payload})>[];

  final received = <LoraFrame>[];

  ({int from, Uint8List payload})? _pending;

  void deliverFromDrone(int from, MissionMessage message) {
    _queue.add((from: from, payload: message.encodeBytes()));
  }

  Uint8List exchange(Uint8List hostBytes) {
    final out = <int>[];
    for (final frame in _parser.feed(hostBytes).frames) {
      received.add(frame);
      final reply = _respond(frame);
      if (reply != null) out.addAll(reply.encode());
    }
    return Uint8List.fromList(out);
  }

  LoraFrame? _respond(LoraFrame frame) {
    switch (frame.type) {
      case LoraFrameType.getmsg:
        _pending ??= _queue.isEmpty ? null : _queue.first;
        final p = _pending;
        if (p == null) return LoraFrame.request(LoraFrameType.ack);
        return LoraFrame(LoraFrameType.getmsg, p.from, p.payload);

      case LoraFrameType.sendmsg:
        return LoraFrame.request(LoraFrameType.ack);

      case LoraFrameType.getconf:
        return LoraFrame(
          LoraFrameType.getconf,
          0,
          Uint8List.fromList(utf8.encode('CMDB_ID=$address')),
        );

      case LoraFrameType.ack:
        if (_pending != null) {
          _queue.remove(_pending);
          _pending = null;
        }
        return null;
    }
  }

  int get queueDepth => _queue.length;
}

void main() {
  test('a command survives the round trip to the wire and back', () {
    final tx = StartMainMessage(
      seq: 42,
      corners: [
        LatLng(50.062975, 19.915700),
        LatLng(50.062983, 19.915846),
        LatLng(50.063157, 19.915882),
        LatLng(50.063200, 19.915770),
      ],
      altitude: 8.0,
    );

    final wire = LoraFrame.sendmsg(3, tx.encodeBytes()).encode();

    final frame = LoraFrameParser().feed(wire).frames.single;
    expect(frame.type, LoraFrameType.sendmsg);
    expect(frame.id, 3);

    final rx = MissionMessage.decodeBytes(frame.payload) as StartMainMessage;
    expect(rx.seq, 42);
    expect(rx.altitude, 8.0);
    for (var i = 0; i < 4; i++) {
      expect(rx.corners[i].latitude, closeTo(tx.corners[i].latitude, 1e-7));
      expect(rx.corners[i].longitude, closeTo(tx.corners[i].longitude, 1e-7));
    }
  });

  test('the spec\'s worked example plays out against a fake ESP', () {
    final esp = FakeEsp();

    final start = StartDemoMessage(seq: 1, altitude: 3.0);
    var reply = esp.exchange(LoraFrame.sendmsg(3, start.encodeBytes()).encode());
    expect(
      LoraFrameParser().feed(reply).frames.single.type,
      LoraFrameType.ack,
      reason: 'SENDMSG must be answered with an ACK',
    );

    reply = esp.exchange(LoraFrame.request(LoraFrameType.getmsg).encode());
    expect(
      LoraFrameParser().feed(reply).frames.single.type,
      LoraFrameType.ack,
      reason: 'an empty queue is signalled by a bare ACK, not an empty GETMSG',
    );

    esp.deliverFromDrone(3, AckMessage(seq: 40, respondingTo: 1));
    esp.deliverFromDrone(
      3,
      TelemMessage(
        seq: 41,
        position: LatLng(50.062975, 19.9157),
        altitude: 3.1,
        battery: 15.6,
        state: DroneState.hover,
      ),
    );

    reply = esp.exchange(LoraFrame.request(LoraFrameType.getmsg).encode());
    var got = LoraFrameParser().feed(reply).frames.single;
    expect(got.type, LoraFrameType.getmsg);
    expect(got.id, 3, reason: 'id carries the sender address');

    final ack = MissionMessage.decodeBytes(got.payload) as AckMessage;
    expect(ack.respondingTo, 1);

    reply = esp.exchange(LoraFrame.request(LoraFrameType.getmsg).encode());
    final repeat = LoraFrameParser().feed(reply).frames.single;
    expect(repeat.payload, got.payload,
        reason: 'the board peeks; it only pops once the host ACKs');
    expect(esp.queueDepth, 2);

    esp.exchange(LoraFrame.request(LoraFrameType.ack).encode());
    expect(esp.queueDepth, 1);

    reply = esp.exchange(LoraFrame.request(LoraFrameType.getmsg).encode());
    got = LoraFrameParser().feed(reply).frames.single;
    final telem = MissionMessage.decodeBytes(got.payload) as TelemMessage;
    expect(telem.state, DroneState.hover);
    expect(telem.battery, 15.6);
    expect(telem.altitude, 3.1);

    esp.exchange(LoraFrame.request(LoraFrameType.ack).encode());
    expect(esp.queueDepth, 0);
  });

  test('GETCONF reports the ground ESP address', () {
    final esp = FakeEsp(address: 7);
    final reply = esp.exchange(LoraFrame.request(LoraFrameType.getconf).encode());
    final frame = LoraFrameParser().feed(reply).frames.single;

    expect(frame.type, LoraFrameType.getconf);
    expect(utf8.decode(frame.payload), 'CMDB_ID=7');
  });

  test('every message type survives framing intact', () {
    final messages = <MissionMessage>[
      StartDemoMessage(seq: 1, altitude: 3.0),
      MoveMessage(seq: 2, target: LatLng(50.062975, 19.9157)),
      LandMessage(seq: 3),
      RthMessage(seq: 4),
      StatusMessage(seq: 6),
      AckMessage(seq: 7, respondingTo: 1),
      NackMessage(seq: 8, respondingTo: 1, error: NackError.geofence),
      MineMessage(seq: 9, tag: 12, position: LatLng(50.062975, 19.9157)),
      EventMessage(seq: 10, event: MissionEvent.waypointReached),
    ];

    for (final tx in messages) {
      final wire = LoraFrame.sendmsg(1, tx.encodeBytes()).encode();
      final frame = LoraFrameParser().feed(wire).frames.single;
      final rx = MissionMessage.decodeBytes(frame.payload);

      expect(rx.type, tx.type);
      expect(rx.seq, tx.seq);
      expect(rx.encode(), tx.encode(), reason: '${tx.type} did not round-trip');
    }
  });

  test('a burst of messages arriving in one read all decode', () {
    final buf = <int>[];
    for (var i = 0; i < 5; i++) {
      final t = TelemMessage(
        seq: i,
        position: LatLng(50.0 + i / 1000, 19.0 + i / 1000),
        altitude: i.toDouble(),
        state: DroneState.main,
      );
      buf.addAll(LoraFrame(LoraFrameType.getmsg, 2, t.encodeBytes()).encode());
    }

    final frames = LoraFrameParser().feed(Uint8List.fromList(buf)).frames;
    expect(frames, hasLength(5));

    for (var i = 0; i < 5; i++) {
      final rx = MissionMessage.decodeBytes(frames[i].payload) as TelemMessage;
      expect(rx.seq, i);
      expect(rx.altitude, i.toDouble());
    }
  });
}
