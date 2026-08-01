import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:usb_serial/usb_serial.dart';

import '../models/drone.dart';
import '../services/link_service.dart';
import '../services/lora_frame.dart';
import '../state/app_state.dart';

class EspDataTab extends StatefulWidget {
  const EspDataTab({super.key});

  @override
  State<EspDataTab> createState() => _EspDataTabState();
}

class _EspDataTabState extends State<EspDataTab>
    with AutomaticKeepAliveClientMixin {
  List<UsbDevice> _devices = [];
  UsbDevice? _selected;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Drone.ensureRegistered();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDevices());
  }

  Future<void> _refreshDevices() async {
    final devices = await context.read<AppState>().link.listDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      if (!_devices.contains(_selected)) {
        _selected = _devices.isNotEmpty ? _devices.first : null;
      }
    });
  }

  Future<void> _connect() async {
    final device = _selected;
    if (device == null) return;
    setState(() => _busy = true);
    await context.read<AppState>().link.connect(device);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await context.read<AppState>().link.disconnect();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final app = context.watch<AppState>();
    final connected = app.isConnected;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Ground station link',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<UsbDevice>(
                          isExpanded: true,
                          initialValue: _selected,
                          hint: const Text('Select USB device'),
                          decoration: const InputDecoration(
                            labelText: 'Device',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final d in _devices)
                              DropdownMenuItem(
                                value: d,
                                child: Text(
                                  d.productName ?? d.deviceName,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: connected
                              ? null
                              : (d) => setState(() => _selected = d),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Refresh devices',
                        onPressed: _busy ? null : _refreshDevices,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              (_selected == null || connected || _busy) ? null : _connect,
                          icon: const Icon(Icons.usb),
                          label: const Text('Connect'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: (!connected || _busy) ? null : _disconnect,
                          icon: const Icon(Icons.link_off),
                          label: const Text('Disconnect'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        connected ? Icons.check_circle : Icons.circle_outlined,
                        size: 18,
                        color: connected
                            ? Colors.green
                            : Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(app.connectionStatus,
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _LinkDetails(link: app.link),
          const SizedBox(height: 16),
          const _ProtocolNote(),
        ],
      ),
    );
  }
}

class _LinkDetails extends StatelessWidget {
  const _LinkDetails({required this.link});

  final LinkService link;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Transport', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _row(context, 'Protocol', 'LoRaCom frames, 115200 8N1'),
            _row(context, 'Poll interval', '${link.pollInterval.inMilliseconds} ms'),
            _row(context, 'Reply timeout',
                '${link.transactionTimeout.inMilliseconds} ms × ${link.maxAttempts}'),
            _row(context, 'Ground ESP address',
                link.groundNodeId == null ? 'unknown' : '#${link.groundNodeId}'),
            _row(context, 'Max payload', '$kMaxMessageSize bytes'),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
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
}

class _ProtocolNote extends StatelessWidget {
  const _ProtocolNote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'The HAT bridges LoRaCom on GPIO17/18, not on USB-CDC. Until the '
              'firmware also bridges USB, connect through a USB-UART adapter '
              'wired to those pins. See PROTOCOL.md §1.1.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
