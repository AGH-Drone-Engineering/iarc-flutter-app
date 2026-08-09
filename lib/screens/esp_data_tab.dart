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
          const _AckSection(),
          const SizedBox(height: 16),
          const _DebugSection(),
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

class _AckSection extends StatelessWidget {
  const _AckSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final worst = app.config.worstCaseWait.inMilliseconds / 1000;

    return _Card(
      title: 'ACK & retries',
      subtitle: 'How long a command waits for the drone to acknowledge it, and '
          'how many times it is resent on the same sequence number. Applies to '
          'every message, on either transport.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _NumberField(
                  label: 'ACK timeout',
                  suffix: 'ms',
                  value: app.config.ackTimeoutMs,
                  min: kAckTimeoutMsRange.min,
                  max: kAckTimeoutMsRange.max,
                  onChanged: app.setAckTimeoutMs,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _NumberField(
                  label: 'Attempts',
                  value: app.config.maxAttempts,
                  min: kMaxAttemptsRange.min,
                  max: kMaxAttemptsRange.max,
                  onChanged: app.setMaxAttempts,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _kv(context, 'Silent drone reported after',
              '${worst.toStringAsFixed(1)} s'),
        ],
      ),
    );
  }
}

class _DebugSection extends StatelessWidget {
  const _DebugSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final debug = app.debug;
    final running = debug.isRunning;

    return _Card(
      title: 'Debug traffic',
      subtitle: 'Fires STATUS on a loop down the real command path — same '
          'sequence counter, same ACKs and retries. Ties up the link on '
          'purpose; nothing flies.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _NumberField(
            label: 'Interval',
            suffix: 'ms',
            value: debug.interval.inMilliseconds,
            min: 50,
            max: 60000,
            onChanged: (ms) => debug.setInterval(Duration(milliseconds: ms)),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: (!app.isConnected && !running)
                ? null
                : () => running
                    ? debug.stop()
                    : debug.start(dest: app.selectedTarget),
            icon: Icon(running ? Icons.stop : Icons.play_arrow),
            label: Text(running ? 'Stop' : 'Start'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              backgroundColor: running ? scheme.error : null,
              foregroundColor: running ? scheme.onError : null,
            ),
          ),
          const SizedBox(height: 12),
          _kv(context, 'Target',
              app.transport.describeDest(running ? debug.dest : app.selectedTarget)),
          _kv(context, 'Sent', '${debug.sent}'),
          _kv(context, 'Skipped, link still busy', '${debug.skipped}'),
        ],
      ),
    );
  }
}

/// Commits on submit or on losing focus, never per keystroke: applying every
/// intermediate value would run the debug loop at 5 ms on the way to typing
/// 500.
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.suffix,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final String? suffix;
  final ValueChanged<int> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _controller = TextEditingController(text: '${widget.value}');
  late final _focus = FocusNode()..addListener(_onFocusChanged);

  @override
  void didUpdateWidget(_NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && !_focus.hasFocus) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text.trim()) ?? widget.value;
    final clamped = parsed.clamp(widget.min, widget.max);
    _controller.text = '$clamped';
    if (clamped != widget.value) widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _commit(),
      decoration: InputDecoration(
        labelText: widget.label,
        suffixText: widget.suffix,
        isDense: true,
        border: const OutlineInputBorder(),
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
