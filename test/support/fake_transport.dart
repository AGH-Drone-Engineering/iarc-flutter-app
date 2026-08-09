import 'dart:async';

import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/services/mission_transport.dart';

/// A link that goes nowhere: records what the app sends and lets a test hand it
/// whatever a drone might say.
class FakeTransport implements MissionTransport {
  final sent = <({int dest, MissionMessage message})>[];
  final _incoming = StreamController<IncomingMission>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  final _status = StreamController<String>.broadcast();

  /// Push one message up from a drone and let the app process it.
  Future<void> deliver(int from, MissionMessage message) async {
    _incoming.add(IncomingMission(from, message));
    await Future<void>.delayed(Duration.zero);
  }

  @override
  TransportKind get kind => TransportKind.udp;
  @override
  Stream<IncomingMission> get missionStream => _incoming.stream;
  @override
  Stream<LinkState> get stateStream => _state.stream;
  @override
  Stream<String> get statusStream => _status.stream;
  @override
  LinkState get state => LinkState.connected;
  @override
  bool get isConnected => true;
  @override
  String describeDest(int dest) => 'node $dest';
  @override
  Future<bool> sendMission(int dest, MissionMessage message) async {
    sent.add((dest: dest, message: message));
    return true;
  }

  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    await _incoming.close();
    await _state.close();
    await _status.close();
  }
}
