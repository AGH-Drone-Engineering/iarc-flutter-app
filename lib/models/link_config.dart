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

/// The drone treats a repeated `q` as a retransmission only while it still has
/// the reply cached — `DEDUPE_WINDOW`, 5 s (PROTOCOL.md §7).
const kDroneDedupeWindowMs = 5000;

/// Bounds for the ACK settings, shared by the fields on the link tab and the
/// decoder -- a stored zero would arm a zero-length retry timer.
///
/// The ceiling is not a matter of taste. A retry reuses the original `q`, so one
/// that arrives after [kDroneDedupeWindowMs] is not a retransmission at all: the
/// drone has forgotten the reply, cannot tell it from a new command, and
/// executes it again. On 2026-08-10 this was set to 10 s, and a `MOVE` retry
/// fired ten seconds and four vertices late flew a drone back across the figure.
///
/// So the maximum is held safely under the drone's window. Patience is bought
/// with [kMaxAttemptsRange] instead, which costs nothing when the link is
/// healthy — retries only happen when an ACK is already missing.
const kAckTimeoutMsRange = (min: 100, max: 4000);
const kMaxAttemptsRange = (min: 1, max: 10);

class LinkConfig {
  final TransportKind transport;
  final int listenPort;
  final List<UdpEndpoint> endpoints;

  /// How long a mission message waits for its ACK, and how many times it is
  /// sent before the drone is called silent. Operator-settable because the
  /// right numbers for a LoRa hop across a field are not the ones for a bench
  /// cable, and they apply to every message on either transport.
  final int ackTimeoutMs;
  final int maxAttempts;

  const LinkConfig({
    required this.transport,
    required this.listenPort,
    required this.endpoints,
    this.ackTimeoutMs = 2000,
    this.maxAttempts = 3,
  });

  factory LinkConfig.defaults(List<int> droneIds) => LinkConfig(
        transport: TransportKind.lora,
        listenPort: 14650,
        endpoints: [
          for (final id in droneIds)
            UdpEndpoint(droneId: id, host: 'raspi-usa-$id.local', port: 14660),
        ],
      );

  Duration get ackTimeout => Duration(milliseconds: ackTimeoutMs);

  /// How long the operator waits before a silent drone is reported as such.
  Duration get worstCaseWait => ackTimeout * maxAttempts;

  LinkConfig copyWith({
    TransportKind? transport,
    int? listenPort,
    List<UdpEndpoint>? endpoints,
    int? ackTimeoutMs,
    int? maxAttempts,
  }) =>
      LinkConfig(
        transport: transport ?? this.transport,
        listenPort: listenPort ?? this.listenPort,
        endpoints: endpoints ?? this.endpoints,
        ackTimeoutMs: ackTimeoutMs ?? this.ackTimeoutMs,
        maxAttempts: maxAttempts ?? this.maxAttempts,
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
        'ackTimeoutMs': ackTimeoutMs,
        'maxAttempts': maxAttempts,
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
        ackTimeoutMs: ((j['ackTimeoutMs'] as num?)?.toInt() ??
                defaults.ackTimeoutMs)
            .clamp(kAckTimeoutMsRange.min, kAckTimeoutMsRange.max),
        maxAttempts: ((j['maxAttempts'] as num?)?.toInt() ??
                defaults.maxAttempts)
            .clamp(kMaxAttemptsRange.min, kMaxAttemptsRange.max),
      );
    } catch (_) {
      return LinkConfig.defaults(droneIds);
    }
  }
}
