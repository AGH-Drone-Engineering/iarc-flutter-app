import 'dart:convert';

import '../services/mission_transport.dart';

class UdpEndpoint {
  final int droneId;
  final String host;
  final int port;

  const UdpEndpoint({
    required this.droneId,
    required this.host,
    required this.port,
  });

  UdpEndpoint copyWith({String? host, int? port}) => UdpEndpoint(
        droneId: droneId,
        host: host ?? this.host,
        port: port ?? this.port,
      );

  bool get isConfigured => host.trim().isNotEmpty && port > 0 && port < 65536;

  Map<String, Object?> toJson() => {'id': droneId, 'host': host, 'port': port};

  factory UdpEndpoint.fromJson(Map<String, Object?> j) => UdpEndpoint(
        droneId: (j['id'] as num).toInt(),
        host: j['host'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 14660,
      );

  @override
  String toString() => '$host:$port';
}

class LinkConfig {
  final TransportKind transport;
  final int listenPort;
  final List<UdpEndpoint> endpoints;

  const LinkConfig({
    required this.transport,
    required this.listenPort,
    required this.endpoints,
  });

  factory LinkConfig.defaults(List<int> droneIds) => LinkConfig(
        transport: TransportKind.lora,
        listenPort: 14650,
        endpoints: [
          for (final id in droneIds)
            UdpEndpoint(droneId: id, host: 'raspi-usa-$id.local', port: 14660),
        ],
      );

  LinkConfig copyWith({
    TransportKind? transport,
    int? listenPort,
    List<UdpEndpoint>? endpoints,
  }) =>
      LinkConfig(
        transport: transport ?? this.transport,
        listenPort: listenPort ?? this.listenPort,
        endpoints: endpoints ?? this.endpoints,
      );

  LinkConfig withEndpoint(int droneId, {String? host, int? port}) => copyWith(
        endpoints: [
          for (final e in endpoints)
            if (e.droneId == droneId) e.copyWith(host: host, port: port) else e,
        ],
      );

  UdpEndpoint? endpointFor(int droneId) {
    for (final e in endpoints) {
      if (e.droneId == droneId) return e;
    }
    return null;
  }

  List<UdpEndpoint> get configured =>
      endpoints.where((e) => e.isConfigured).toList();

  String encode() => jsonEncode({
        'transport': transport.name,
        'listenPort': listenPort,
        'endpoints': [for (final e in endpoints) e.toJson()],
      });

  static LinkConfig decode(String raw, List<int> droneIds) {
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      final stored = <int, UdpEndpoint>{
        for (final e in (j['endpoints'] as List? ?? []))
          if (e is Map<String, Object?>)
            (e['id'] as num).toInt(): UdpEndpoint.fromJson(e),
      };
      final defaults = LinkConfig.defaults(droneIds);
      return LinkConfig(
        transport: TransportKind.fromName(j['transport'] as String?),
        listenPort: (j['listenPort'] as num?)?.toInt() ?? defaults.listenPort,
        endpoints: [
          for (final id in droneIds) stored[id] ?? defaults.endpointFor(id)!,
        ],
      );
    } catch (_) {
      return LinkConfig.defaults(droneIds);
    }
  }
}
