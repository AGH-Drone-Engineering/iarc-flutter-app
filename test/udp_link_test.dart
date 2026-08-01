import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_esp_android_communication/models/link_config.dart';
import 'package:flutter_esp_android_communication/models/mission_message.dart';
import 'package:flutter_esp_android_communication/services/mission_transport.dart';
import 'package:flutter_esp_android_communication/services/udp_link_service.dart';

/// A drone's Pi: listens on a loopback port, decodes mission JSON, replies.
class FakeDrone {
  FakeDrone(this._socket) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = _socket.receive();
      if (d == null) return;
      _lastSender = d.address;
      _lastSenderPort = d.port;
      final text = utf8.decode(d.data);
      received.add(MissionMessage.decode(text));
      _onReceive?.complete();
      _onReceive = null;
    });
  }

  static Future<FakeDrone> bind() async =>
      FakeDrone(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));

  final RawDatagramSocket _socket;
  final received = <MissionMessage>[];
  InternetAddress? _lastSender;
  int? _lastSenderPort;
  Completer<void>? _onReceive;

  int get port => _socket.port;

  Future<void> nextMessage({Duration timeout = const Duration(seconds: 2)}) {
    _onReceive = Completer<void>();
    return _onReceive!.future.timeout(timeout);
  }

  void reply(MissionMessage message) {
    _socket.send(utf8.encode(message.encode()), _lastSender!, _lastSenderPort!);
  }

  void close() => _socket.close();
}

LinkConfig configFor(FakeDrone drone, {int droneId = 1, int listenPort = 0}) =>
    LinkConfig(
      transport: TransportKind.udp,
      listenPort: listenPort,
      endpoints: [
        UdpEndpoint(droneId: droneId, host: '127.0.0.1', port: drone.port),
      ],
    );

void main() {
  group('LinkConfig', () {
    test('round-trips through JSON', () {
      final original = LinkConfig(
        transport: TransportKind.udp,
        listenPort: 14650,
        endpoints: const [
          UdpEndpoint(droneId: 1, host: 'raspi-usa-1.local', port: 14660),
          UdpEndpoint(droneId: 2, host: '192.168.1.42', port: 14661),
        ],
      );

      final restored = LinkConfig.decode(original.encode(), [1, 2]);
      expect(restored.transport, TransportKind.udp);
      expect(restored.listenPort, 14650);
      expect(restored.endpointFor(1)!.host, 'raspi-usa-1.local');
      expect(restored.endpointFor(2)!.port, 14661);
    });

    test('falls back to defaults on garbage', () {
      final c = LinkConfig.decode('not json', [1, 2]);
      expect(c.transport, TransportKind.lora);
      expect(c.endpoints, hasLength(2));
    });

    test('gains defaults for drones missing from stored config', () {
      final stored = LinkConfig(
        transport: TransportKind.udp,
        listenPort: 1,
        endpoints: const [UdpEndpoint(droneId: 1, host: 'a', port: 2)],
      ).encode();

      final restored = LinkConfig.decode(stored, [1, 2, 3]);
      expect(restored.endpoints, hasLength(3));
      expect(restored.endpointFor(1)!.host, 'a');
      expect(restored.endpointFor(3), isNotNull);
    });

    test('an empty host is not configured', () {
      const empty = UdpEndpoint(droneId: 1, host: '  ', port: 14660);
      const badPort = UdpEndpoint(droneId: 1, host: 'x', port: 0);
      expect(empty.isConfigured, isFalse);
      expect(badPort.isConfigured, isFalse);
      expect(const UdpEndpoint(droneId: 1, host: 'x', port: 1).isConfigured, isTrue);
    });
  });

  group('UdpLinkService', () {
    late FakeDrone drone;
    late UdpLinkService link;

    setUp(() async {
      drone = await FakeDrone.bind();
      link = UdpLinkService();
    });

    tearDown(() async {
      await link.dispose();
      drone.close();
    });

    test('connects and resolves the endpoint', () async {
      expect(await link.connect(configFor(drone)), isTrue);
      expect(link.isConnected, isTrue);
      expect(link.reachableDrones, [1]);
    });

    test('delivers a command as one datagram of mission JSON', () async {
      await link.connect(configFor(drone));

      final pending = drone.nextMessage();
      expect(await link.sendMission(1, StartDemoMessage(seq: 7, altitude: 3.0)),
          isTrue);
      await pending;

      expect(drone.received, hasLength(1));
      final rx = drone.received.single as StartDemoMessage;
      expect(rx.seq, 7);
      expect(rx.altitude, 3.0);
    });

    test('surfaces a reply as an IncomingMission tagged with the drone id', () async {
      await link.connect(configFor(drone));

      final incoming = link.missionStream.first;
      final pending = drone.nextMessage();
      await link.sendMission(1, StatusMessage(seq: 1));
      await pending;

      drone.reply(TelemMessage(
        seq: 20,
        position: LatLng(50.062975, 19.9157),
        altitude: 4.5,
        battery: 15.1,
        state: DroneState.hover,
      ));

      final got = await incoming.timeout(const Duration(seconds: 2));
      expect(got.from, 1);
      final telem = got.message as TelemMessage;
      expect(telem.state, DroneState.hover);
      expect(telem.altitude, 4.5);
      expect(telem.battery, 15.1);
    });

    test('broadcast reaches every resolved endpoint', () async {
      final second = await FakeDrone.bind();
      addTearDown(second.close);

      await link.connect(LinkConfig(
        transport: TransportKind.udp,
        listenPort: 0,
        endpoints: [
          UdpEndpoint(droneId: 1, host: '127.0.0.1', port: drone.port),
          UdpEndpoint(droneId: 2, host: '127.0.0.1', port: second.port),
        ],
      ));

      final a = drone.nextMessage();
      final b = second.nextMessage();
      expect(await link.sendMission(kBroadcastAddress, LandMessage(seq: 3)), isTrue);
      await Future.wait([a, b]);

      expect(drone.received.single, isA<LandMessage>());
      expect(second.received.single, isA<LandMessage>());
    });

    test('refuses to send when disconnected', () async {
      expect(await link.sendMission(1, LandMessage(seq: 1)), isFalse);
      expect(drone.received, isEmpty);
    });

    test('refuses to send to an unresolved drone', () async {
      await link.connect(configFor(drone, droneId: 1));
      expect(await link.sendMission(2, LandMessage(seq: 1)), isFalse);
    });

    test('connect fails when no endpoint is configured', () async {
      final ok = await link.connect(const LinkConfig(
        transport: TransportKind.udp,
        listenPort: 0,
        endpoints: [UdpEndpoint(droneId: 1, host: '', port: 14660)],
      ));
      expect(ok, isFalse);
      expect(link.isConnected, isFalse);
    });

    test('connect fails when the host does not resolve', () async {
      final ok = await link.connect(const LinkConfig(
        transport: TransportKind.udp,
        listenPort: 0,
        endpoints: [
          UdpEndpoint(droneId: 1, host: 'no-such-host.invalid', port: 14660),
        ],
      ));
      expect(ok, isFalse);
      expect(link.isConnected, isFalse);
    });

    test('disconnect frees the port for a reconnect', () async {
      await link.connect(configFor(drone));
      final port = link.listenPort;
      await link.disconnect();

      expect(link.isConnected, isFalse);
      expect(link.reachableDrones, isEmpty);

      final again = UdpLinkService();
      addTearDown(again.dispose);
      expect(
        await again.connect(configFor(drone, listenPort: port)),
        isTrue,
        reason: 'the previous socket must have been released',
      );
    });
  });
}
