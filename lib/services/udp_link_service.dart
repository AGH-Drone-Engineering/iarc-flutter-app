import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/link_config.dart';
import '../models/mission_message.dart';
import 'global_log.dart';
import 'mission_transport.dart';

const _tag = 'udp';

class UdpLinkService implements MissionTransport {
  UdpLinkService();

  @override
  TransportKind get kind => TransportKind.udp;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  LinkConfig? _config;

  final Map<int, InternetAddress> _addressOf = {};
  final Map<String, int> _droneAt = {};
  final Map<String, DateTime> _lastStrangerWarning = {};

  final _stateCtl = StreamController<LinkState>.broadcast();
  final _statusCtl = StreamController<String>.broadcast();
  final _missionCtl = StreamController<IncomingMission>.broadcast();

  @override
  Stream<LinkState> get stateStream => _stateCtl.stream;
  @override
  Stream<String> get statusStream => _statusCtl.stream;
  @override
  Stream<IncomingMission> get missionStream => _missionCtl.stream;

  LinkState _state = LinkState.disconnected;
  @override
  LinkState get state => _state;
  @override
  bool get isConnected => _state == LinkState.connected;

  int get listenPort => _socket?.port ?? 0;
  List<int> get reachableDrones => _addressOf.keys.toList()..sort();

  void _setState(LinkState s, String message) {
    _state = s;
    logTrace(_tag, 'state=${s.name} "$message"');
    if (!_stateCtl.isClosed) _stateCtl.add(s);
    if (!_statusCtl.isClosed) _statusCtl.add(message);
  }

  @override
  String describeDest(int dest) {
    if (dest == kBroadcastAddress) return 'all drones';
    final ep = _config?.endpointFor(dest);
    return ep == null ? 'node $dest' : '$ep';
  }

  Future<bool> connect(LinkConfig config) async {
    await disconnect();
    _config = config;
    _setState(LinkState.connecting, 'Binding UDP :${config.listenPort}…');

    final endpoints = config.configured;
    if (endpoints.isEmpty) {
      _setState(LinkState.disconnected, 'No drone endpoints configured');
      logError('UDP: no endpoints configured', _tag);
      return false;
    }

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        config.listenPort,
      );
      socket.broadcastEnabled = true;
      _socket = socket;
      _sub = socket.listen(_onEvent, onError: (Object e) {
        logError('UDP socket error: $e', _tag);
        _setState(LinkState.disconnected, 'UDP error');
      });
      logTrace(_tag, 'bound 0.0.0.0:${socket.port}');
    } catch (e) {
      logError('Could not bind UDP :${config.listenPort}: $e', _tag);
      _setState(LinkState.disconnected, 'Bind failed: $e');
      return false;
    }

    await _resolveEndpoints(endpoints);

    if (_addressOf.isEmpty) {
      await disconnect();
      _setState(LinkState.disconnected, 'No endpoint resolved');
      return false;
    }

    _setState(
      LinkState.connected,
      'UDP :${_socket!.port} → ${_addressOf.length}/${endpoints.length} drone(s)',
    );
    logInfo('UDP link up on :${_socket!.port}, '
        'reachable: ${reachableDrones.join(", ")}', _tag);
    return true;
  }

  Future<void> _resolveEndpoints(List<UdpEndpoint> endpoints) async {
    _addressOf.clear();
    _droneAt.clear();

    for (final ep in endpoints) {
      try {
        final addrs = await InternetAddress.lookup(ep.host)
            .timeout(const Duration(seconds: 3));
        final v4 = addrs.firstWhere(
          (a) => a.type == InternetAddressType.IPv4,
          orElse: () => addrs.first,
        );
        _addressOf[ep.droneId] = v4;
        _droneAt[v4.address] = ep.droneId;
        logInfo('Drone ${ep.droneId}: ${ep.host} → ${v4.address}:${ep.port}', _tag);
      } catch (e) {
        logWarn('Could not resolve ${ep.host} for drone ${ep.droneId}: $e', _tag);
      }
    }
  }

  @override
  Future<bool> sendMission(int dest, MissionMessage message) async {
    final socket = _socket;
    final config = _config;
    if (socket == null || config == null || !isConnected) {
      logWarn('Send failed: UDP not connected', _tag);
      return false;
    }

    final targets = dest == kBroadcastAddress
        ? _addressOf.keys.toList()
        : <int>[if (_addressOf.containsKey(dest)) dest];

    if (targets.isEmpty) {
      logError('No resolved endpoint for ${describeDest(dest)}', _tag);
      return false;
    }

    final bytes = utf8.encode(message.encode());
    logSnt('→ ${describeDest(dest)}  ${message.encode()}', _tag);

    var delivered = 0;
    for (final id in targets) {
      final addr = _addressOf[id]!;
      final port = config.endpointFor(id)!.port;
      try {
        final n = socket.send(bytes, addr, port);
        logTrace(_tag, 'TX ${addr.address}:$port ${n}B ${message.type} q=${message.seq}');
        if (n > 0) delivered++;
      } catch (e) {
        logError('Send to ${addr.address}:$port failed: $e', _tag);
      }
    }

    return delivered > 0; // handed to the OS; delivery is proven by the Layer 2 ACK
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;

    final source = datagram.address.address;
    final droneId = _droneAt[source]; // identity comes from the source address
    logTrace(_tag, 'RX $source:${datagram.port} ${datagram.data.length}B');

    if (droneId == null) {
      _warnAboutStranger(source, datagram.data.length);
      return;
    }

    final text = utf8.decode(datagram.data, allowMalformed: true);
    try {
      final message = MissionMessage.decode(text);
      logRx('← drone $droneId  $text', _tag);
      logTrace(_tag, 'decoded ${message.type} q=${message.seq} from=$droneId');
      if (!_missionCtl.isClosed) _missionCtl.add(IncomingMission(droneId, message));
    } on UnsupportedMessageTypeException catch (e) {
      logWarn('Unsupported message from drone $droneId: ${e.messageType}', _tag);
    } on MissionMessageException catch (e) {
      logError('Bad payload from drone $droneId: ${e.message}', _tag);
      logTrace(_tag, 'raw payload: ${sanitizeForLog(text)}');
    }
  }

  /// The listen port is open to the whole network, so an unmapped sender is
  /// untrusted: never log its payload, and warn at most once a minute per host
  /// so a flood cannot bury the log.
  void _warnAboutStranger(String source, int length) {
    final now = DateTime.now();
    final last = _lastStrangerWarning[source];
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      logTrace(_tag, 'ignored ${length}B from unmapped $source');
      return;
    }
    _lastStrangerWarning[source] = now;
    logWarn('Ignoring ${length}B from unmapped host $source '
        '— check the endpoint config', _tag);
  }

  @override
  Future<void> disconnect() async {
    if (_socket == null && _state == LinkState.disconnected) return;
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
    _addressOf.clear();
    _droneAt.clear();
    _lastStrangerWarning.clear();
    _setState(LinkState.disconnected, 'Disconnected');
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _stateCtl.close();
    await _statusCtl.close();
    await _missionCtl.close();
  }
}
