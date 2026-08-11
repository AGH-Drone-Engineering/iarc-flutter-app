import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drone.dart';
import '../models/mission_message.dart';
import '../services/demo_runner.dart';
import '../state/app_state.dart';
import '../state/mission_limits.dart';
import '../widgets/connection_bar.dart';
import '../widgets/drone_visuals.dart';
import '../widgets/mine_identity.dart';
import '../widgets/number_stepper.dart';
import '../widgets/section_card.dart';
import '../widgets/voice_control.dart';
import 'status_screen.dart';

class MissionTab extends StatelessWidget {
  const MissionTab({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const ConnectionBar(),
          if (app.tracker.failures.isNotEmpty) const _LatestFailureLine(),
          const SizedBox(height: 12),
          const VoiceControl(),
          const SizedBox(height: 16),
          const _FleetSection(),
          const SizedBox(height: 20),
          const _MissionStartSection(),
          const SizedBox(height: 20),
          const _RecoverySection(),
          if (app.mines.isNotEmpty) ...[
            const SizedBox(height: 20),
            const _MineStrip(),
          ],
        ],
      ),
    );
  }
}

/// The newest ACK failure as a single line. The full history lives in the Logs
/// tab, the full detail and the retry controls on the status screen.
class _LatestFailureLine extends StatelessWidget {
  const _LatestFailureLine();

  @override
  Widget build(BuildContext context) {
    final failures = context.watch<AppState>().tracker.failures;
    if (failures.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final latest = failures.first;
    final older = failures.length - 1;
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: scheme.error);

    return InkWell(
      onTap: () => StatusScreen.open(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: scheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${Drone.nameFor(latest.droneId)}: ${latest.description}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (older > 0) Text(' +$older', style: style),
            Icon(Icons.chevron_right, size: 16, color: scheme.error),
          ],
        ),
      ),
    );
  }
}

/// Doubles as the command target selector: the tile you pick is the drone
/// every button on this screen addresses.
class _FleetSection extends StatelessWidget {
  const _FleetSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final drones = app.drones;

    return SectionCard(
      title: 'Fleet',
      trailing: TextButton.icon(
        onPressed: () => StatusScreen.open(context),
        icon: const Icon(Icons.open_in_new, size: 16),
        label: const Text('Status'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TargetTile(
            selected: app.selectedTarget == kBroadcastAddress,
            onTap: () => app.setSelectedTarget(kBroadcastAddress),
            child: Row(
              children: [
                const Icon(Icons.groups, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    Drone.nameFor(kBroadcastAddress),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  'broadcast',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < drones.length; i += 2)
            Padding(
              padding: EdgeInsets.only(bottom: i + 2 < drones.length ? 8 : 0),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _FleetCell(drone: drones[i])),
                    const SizedBox(width: 8),
                    Expanded(
                      child: i + 1 < drones.length
                          ? _FleetCell(drone: drones[i + 1])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: selected
          ? scheme.secondaryContainer
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? scheme.primary : Colors.transparent,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: child,
        ),
      ),
    );
  }
}

class _FleetCell extends StatelessWidget {
  const _FleetCell({required this.drone});

  final Drone drone;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final stateColor = droneStateColor(
      drone,
      scheme,
      failure: app.tracker.failureFor(drone.id),
    );
    final progress = app.demo.progressFor(drone.id);

    return _TargetTile(
      selected: app.selectedTarget == drone.id,
      onTap: () => app.setSelectedTarget(drone.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              DroneBadge(color: drone.color, radius: 5),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  drone.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (app.tracker.isAwaitingAck(drone.id))
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: scheme.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Flexible(
                child: Text(
                  drone.hasEverReported ? drone.state.wire : 'no telemetry',
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall
                      ?.copyWith(color: stateColor, fontWeight: FontWeight.w700),
                ),
              ),
              if (drone.battery != null) ...[
                const SizedBox(width: 6),
                Text(
                  '${drone.battery!.toStringAsFixed(1)} V',
                  style: text.labelSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(
                  demoPhaseIcon(progress.phase),
                  size: 12,
                  color: demoPhaseColor(progress.phase, scheme),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    progress.phase == DemoPhase.stepping
                        ? 'step ${progress.steps}'
                        : demoPhaseLabel(progress.phase),
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall?.copyWith(
                      color: demoPhaseColor(progress.phase, scheme),
                    ),
                  ),
                ),
              ],
            ),
          ],
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

    return SectionCard(
      title: 'Start mission',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NumberStepper(
            label: 'Demo hover altitude',
            value: app.demoAltitude,
            min: demoAltitudeRange.min,
            max: demoAltitudeRange.max,
            step: demoAltitudeRange.step,
            unit: 'm',
            onChanged: app.setDemoAltitude,
          ),
          const SizedBox(height: 8),
          NumberStepper(
            label: 'Figure vertices',
            value: app.demoVertices.toDouble(),
            min: demoVerticesRange.min,
            max: demoVerticesRange.max,
            step: demoVerticesRange.step,
            unit: '',
            onChanged: app.setDemoVertices,
          ),
          const SizedBox(height: 8),
          NumberStepper(
            label: 'Figure radius',
            value: app.demoRadius,
            min: demoRadiusRange.min,
            max: demoRadiusRange.max,
            step: demoRadiusRange.step,
            unit: 'm',
            onChanged: app.setDemoRadius,
          ),
          const SizedBox(height: 8),
          NumberStepper(
            label: 'Settle on vertex',
            value: app.demoSettleSeconds,
            min: demoSettleRange.min,
            max: demoSettleRange.max,
            step: demoSettleRange.step,
            unit: 's',
            onChanged: app.setDemoSettle,
          ),
          const Divider(height: 24),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Lockstep formation'),
            subtitle: Text(
              app.demoLockstep
                  ? 'All drones step together'
                  : 'Independent, collision-checked',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: app.demoLockstep,
            onChanged: app.demo.isRunning
                ? null
                : (v) => app.setDemoLockstep(v),
          ),
          if (!app.demoLockstep) ...[
            const SizedBox(height: 4),
            NumberStepper(
              label: 'Clearance',
              value: app.demoClearance,
              min: demoClearanceRange.min,
              max: demoClearanceRange.max,
              step: demoClearanceRange.step,
              unit: 'm',
              onChanged: app.setDemoClearance,
            ),
            const SizedBox(height: 4),
            Text(
              app.worstReportedAccuracy == null
                  ? 'no fix accuracy reported'
                  : 'worst fix '
                      '±${app.worstReportedAccuracy!.toStringAsFixed(1)} m',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ],
          const SizedBox(height: 8),
          if (app.demo.isRunning) ...[
            _MusterRoster(app: app),
            const SizedBox(height: 8),
            if (app.demo.isMustering)
              Builder(builder: (context) {
                final fault = app.demo.separationFault;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (fault != null)
                      _Warning(text: fault),
                    FilledButton.icon(
                      onPressed: app.demo.mustered.isEmpty || fault != null
                          ? null
                          : () {
                              final refusal = app.beginFormation();
                              if (refusal != null && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(refusal)));
                              }
                            },
                      icon: const Icon(Icons.play_arrow),
                      label: Text('BEGIN FORMATION '
                          '(${app.demo.mustered.length} ready)'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ],
                );
              }),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: app.stopDemo,
              icon: const Icon(Icons.stop),
              label: Text(app.demo.isMustering ? 'CANCEL' : 'STOP DEMO'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: Theme.of(context).colorScheme.tertiary,
              ),
            ),
          ] else ...[
            _RosterPicker(app: app),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: enabled ? () => app.startDemo() : null,
              icon: const Icon(Icons.flight_takeoff),
              label: const Text('MUSTER DRONES'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ],
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          NumberStepper(
            label: 'Main search altitude',
            value: app.mainAltitude,
            min: mainAltitudeRange.min,
            max: mainAltitudeRange.max,
            step: mainAltitudeRange.step,
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

class _RecoverySection extends StatelessWidget {
  const _RecoverySection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final enabled = app.isConnected;

    return SectionCard(
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
        ],
      ),
    );
  }
}

/// One badge per mine, coloured by the drone that reported it. Coordinates are
/// on the map, on the status screen and in the log.
class _MineStrip extends StatelessWidget {
  const _MineStrip();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SectionCard(
      title: 'Mines detected',
      trailing: Text(
        '${app.mines.length}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final m in app.mines) MineIdentity(mine: m)],
        ),
      ),
    );
  }
}

