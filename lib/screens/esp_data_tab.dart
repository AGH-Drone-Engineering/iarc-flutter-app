import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:usb_serial/usb_serial.dart';

import '../models/drone.dart';
import '../models/link_config.dart';
import '../services/lora_frame.dart';
import '../services/mission_transport.dart';
import '../state/app_state.dart';

class EspDataTab extends StatefulWidget {
  const EspDataTab({super.key});

  @override
  State<EspDataTab> createState() => _EspDataTabState();
}

class _EspDataTabState extends State<EspDataTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Drone.ensureRegistered();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final app = context.watch<AppState>();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _TransportSelector(),
          const SizedBox(height: 16),
          if (app.config.transport == TransportKind.lora)
            const _LoraSection()
          else
            const _UdpSection(),
          const SizedBox(height: 16),
          const _StatusRow(),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _TransportSelector extends StatelessWidget {
  const _TransportSelector();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return _Card(
      title: 'Transport',
      subtitle: 'Same mission protocol either way — only the link differs.',
      child: SegmentedButton<TransportKind>(
        segments: const [
          ButtonSegment(
            value: TransportKind.lora,
            icon: Icon(Icons.usb),
            label: Text('LoRa'),
          ),
          ButtonSegment(
            value: TransportKind.udp,
            icon: Icon(Icons.wifi),
            label: Text('UDP'),
          ),
        ],
        selected: {app.config.transport},
        onSelectionChanged: (s) => app.setTransport(s.first),
      ),
    );
  }
}

class _LoraSection extends StatefulWidget {
  const _LoraSection();

  @override
  State<_LoraSection> createState() => _LoraSectionState();
}

class _LoraSectionState extends State<_LoraSection> {
  List<UsbDevice> _devices = [];
  UsbDevice? _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final devices = await context.read<AppState>().lora.listDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      if (!_devices.contains(_selected)) {
        _selected = _devices.isNotEmpty ? _devices.first : null;
      }
    });
  }

  Future<void> _toggle(bool connected) async {
    setState(() => _busy = true);
    final app = context.read<AppState>();
    if (connected) {
      await app.lora.disconnect();
    } else if (_selected != null) {
      await app.lora.connect(_selected!);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final connected = app.lora.isConnected;

    return _Card(
      title: 'LoRa over USB',
      subtitle: 'The HAT bridges LoRaCom on GPIO17/18, not USB-CDC — use a '
          'USB-UART adapter onto those pins.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<UsbDevice>(
                  isExpanded: true,
                  initialValue: _selected,
                  hint: const Text('Select USB device'),
                  decoration: const InputDecoration(
                    labelText: 'Device',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final d in _devices)
                      DropdownMenuItem(
                        value: d,
                        child: Text(d.productName ?? d.deviceName,
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged:
                      connected ? null : (d) => setState(() => _selected = d),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh devices',
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: (_busy || (_selected == null && !connected))
                ? null
                : () => _toggle(connected),
            icon: Icon(connected ? Icons.link_off : Icons.usb),
            label: Text(connected ? 'Disconnect' : 'Connect'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          ),
          const SizedBox(height: 12),
          _kv(context, 'Framing', 'LoRaCom, 115200 8N1'),
          _kv(context, 'Poll interval', '${app.lora.pollInterval.inMilliseconds} ms'),
          _kv(context, 'Reply timeout',
              '${app.lora.transactionTimeout.inMilliseconds} ms × ${app.lora.maxAttempts}'),
          _kv(context, 'Max payload', '$kMaxMessageSize bytes'),
          _kv(context, 'Ground ESP',
              app.lora.groundNodeId == null ? 'unknown' : '#${app.lora.groundNodeId}'),
        ],
      ),
    );
  }
}

class _UdpSection extends StatefulWidget {
  const _UdpSection();

  @override
  State<_UdpSection> createState() => _UdpSectionState();
}

class _UdpSectionState extends State<_UdpSection> {
  final _listenCtrl = TextEditingController();
  final Map<int, TextEditingController> _hostCtrls = {};
  final Map<int, TextEditingController> _portCtrls = {};
  bool _busy = false;
  bool _seeded = false;

  @override
  void dispose() {
    _listenCtrl.dispose();
    for (final c in [..._hostCtrls.values, ..._portCtrls.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _seed(LinkConfig config) {
    if (_seeded) return;
    _seeded = true;
    _listenCtrl.text = '${config.listenPort}';
    for (final ep in config.endpoints) {
      _hostCtrls[ep.droneId] = TextEditingController(text: ep.host);
      _portCtrls[ep.droneId] = TextEditingController(text: '${ep.port}');
    }
  }

  Future<void> _apply(AppState app) async {
    final listen = int.tryParse(_listenCtrl.text.trim());
    if (listen != null) await app.setUdpListenPort(listen);

    for (final ep in app.config.endpoints) {
      await app.setUdpEndpoint(
        ep.droneId,
        host: _hostCtrls[ep.droneId]?.text.trim(),
        port: int.tryParse(_portCtrls[ep.droneId]?.text.trim() ?? ''),
      );
    }
  }

  Future<void> _toggle(AppState app, bool connected) async {
    setState(() => _busy = true);
    if (connected) {
      await app.udp.disconnect();
    } else {
      await _apply(app);
      final ok = await app.connectUdp();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('UDP link failed — see the Logs tab')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    _seed(app.config);
    final connected = app.udp.isConnected;
    final reachable = app.udp.reachableDrones;

    return _Card(
      title: 'UDP over Wi-Fi',
      subtitle: 'Direct to each Pi, bypassing the ESP. One message per datagram; '
          'hostnames resolve on connect.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _listenCtrl,
            enabled: !connected,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Local listen port',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          Text('Drone endpoints', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          for (final ep in app.config.endpoints) ...[
            Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Icon(
                    reachable.contains(ep.droneId)
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    size: 16,
                    color: reachable.contains(ep.droneId)
                        ? Colors.green
                        : Theme.of(context).colorScheme.outline,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostCtrls[ep.droneId],
                    enabled: !connected,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: Drone.nameFor(ep.droneId),
                      hintText: 'host or IP',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _portCtrls[ep.droneId],
                    enabled: !connected,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'port',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: _busy ? null : () => _toggle(app, connected),
            icon: Icon(connected ? Icons.link_off : Icons.wifi),
            label: Text(connected ? 'Disconnect' : 'Connect'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          ),
          if (connected) ...[
            const SizedBox(height: 12),
            _kv(context, 'Bound', '0.0.0.0:${app.udp.listenPort}'),
            _kv(context, 'Reachable',
                reachable.isEmpty ? 'none' : reachable.map(Drone.nameFor).join(', ')),
          ],
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final connected = app.isConnected;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: connected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            connected ? Icons.check_circle : Icons.circle_outlined,
            size: 18,
            color: connected ? scheme.onPrimaryContainer : scheme.outline,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              app.connectionStatus,
              style: TextStyle(
                color: connected ? scheme.onPrimaryContainer : null,
              ),
            ),
          ),
          Text(
            app.config.transport.label,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

Widget _kv(BuildContext context, String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
