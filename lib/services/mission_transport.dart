import '../models/mission_message.dart';

class IncomingMission {
  final int from;
  final MissionMessage message;
  const IncomingMission(this.from, this.message);
}

enum LinkState { disconnected, connecting, connected }

enum TransportKind {
  lora('LoRa (USB)'),
  udp('UDP (Wi-Fi)');

  const TransportKind(this.label);
  final String label;

  static TransportKind fromName(String? s) =>
      TransportKind.values.firstWhere((t) => t.name == s,
          orElse: () => TransportKind.lora);
}

abstract class MissionTransport {
  TransportKind get kind;

  Stream<LinkState> get stateStream;
  Stream<String> get statusStream;
  Stream<IncomingMission> get missionStream;

  LinkState get state;
  bool get isConnected;

  String describeDest(int dest);

  Future<bool> sendMission(int dest, MissionMessage message);
  Future<void> disconnect();
  Future<void> dispose();
}
