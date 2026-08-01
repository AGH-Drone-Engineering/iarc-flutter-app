import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drone.dart';
import '../models/mission_message.dart';
import '../services/demo_runner.dart';
import '../state/app_state.dart';
import '../widgets/ack_alert_banner.dart';
import '../widgets/drone_status_tile.dart';
import '../widgets/hold_to_confirm_button.dart';
import '../widgets/voice_control.dart';

class MissionTab extends StatelessWidget {
  const MissionTab({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          if (app.tracker.failures.isNotEmpty) ...[
            AckAlertBanner(
              failures: app.tracker.failures,
              onDismiss: app.tracker.dismissFailure,
              onRetryStatus: (id) => app.requestStatus(target: id),
            ),
            const SizedBox(height: 16),
          ],
          const _ConnectionBar(),
          const SizedBox(height: 12),
          const VoiceControl(),
          const SizedBox(height: 16),
          const _TargetSelector(),
          const SizedBox(height: 20),
          const _MissionStartSection(),
          const SizedBox(height: 20),
          const _DemoSequenceSection(),
          const SizedBox(height: 20),
          const _DemoControlSection(),
          const SizedBox(height: 20),
          const _RecoverySection(),
          const SizedBox(height: 24),
          const _FleetStatusSection(),
          if (app.mines.isNotEmpty) ...[
            const SizedBox(height: 24),
            const _MineList(),
          ],
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final connected = app.isConnected;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: connected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            connected ? Icons.usb : Icons.usb_off,
            size: 20,
            color: connected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              app.connectionStatus,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:
                    connected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (app.link.groundNodeId != null)
            Text(
              'ESP #${app.link.groundNodeId}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}

class _TargetSelector extends StatelessWidget {
  const _TargetSelector();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return _SectionCard(
      title: 'Target',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            label: const Text('All drones'),
            avatar: const Icon(Icons.groups, size: 18),
            selected: app.selectedTarget == kBroadcastAddress,
            onSelected: (_) => app.setSelectedTarget(kBroadcastAddress),
          ),
          for (final d in app.drones)
            ChoiceChip(
              label: Text(d.name),
              avatar: CircleAvatar(backgroundColor: d.color, radius: 8),
              selected: app.selectedTarget == d.id,
              onSelected: (_) => app.setSelectedTarget(d.id),
            ),
        ],
      ),
    );
  }
}

class _MissionStartSection extends StatelessWidget {
  const _MissionStartSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final enabled = app.isConnected;
    final cornerCount = app.filledCorners.length;

    return _SectionCard(
      title: 'Start mission',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _NumberStepper(
            label: 'Demo hover altitude',
            value: app.demoAltitude,
            min: 0.5,
            max: 30.0,
            step: 0.5,
            unit: 'm',
            onChanged: app.setDemoAltitude,
          ),
          const SizedBox(height: 8),
          if (app.demo.isRunning)
            FilledButton.icon(
              onPressed: app.stopDemo,
              icon: const Icon(Icons.stop),
              label: const Text('STOP DEMO'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: Theme.of(context).colorScheme.tertiary,
              ),
            )
          else
            FilledButton.icon(
              onPressed: enabled ? () => app.startDemo() : null,
              icon: const Icon(Icons.flight_takeoff),
              label: const Text('START DEMO'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          _NumberStepper(
            label: 'Main search altitude',
            value: app.mainAltitude,
            min: 1.0,
            max: 30.0,
            step: 0.5,
            unit: 'm',
            onChanged: app.setMainAltitude,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                cornerCount == 4 ? Icons.check_circle : Icons.error_outline,
                size: 18,
                color: cornerCount == 4
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cornerCount == 4
                      ? 'Field corners set'
                      : '$cornerCount/4 field corners set — enter them in the Inputs tab',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: enabled && cornerCount == 4
                ? () async {
                    final ok = await app.startMain();
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Set all 4 field corners first')),
                      );
                    }
                  }
                : null,
            icon: const Icon(Icons.grid_on),
            label: const Text('START MAIN'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ),
    );
  }
}

class _DemoSequenceSection extends StatelessWidget {
  const _DemoSequenceSection();

  static const _icons = <DemoPhase, IconData>{
    DemoPhase.starting: Icons.flight_takeoff,
    DemoPhase.stepping: Icons.directions_run,
    DemoPhase.returning: Icons.home,
    DemoPhase.finished: Icons.check_circle,
    DemoPhase.stopped: Icons.pause_circle,
  };

  static const _labels = <DemoPhase, String>{
    DemoPhase.starting: 'taking off',
    DemoPhase.stepping: 'running',
    DemoPhase.returning: 'returning home',
    DemoPhase.finished: 'finished',
    DemoPhase.stopped: 'stopped',
  };

