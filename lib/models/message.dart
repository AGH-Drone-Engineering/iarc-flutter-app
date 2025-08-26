import 'dart:typed_data';
import 'package:latlong2/latlong.dart';

class NodeId {
  static const int drone1 = 0x01;
  static const int drone2 = 0x02;
  static const int drone3 = 0x03;
  static const int drone4 = 0x04;
  static const int broadcast = 0x7F;

  static bool isValid(int id) =>
      id == broadcast || (id >= drone1 && id <= drone4);
}

const Map<int, String> nodeIdToName = {
  NodeId.drone1: "Bajer 1",
  NodeId.drone2: "Bajer 2",
  NodeId.drone3: "Bajer 3",
  NodeId.drone4: "Bajer 4",
  NodeId.broadcast: "All drones"
};

class Command {
  final int byte;
  const Command._(this.byte);

  static const start = Command._(0x01);
  static const crdSnd = Command._(0x02);
  static const flyTo = Command._(0x03);
  static const altSet = Command._(0x04);
  static const msnStart = Command._(0x05);
  static const end = Command._(0x06);
  static const prepareTestFlight = Command._(0x07);
  static const prepareMission = Command._(0x08);

  static const telemetry = Command._(0xFF);


  static const List<Command> _all = [
    start, crdSnd, flyTo, altSet, msnStart, end, telemetry,
  ];

  static Command fromByte(int b) {
    for (final c in _all) {
      if (c.byte == b) return c;
    }
    throw FormatException('Unknown command byte: 0x${b.toRadixString(16).padLeft(2, '0')}');
  }

  @override
  String toString() {
    switch (byte) {
      case 0x01:
        return 'START';
      case 0x02:
        return 'CRD_SND';
      case 0x03:
        return 'FLY_TO';
      case 0x04:
        return 'ALT_SET';
      case 0x05:
        return 'MSN_START';
      case 0x06:
        return 'END';
      case 0x07:
        return 'PREP_TEST';
      case 0x08:
        return 'PREP_MSN';
      case 0xFF:
        return 'TELEMETRY';
      default:
        return '0x${byte.toRadixString(16)}';
    }
  }
}

class Message {
  final int node;
  final Command command;
  final bool ack;
  final Uint8List payload;
  final Uint8List raw;
  final Endian endian;

  Message._(this.node, this.command, this.ack, this.payload, this.raw, this.endian);

  factory Message.parse(Uint8List frame, {Endian endian = Endian.little}) {
    if (frame.length < 2) {
      throw const FormatException('Frame too short (< 2 bytes)');
    }
    final first = frame[0];
    final ack = (first & 0x80) != 0;
    final node = first & 0x7F;
    if (!NodeId.isValid(node)) {
      throw FormatException('Invalid node id: 0x${node.toRadixString(16)}');
    }
    final cmd = Command.fromByte(frame[1]);
    final payload = Uint8List.sublistView(frame, 2);

    switch (cmd.byte) {
      case 0x01:
      case 0x05:
      case 0x06:
      case 0x07:
      case 0x08:
        if (payload.isNotEmpty) {
          throw FormatException('$cmd must have empty payload, found ${payload.length} bytes');
        }
        break;
      case 0x04:
        if (payload.length != 4) {
          throw FormatException('ALT_SET must be 4 bytes (float32), found ${payload.length}');
        }
        break;
      case 0x03:
        if (payload.length != 8) {
          throw FormatException('FLY_TO must be 8 bytes (2x float32), found ${payload.length}');
        }
        break;
      case 0x02:
        if (payload.length != 32) {
          throw FormatException('CRD_SND must be 32 bytes (8x float32), found ${payload.length}');
        }
        break;
      case 0xFF:
        if (payload.length != 8) {
          throw FormatException('TELEMETRY must be 8 bytes (lat float32 + lon float32), found ${payload.length}');
        }
        break;
    }

    return Message._(node, cmd, ack, payload, frame, endian);
  }

  bool get isBroadcast => node == NodeId.broadcast;

  double get altitudeMeters {
    if (command != Command.altSet) {
      throw StateError('No altitude available for $command');
    }
    return _readF32(payload, 0, endian);
  }

