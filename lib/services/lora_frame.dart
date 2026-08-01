import 'dart:typed_data';

enum LoraFrameType {
  getmsg(0x47),
  sendmsg(0x53),
  getconf(0x43),
  ack(0x41);

  const LoraFrameType(this.byte);
  final int byte;

  static LoraFrameType? fromByte(int b) {
    for (final t in LoraFrameType.values) {
      if (t.byte == b) return t;
    }
    return null;
  }
}

const int kMaxFramePayload = 3072;
const int kMaxMessageSize = 248;

const int _headerLength = 6;
const int _checksumLength = 2;

/// CRC-16/XMODEM: poly 0x1021, init 0x0000, no reflection, no final xor.
int crc16(List<int> data) {
  var crc = 0x0000;
  for (final byte in data) {
    crc ^= (byte & 0xFF) << 8;
    for (var bit = 0; bit < 8; bit++) {
      if ((crc & 0x8000) != 0) {
        crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
      } else {
        crc = (crc << 1) & 0xFFFF;
      }
    }
  }
  return crc & 0xFFFF;
}

class LoraFrame {
  final LoraFrameType type;
  final int id;
  final Uint8List payload;

  LoraFrame(this.type, this.id, Uint8List? payload)
      : payload = payload ?? Uint8List(0);

  LoraFrame.request(this.type)
      : id = 0,
        payload = Uint8List(0);

  factory LoraFrame.sendmsg(int dest, Uint8List payload) {
    if (dest < 0 || dest > 0xFF) {
      throw ArgumentError('Destination out of range: $dest');
    }
    if (payload.length > kMaxMessageSize) {
      throw ArgumentError(
        'Payload is ${payload.length} bytes, over the $kMaxMessageSize-byte limit',
      );
    }
    return LoraFrame(LoraFrameType.sendmsg, dest, payload);
  }

  Uint8List encode() {
    final len = payload.length;
    final out = Uint8List(_headerLength + len + _checksumLength);
    out[0] = type.byte;
    out[1] = id & 0xFF;
    out[2] = len & 0xFF;
    out[3] = (len >> 8) & 0xFF;
    out[4] = (len >> 16) & 0xFF;
    out[5] = (len >> 24) & 0xFF;
    out.setRange(_headerLength, _headerLength + len, payload);

    final crc = crc16(<int>[type.byte, id & 0xFF, ...payload]); // excludes LENGTH
    out[_headerLength + len] = crc & 0xFF;
    out[_headerLength + len + 1] = (crc >> 8) & 0xFF;
    return out;
  }

  @override
  String toString() => '${type.name}(id=$id, len=${payload.length})';
}

class LoraParseResult {
  final List<LoraFrame> frames;
  final Uint8List noise;

  const LoraParseResult(this.frames, this.noise);

  bool get isEmpty => frames.isEmpty && noise.isEmpty;
}

class LoraFrameParser {
  LoraFrameParser({this.idleTimeout = const Duration(milliseconds: 100)});

  final Duration idleTimeout;

  final List<int> _buf = <int>[];
  DateTime? _lastFeed;

  void reset() {
    _buf.clear();
    _lastFeed = null;
  }

  LoraParseResult feed(Uint8List data, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final noise = <int>[];

    final last = _lastFeed;
    if (last != null && _buf.isNotEmpty && at.difference(last) > idleTimeout) {
      noise.addAll(_buf);
      _buf.clear();
    }
    _lastFeed = at;
    _buf.addAll(data);

    final frames = <LoraFrame>[];

    while (_buf.isNotEmpty) {
      final type = LoraFrameType.fromByte(_buf[0]);
      if (type == null) {
        noise.add(_buf.removeAt(0));
        continue;
      }
      if (_buf.length < _headerLength) break;

      final len = _buf[2] | (_buf[3] << 8) | (_buf[4] << 16) | (_buf[5] << 24);
      if (len < 0 || len > kMaxFramePayload) {
        noise.add(_buf.removeAt(0));
        continue;
      }

      final total = _headerLength + len + _checksumLength;
      if (_buf.length < total) break;

      final payload =
          Uint8List.fromList(_buf.sublist(_headerLength, _headerLength + len));
      final expected = crc16(<int>[_buf[0], _buf[1], ...payload]);
      final actual = _buf[_headerLength + len] | (_buf[_headerLength + len + 1] << 8);

      if (expected != actual) {
        noise.add(_buf.removeAt(0));
        continue;
      }

      frames.add(LoraFrame(type, _buf[1], payload));
      _buf.removeRange(0, total);
    }

    return LoraParseResult(frames, Uint8List.fromList(noise));
  }
}