/// Which drones a demo is for, chosen before mustering.
///
/// An arbitrary subset, not "one or all": which airframes are on the field
/// changes between tests, and addressing drones that are switched off spends
/// uplink airtime on frames that can never be answered.
class _RosterPicker extends StatelessWidget {
  const _RosterPicker({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Drones in this demo',
            style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final d in app.drones)
              FilterChip(
                label: Text(d.name),
                selected: app.demoRoster.contains(d.id),
                showCheckmark: false,
                avatar: DroneBadge(color: d.color, radius: 5),
                onSelected: (_) => app.toggleDemoRoster(d.id),
              ),
          ],
        ),
      ],
    );
  }
}

/// Per-drone state during a muster, with a retry for whoever did not come up.
class _MusterRoster extends StatelessWidget {
  const _MusterRoster({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = app.demo.progress.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(app.demo.isMustering ? 'Mustering' : 'Flying the figure',
            style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(
                  switch (e.value.phase) {
                    DemoPhase.holding => Icons.check_circle,
                    DemoPhase.starting => Icons.flight_takeoff,
                    DemoPhase.stepping => Icons.navigation,
                    DemoPhase.landing => Icons.flight_land,
                    DemoPhase.finished => Icons.done_all,
                    DemoPhase.stopped => Icons.cancel,
                  },
                  size: 16,
                  color: switch (e.value.phase) {
                    DemoPhase.holding => scheme.primary,
                    DemoPhase.landing || DemoPhase.stopped => scheme.error,
                    _ => scheme.onSurfaceVariant,
                  },
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    () {
                      final off = app.demo.altitudeOverrideFor(e.key);
                      final base =
                          '${Drone.nameFor(e.key)} — ${e.value.detail ?? e.value.phase.name}';
                      return off == null
                          ? base
                          : '$base · joining at ${off.toStringAsFixed(1)}m';
                    }(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                // Only once it is actually walking the figure: merging a drone
                // that is still climbing would drop its offset before it has a
                // vertex to hold.
                if (app.demo.altitudeOverrideFor(e.key) != null &&
                    e.value.phase != DemoPhase.starting)
                  TextButton(
                    onPressed: () => app.mergeIntoFormation(e.key),
                    child: const Text('MERGE'),
                  ),
                // Only offer a retry for a drone that never got up, and only
                // while mustering -- adding one to a moving figure would put it
                // a vertex out of phase with everybody else.
                if (!e.value.isActive)
                  TextButton(
                    onPressed: () => app.retryStart(e.key),
                    child: Text(app.demo.isMustering ? 'RETRY' : 'JOIN'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