  List<LatLng> get points {
    switch (command.byte) {
      case 0x03: // FLY_TO
        return [
          LatLng(_readF32(payload, 0, endian), _readF32(payload, 4, endian)),
        ];
      case 0x02: // CRD_SND (4 corners)
        return _readPairs(payload, endian);
      case 0xFF: // TELEMETRY (single point)
        return [
          LatLng(_readF32(payload, 0, endian), _readF32(payload, 4, endian)),
        ];
      default:
        return [];
    }
  }

  String get hex => bytesToHex(raw);
  
  @override
  String toString() {
    String init = '${ack ? "ACK for " : ""}'
        '(${nodeIdToName[node]}) '
        '${command.toString()} ';
    switch (command.byte) {
      case 0xFF:
        init += points.first.toString();
        break;
      case 0x02:
        init += points.toString();
        break;
      case 0x03:
        init += points.first.toString();
        break;
      case 0x01:
        init += altitudeMeters.toStringAsFixed(2);
      default:
        break;
    }
    return init;
  }
}

class MessageBuilder {
  static Uint8List start({required int dest}) => _build(dest, Command.start, const []);

  static Uint8List msnStart({required int dest}) => _build(dest, Command.msnStart, const []);

  static Uint8List end({required int dest}) => _build(dest, Command.end, const []);

  static Uint8List prepareForTest({required int dest}) => _build(dest, Command.prepareTestFlight, const []);

  static Uint8List prepareForMission({required int dest}) => _build(dest, Command.prepareMission, const []);

  static Uint8List altSet({required int dest, required double meters, Endian endian = Endian.little}) {
    _assertDest(dest);
    final out = <int>[dest & 0x7F, Command.altSet.byte];
    _appendF32(out, meters, endian);
    return Uint8List.fromList(out);
  }

  static Uint8List flyTo({
    required int dest,
    required double lat,
    required double lon,
    Endian endian = Endian.little,
  }) {
    _assertDest(dest);
    final out = <int>[dest & 0x7F, Command.flyTo.byte];
    _appendF32(out, lat, endian);
    _appendF32(out, lon, endian);
    return Uint8List.fromList(out);
  }

  static Uint8List crdSnd({
    required int dest,
    required List<LatLng> corners,
    Endian endian = Endian.little,
  }) {
    _assertDest(dest);
    if (corners.length != 4) {
      throw ArgumentError('CRD_SND requires exactly 4 corners');
    }
    final out = <int>[dest & 0x7F, Command.crdSnd.byte];
    for (final p in corners) {
      _appendF32(out, p.latitude, endian);
      _appendF32(out, p.longitude, endian);
    }
    return Uint8List.fromList(out);
  }

  static Uint8List _build(int dest, Command cmd, List<int> payload) {
    _assertDest(dest);
    return Uint8List.fromList(<int>[dest & 0x7F, cmd.byte, ...payload]);
  }
}

void _assertDest(int dest) {
  if (!NodeId.isValid(dest)) {
    throw ArgumentError('Invalid dest: 0x' + dest.toRadixString(16));
  }
}

List<LatLng> _readPairs(Uint8List data, Endian endian) {
  if (data.length % 8 != 0) {
    throw FormatException('Coordinate payload must be multiple of 8 bytes');
  }
  final out = <LatLng>[];
  for (var i = 0; i < data.length; i += 8) {
    final lat = _readF32(data, i + 0, endian);
    final lon = _readF32(data, i + 4, endian);
    out.add(LatLng(lat, lon));
  }
  return out;
}

double _readF32(Uint8List data, int offset, Endian endian) {
  final bd = ByteData.sublistView(data, offset, offset + 4);
  return bd.getFloat32(0, endian);
}

void _appendF32(List<int> out, double value, Endian endian) {
  final bd = ByteData(4);
  bd.setFloat32(0, value, endian);
  out.addAll(bd.buffer.asUint8List());
}

String bytesToHex(Uint8List bytes, {String sep = ' '}) {
  final sb = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    if (i > 0) sb.write(sep);
    sb.write(bytes[i].toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  return sb.toString();
}

Uint8List hexToBytes(String hex) {
  final cleaned = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (cleaned.length % 2 != 0) {
    throw const FormatException('Hex string must have even length');
  }
  final out = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < cleaned.length; i += 2) {
    out[i ~/ 2] = int.parse(cleaned.substring(i, i + 2), radix: 16);
  }
  return out;
}
