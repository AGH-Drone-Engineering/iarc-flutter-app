import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_esp_android_communication/services/lora_frame.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  group('crc16 (CRC-16/XMODEM)', () {
    test('matches the reference check value', () {
      expect(crc16('123456789'.codeUnits), 0x31C3);
    });

    test('empty input is zero', () {
      expect(crc16(const []), 0x0000);
    });
  });

  group('LoraFrame.encode', () {
    test('GETMSG request', () {
      final f = LoraFrame.request(LoraFrameType.getmsg);
      expect(f.encode(), bytes([0x47, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5B, 0x94]));
    });

    test('ACK frame', () {
      final f = LoraFrame.request(LoraFrameType.ack);
      expect(f.encode(), bytes([0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFD, 0x3E]));
    });

    test('GETCONF request', () {
      final f = LoraFrame.request(LoraFrameType.getconf);
      expect(f.encode(), bytes([0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9F, 0x58]));
    });

    test('SENDMSG "hi" to node 5', () {
      final f = LoraFrame.sendmsg(5, bytes('hi'.codeUnits));
      expect(
        f.encode(),
        bytes([0x53, 0x05, 0x02, 0x00, 0x00, 0x00, 0x68, 0x69, 0x1B, 0x7A]),
      );
    });

    test('length is little-endian across all four bytes', () {
      final f = LoraFrame(LoraFrameType.sendmsg, 1, Uint8List(300));
      final encoded = f.encode();
      expect(encoded.sublist(2, 6), bytes([0x2C, 0x01, 0x00, 0x00])); // 300
    });

    test('rejects a payload over the 248-byte send limit', () {
      expect(
        () => LoraFrame.sendmsg(1, Uint8List(kMaxMessageSize + 1)),
        throwsArgumentError,
      );
      expect(() => LoraFrame.sendmsg(1, Uint8List(kMaxMessageSize)), returnsNormally);
    });
  });

  group('LoraFrameParser', () {
    test('round-trips an encoded frame', () {
      final tx = LoraFrame.sendmsg(7, bytes('hello'.codeUnits));
      final result = LoraFrameParser().feed(tx.encode());

      expect(result.frames, hasLength(1));
      expect(result.noise, isEmpty);
      expect(result.frames.single.type, LoraFrameType.sendmsg);
      expect(result.frames.single.id, 7);
      expect(result.frames.single.payload, bytes('hello'.codeUnits));
    });

    test('parses a GETCONF reply payload as ASCII', () {
      final tx = LoraFrame(LoraFrameType.getconf, 0, bytes('CMDB_ID=5'.codeUnits));
      final result = LoraFrameParser().feed(tx.encode());

      expect(String.fromCharCodes(result.frames.single.payload), 'CMDB_ID=5');
    });

    test('reassembles a frame split across reads', () {
      final parser = LoraFrameParser();
      final encoded = LoraFrame.sendmsg(3, bytes('split me'.codeUnits)).encode();

      for (var i = 0; i < encoded.length - 1; i++) {
        final partial = parser.feed(bytes([encoded[i]]));
        expect(partial.frames, isEmpty, reason: 'byte $i completed a frame early');
      }

      final done = parser.feed(bytes([encoded.last]));
      expect(done.frames, hasLength(1));
      expect(done.frames.single.payload, bytes('split me'.codeUnits));
    });

    test('parses several frames from one read', () {
      final buf = <int>[
        ...LoraFrame.request(LoraFrameType.ack).encode(),
        ...LoraFrame.sendmsg(2, bytes('a'.codeUnits)).encode(),
        ...LoraFrame.request(LoraFrameType.getmsg).encode(),
      ];

      final result = LoraFrameParser().feed(bytes(buf));
      expect(result.frames.map((f) => f.type), [
        LoraFrameType.ack,
        LoraFrameType.sendmsg,
        LoraFrameType.getmsg,
      ]);
      expect(result.noise, isEmpty);
    });

    test('a payload containing 0x0A does not split the frame', () {
      final payload = bytes([0x41, 0x0A, 0x0A, 0x42]);
      final result = LoraFrameParser().feed(LoraFrame.sendmsg(1, payload).encode());

      expect(result.frames, hasLength(1));
      expect(result.frames.single.payload, payload);
    });

    test('routes a corrupted-checksum frame to noise, not frames', () {
      final encoded = LoraFrame.sendmsg(1, bytes('data'.codeUnits)).encode();
      encoded[encoded.length - 1] ^= 0xFF; // break the CRC

      final result = LoraFrameParser().feed(encoded);
      expect(result.frames, isEmpty);
      expect(result.noise, isNotEmpty);
    });

    test('recovers a real frame that follows interleaved log text', () {
      final log = '[I][main] ready addr=0x03\n'.codeUnits;
      final tx = LoraFrame.sendmsg(3, bytes('ok'.codeUnits));

      final result = LoraFrameParser().feed(bytes([...log, ...tx.encode()]));

      expect(result.frames, hasLength(1));
      expect(result.frames.single.payload, bytes('ok'.codeUnits));
      expect(String.fromCharCodes(result.noise), contains('ready addr'));
    });

    test('abandons a partial frame after the idle timeout', () {
      final parser = LoraFrameParser(idleTimeout: const Duration(milliseconds: 100));
      final t0 = DateTime(2026, 1, 1);

      final stuck = bytes([0x53, 0x01, 0xC8, 0x00, 0x00, 0x00, 0x01, 0x02]);
      expect(parser.feed(stuck, now: t0).frames, isEmpty);

      final tx = LoraFrame.sendmsg(4, bytes('after'.codeUnits));
      final result = parser.feed(
        tx.encode(),
        now: t0.add(const Duration(milliseconds: 500)),
      );

      expect(result.frames, hasLength(1), reason: 'parser stayed wedged on the stale header');
      expect(result.frames.single.payload, bytes('after'.codeUnits));
      expect(result.noise, isNotEmpty);
    });

    test('rejects an over-long declared length as desync', () {
      final tooBig = kMaxFramePayload + 1;
      final result = LoraFrameParser().feed(bytes([
        0x53,
        0x01,
        tooBig & 0xFF,
        (tooBig >> 8) & 0xFF,
        0x00,
        0x00,
      ]));

      expect(result.frames, isEmpty);
      expect(result.noise, isNotEmpty);
    });
  });
}