  Color _color(DemoPhase phase, ColorScheme scheme) => switch (phase) {
        DemoPhase.returning => scheme.error,
        DemoPhase.finished => Colors.green,
        DemoPhase.stopped => scheme.outline,
        _ => scheme.primary,
      };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final entries = app.demo.progress.values.toList()
      ..sort((a, b) => a.droneId.compareTo(b.droneId));

    if (entries.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;

    return _SectionCard(
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
                  Icon(_icons[p.phase], size: 18, color: _color(p.phase, scheme)),
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
                          p.detail ?? _labels[p.phase]!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: _color(p.phase, scheme),
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

class _DemoControlSection extends StatelessWidget {
  const _DemoControlSection();

  static const _layout = <List<MoveDirection?>>[
    [MoveDirection.forwardLeft, MoveDirection.forward, MoveDirection.forwardRight],
    [MoveDirection.left, null, MoveDirection.right],
    [MoveDirection.backLeft, MoveDirection.back, MoveDirection.backRight],
  ];

  static const _icons = <MoveDirection, IconData>{
    MoveDirection.forward: Icons.arrow_upward,
    MoveDirection.back: Icons.arrow_downward,
    MoveDirection.left: Icons.arrow_back,
    MoveDirection.right: Icons.arrow_forward,
    MoveDirection.forwardLeft: Icons.north_west,
    MoveDirection.forwardRight: Icons.north_east,
    MoveDirection.backLeft: Icons.south_west,
    MoveDirection.backRight: Icons.south_east,
  };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final enabled = app.isConnected;

    return _SectionCard(
      title: 'Manual movement',
      trailing: Text(
        'body frame',
        style: Theme.of(context).textTheme.labelSmall,
      ),
      child: Column(
        children: [
          _NumberStepper(
            label: 'Step distance',
            value: app.stepDistance,
            min: 0.5,
            max: 20.0,
            step: 0.5,
            unit: 'm',
            onChanged: app.setStepDistance,
          ),
          const SizedBox(height: 12),
          for (final row in _layout)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  for (final dir in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: dir == null
                            ? Center(
                                child: Text(
                                  '${app.stepDistance.toStringAsFixed(1)} m',
                                  style: Theme.of(context).textTheme.labelMedium,
                                ),
                              )
                            : OutlinedButton(
                                onPressed:
                                    enabled ? () => app.move(dir) : null,
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                ),
                                child: Icon(_icons[dir]),
                              ),
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

class _RecoverySection extends StatelessWidget {
  const _RecoverySection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final enabled = app.isConnected;
    final scheme = Theme.of(context).colorScheme;

    return _SectionCard(
      title: 'Recovery',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled ? () => app.land() : null,
                  icon: const Icon(Icons.flight_land),
                  label: const Text('LAND'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled ? () => app.returnHome() : null,
                  icon: const Icon(Icons.home),
                  label: const Text('RTH'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                onPressed: enabled ? () => app.requestStatus() : null,
                tooltip: 'Request status',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 20),
          HoldToConfirmButton(
            label: 'KILL',
            holdingLabel: 'Hold to cut motors…',
            icon: Icons.dangerous,
            color: scheme.error,
            onConfirmed: enabled ? () => app.kill() : null,
          ),
          const SizedBox(height: 8),
          Text(
            'Cuts motors on ${Drone.nameFor(app.selectedTarget)}. '
            'Sent 3× without waiting for an ACK.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _FleetStatusSection extends StatelessWidget {
  const _FleetStatusSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return _SectionCard(
      title: 'Fleet',
      child: Column(
        children: [
          for (final d in app.drones)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DroneStatusTile(
                drone: d,
                awaitingAck: app.tracker.isAwaitingAck(d.id),
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

class _MineList extends StatelessWidget {
  const _MineList();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return _SectionCard(
      title: 'Mines detected',
      trailing: Text('${app.mines.length}',
          style: Theme.of(context).textTheme.titleMedium),
      child: Column(
        children: [
          for (final m in app.mines)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: Drone.byId(m.reportedBy)?.color,
                child: Text('${m.tag}', style: const TextStyle(fontSize: 12)),
              ),
              title: Text(
                '${m.position.latitude.toStringAsFixed(7)}, '
                '${m.position.longitude.toStringAsFixed(7)}',
                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
              ),
              subtitle: Text('by ${Drone.nameFor(m.reportedBy)}'),
            ),
        ],
      ),
    );
  }
}

class _NumberStepper extends StatelessWidget {
  const _NumberStepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.unit,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double step;
  final String unit;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          onPressed: value > min
              ? () => onChanged((value - step).clamp(min, max))
              : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        SizedBox(
          width: 64,
          child: Text(
            '${value.toStringAsFixed(1)} $unit',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        IconButton(
          onPressed: value < max
              ? () => onChanged((value + step).clamp(min, max))
              : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}
