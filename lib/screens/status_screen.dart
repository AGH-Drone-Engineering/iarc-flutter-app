import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drone.dart';
import '../state/app_state.dart';
import '../widgets/ack_alert_banner.dart';
import '../widgets/connection_bar.dart';
import '../widgets/drone_status_tile.dart';
import '../widgets/drone_visuals.dart';
import '../widgets/mine_identity.dart';
import '../widgets/section_card.dart';

/// Everything the mission tab deliberately keeps off screen: full telemetry,
/// the ACK failure detail, demo progress and raw `MOVE` control.
class StatusScreen extends StatelessWidget {
  const StatusScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const StatusScreen()),
      );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(title: const Text('Status')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            const ConnectionBar(),
            const SizedBox(height: 16),
            if (app.tracker.failures.isNotEmpty) ...[
              const _AlertsSection(),
              const SizedBox(height: 16),
            ],
            const _FleetSection(),
            if (app.demo.progress.isNotEmpty) ...[
              const SizedBox(height: 16),
              const _DemoSequenceSection(),
            ],
            const SizedBox(height: 16),
              if (app.mines.isNotEmpty) ...[
              const SizedBox(height: 16),
              const _DetectionsSection(),
            ],
          ],
        ),
      ),
    );
  }
}

class _AlertsSection extends StatelessWidget {
  const _AlertsSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SectionCard(
      title: 'Alerts',
      trailing: TextButton(
        onPressed: app.tracker.dismissAll,
        child: const Text('Dismiss all'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AckAlertBanner(
            failures: app.tracker.failures,
            onDismiss: app.tracker.dismissFailure,
            onRetryStatus: (id) => app.requestStatus(target: id),
          ),
          Text(
            'Every failure is also written to the Logs tab.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _FleetSection extends StatelessWidget {
  const _FleetSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SectionCard(
      title: 'Fleet',
      trailing: IconButton(
        onPressed: app.isConnected ? () => app.requestStatus() : null,
        tooltip: 'Request status',
        icon: const Icon(Icons.refresh),
      ),
      child: Column(
        children: [
          for (final d in app.drones)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DroneStatusTile(
                drone: d,
                awaitingAck: false,
                failure: app.tracker.failureFor(d.id),
                onTap: () => app.setSelectedTarget(d.id),
                selected: app.selectedTarget == d.id,
              ),
            ),
        ],
      ),
    );
  }
}

class _DemoSequenceSection extends StatelessWidget {
  const _DemoSequenceSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final entries = app.demo.progress.values.toList()
      ..sort((a, b) => a.droneId.compareTo(b.droneId));
    final scheme = Theme.of(context).colorScheme;

    return SectionCard(
      title: 'Demo sequence',
      trailing: app.demo.isRunning
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: app.demo.clear,
              child: const Text('Clear'),
            ),
      child: Column(
        children: [
          for (final p in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(
                    demoPhaseIcon(p.phase),
                    size: 18,
                    color: demoPhaseColor(p.phase, scheme),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          Drone.nameFor(p.droneId),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          p.detail ?? demoPhaseLabel(p.phase),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: demoPhaseColor(p.phase, scheme),
                              ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    'step ${p.steps}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DetectionsSection extends StatelessWidget {
  const _DetectionsSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SectionCard(
      title: 'Mines detected',
      trailing: Text(
        '${app.mines.length}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      child: Column(
        children: [
          for (final m in app.mines)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: MineIdentity(mine: m, radius: 14),
              title: Text(
                '${m.position.latitude.toStringAsFixed(7)}, '
                '${m.position.longitude.toStringAsFixed(7)}',
                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
              ),
              subtitle: Text('${m.name} · by ${Drone.nameFor(m.reportedBy)}'),
            ),
        ],
      ),
    );
  }
}
