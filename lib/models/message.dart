import 'dart:typed_data';
import 'package:latlong2/latlong.dart';

import 'drone.dart';
import 'command.dart';

class Message {
  final int droneId;
  final Command command;
  final bool ack;
  final Uint8List payload;
  final Uint8List raw;
  final Endian endian;

  Message._(this.droneId, this.command, this.ack, this.payload, this.raw, this.endian);

  static List<int> registeredMessages = [2, 6, 10, 34];

  factory Message.parse(Uint8List frame, {Endian endian = Endian.little}) {
    if (frame.length < 2) {
      throw const FormatException('Frame too short (< 2 bytes)');
    }
    final first = frame[0];
    final ack = (first & 0x80) != 0;
    final droneId = first & 0x7F;
    if (!Drone.isValidId(droneId)) {
      throw FormatException('Invalid drone id: 0x${droneId.toRadixString(16)}');
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
      case 0x09:
        if (payload.length != 8) {
          throw FormatException('FLY_POLAR must be 8 bytes (2x float32), found ${payload.length}');
        }
        break;
      case 0x0B:
        if (payload.length != 4) {
          throw FormatException('SET_SPEED must be 4 bytes (float32), found ${payload.length}');
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

    return Message._(droneId, cmd, ack, payload, frame, endian);
  }

  bool get isBroadcast => droneId == Drone.broadcast;

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
        '(${Drone.registeredDronesMap[droneId]!.name}) '
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

  static bool isValidMessageHeader(Uint8List msg) {
    if (msg.length < 2) return false;
    return Drone.isValidId(msg[0] & 0x7F) && Command.registeredCommands.values.map((e) => e.byte).contains(msg[1]);
  }
}

class MessageBuilder {
  static Uint8List start({required int dest}) => _build(dest, Command.start, const []);

  static Uint8List msnStart({required int dest}) => _build(dest, Command.msnStart, const []);

  static Uint8List end({required int dest}) => _build(dest, Command.end, const []);

  static Uint8List prepareForTest({required int dest}) => _build(dest, Command.prepTest, const []);

  static Uint8List prepareForMission({required int dest}) => _build(dest, Command.prepMsn, const []);

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

  static Uint8List flyPolar({
    required int dest,
    required double dist,
    required double angle,
    Endian endian = Endian.little,
  }) {
    _assertDest(dest);
    final out = <int>[dest & 0x7F, Command.flyPolar.byte];
    _appendF32(out, dist, endian);
    _appendF32(out, angle, endian);
    return Uint8List.fromList(out);
  }

  static Uint8List setSpeed({
    required int dest,
    required double speed,
    Endian endian = Endian.little,
  }) {
    _assertDest(dest);
    final out = <int>[dest & 0x7F, Command.setSpeed.byte];
    _appendF32(out, speed, endian);
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
  if (!Drone.isValidId(dest)) {
    throw ArgumentError('Invalid dest: 0x${dest.toRadixString(16)}');
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
