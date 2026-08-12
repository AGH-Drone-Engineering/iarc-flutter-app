import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drone.dart';
import '../services/demo_runner.dart';
import '../state/app_state.dart';
import '../state/mission_limits.dart';
import '../widgets/connection_bar.dart';
import '../widgets/drone_visuals.dart';
import '../widgets/number_stepper.dart';
import '../widgets/section_card.dart';

/// The demo mission, on its own.
///
/// It used to share the Mission tab with `START_MAIN` and the recovery buttons,
/// which put the figure's four steppers between the operator and the two
/// controls that matter when something is going wrong. The demo is also the only
/// mode that is flown one drone at a time -- everything here is per-drone, and
/// that needs the room.
class DemoTab extends StatelessWidget {
  const DemoTab({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const ConnectionBar(),
          const SizedBox(height: 12),
          const _DemoRunSection(),
          const SizedBox(height: 20),
          if (app.demo.progress.isNotEmpty) ...[
            const _DroneControlSection(),
            const SizedBox(height: 20),
          ],
          const _FigureSection(),
        ],
      ),
    );
  }
}

/// Muster, release, step, stop.
class _DemoRunSection extends StatelessWidget {
  const _DemoRunSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SectionCard(
      title: 'Demo mission',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!app.demo.isRunning) ...[
            _RosterPicker(app: app),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: app.isConnected ? () => app.startDemo() : null,
              icon: const Icon(Icons.flight_takeoff),
              label: const Text('MUSTER DRONES'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ] else ...[
            if (app.demo.isMustering) ...[
              // Advisory now, never a gate. The drones are put up close together
              // on purpose and the operator can see them.
              if (app.demo.separationNotice != null)
                _Notice(text: app.demo.separationNotice!),
              FilledButton.icon(
                onPressed: app.demo.mustered.isEmpty
                    ? null
                    : () => _report(context, app.beginFormation()),
                icon: const Icon(Icons.play_arrow),
                label: Text('BEGIN FORMATION '
                    '(${app.demo.mustered.length} ready)'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
            if (app.demo.isFlying) ...[
              // Unchanged: the whole-formation escape hatch that replaces the
              // barrier timeout. Prefer marking the one drone that did not
              // report (per-drone MARK ARRIVED below) -- that keeps everybody on
              // the same vertex index, which is what lockstep separation rests
              // on. This steps the formation regardless, and a drone that had
              // not arrived ends up a vertex out of phase.
              OutlinedButton.icon(
                onPressed: () => _report(context, app.forceNextStep()),
                icon: const Icon(Icons.skip_next),
                label: const Text('FORCE NEXT STEP'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Steps every drone without waiting for arrivals. If only one '
                'drone is missing its report, mark that drone arrived instead.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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
          ],
        ],
      ),
    );
  }
}

/// One card per drone in the run: what it is doing, and every command that can
/// be aimed at it alone.
///
/// `LAND` and `RTH` are here as well as on the Mission tab because a formation
/// is the case where "all drones" is the wrong default: bringing the whole
/// figure down because one aircraft is misbehaving is how a demo ends early.
/// Both go through [DemoRunner] rather than straight down the wire, so the
/// barrier stops waiting for a drone that is on its way out.
class _DroneControlSection extends StatelessWidget {
  const _DroneControlSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final entries = app.demo.progress.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return SectionCard(
      title: app.demo.isMustering ? 'Mustering' : 'Flying the figure',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _DroneControlCard(droneId: e.key, progress: e.value),
            ),
        ],
      ),
    );
  }
}

class _DroneControlCard extends StatelessWidget {
  const _DroneControlCard({required this.droneId, required this.progress});

  final int droneId;
  final DemoProgress progress;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final drone = Drone.byId(droneId);
    final selected = app.selectedTarget == droneId;
    final override = app.demo.altitudeOverrideFor(droneId);
    final offCourse = app.demo.isOffCourse(droneId);

    return Material(
      color: selected
          ? scheme.secondaryContainer
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? scheme.primary : Colors.transparent),
      ),
      child: InkWell(
        onTap: () => app.setSelectedTarget(droneId),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (drone != null) ...[
                    DroneBadge(color: drone.color, radius: 6),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      Drone.nameFor(droneId),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Icon(
                    demoPhaseIcon(progress.phase),
                    size: 16,
                    color: demoPhaseColor(progress.phase, scheme),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    progress.phase == DemoPhase.stepping
                        ? 'step ${progress.steps}'
                        : demoPhaseLabel(progress.phase),
                    style: text.labelSmall?.copyWith(
                      color: demoPhaseColor(progress.phase, scheme),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                override == null
                    ? (progress.detail ?? progress.phase.name)
                    : '${progress.detail ?? progress.phase.name} · joining at '
                        '${override.toStringAsFixed(1)}m',
                style: text.bodySmall,
              ),
              // Reported, never acted on: a joiner is legitimately most of a leg
              // from its vertex while it catches up.
              if (offCourse)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber, size: 14, color: scheme.error),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'off its leg — see the log. Not landing it.',
                          style: text.labelSmall?.copyWith(color: scheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  // The point of this tab: release ONE drone's barrier when its
                  // arrival report was lost, instead of stepping the whole
                  // formation and putting everyone else out of phase.
                  if (progress.isActive && !progress.isWaiting)
                    _Action(
                      icon: Icons.where_to_vote,
                      label: 'MARK ARRIVED',
                      onPressed: () => _report(context, app.markArrived(droneId)),
                    ),
                  if (override != null && progress.phase != DemoPhase.starting)
                    _Action(
                      icon: Icons.merge,
                      label: 'MERGE',
                      onPressed: () =>
                          _report(context, app.mergeIntoFormation(droneId)),
                    ),
                  if (!progress.isActive)
                    _Action(
                      icon: Icons.replay,
                      label: app.demo.isMustering ? 'RETRY' : 'JOIN',
                      onPressed: () => app.retryStart(droneId),
                    ),
                  _Action(
                    icon: Icons.flight_land,
                    label: 'LAND',
                    danger: true,
                    onPressed: app.isConnected
                        ? () => _report(context, app.landDrone(droneId))
                        : null,
                  ),
                  _Action(
                    icon: Icons.home,
                    label: 'RTH',
                    danger: true,
                    onPressed: app.isConnected
                        ? () => _report(context, app.returnDroneHome(droneId))
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor: danger ? scheme.error : null,
        side: danger ? BorderSide(color: scheme.error) : null,
      ),
    );
  }
}

/// The figure the drones walk, and how they are kept apart while they walk it.
///
/// Below the run controls on purpose: these are set once before a muster and
/// frozen for its duration, so they are the least urgent thing on the tab.
class _FigureSection extends StatelessWidget {
  const _FigureSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SectionCard(
      title: 'Figure',
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
          const SizedBox(height: 8),
          NumberStepper(
            label: 'Lookahead (vertices in flight)',
            value: app.demoLookahead.toDouble(),
            min: demoLookaheadRange.min,
            max: demoLookaheadRange.max,
            step: demoLookaheadRange.step,
            unit: '',
            // Frozen mid-run by [AppState.setDemoLookahead], which logs the
            // refusal -- the stepper itself stays live so the value is readable.
            onChanged: app.setDemoLookahead,
          ),
          const SizedBox(height: 4),
          Text(
            app.demoLookahead == 0
                ? 'Strict barrier: every drone confirms a vertex before anyone '
                    'is sent the next. The drones stop dead on each corner.'
                : 'Smooth: the next vertex is sent while the drone is still '
                    'flying, so it rolls through corners without stopping. The '
                    'app confirms up to ${app.demoLookahead} '
                    '${app.demoLookahead == 1 ? "vertex" : "vertices"} behind '
                    'the aircraft.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: app.demoLookahead == 0
                      ? null
                      : Theme.of(context).colorScheme.primary,
                ),
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
            onChanged: app.demo.isRunning ? null : (v) => app.setDemoLockstep(v),
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
        ],
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

/// Something the operator should know, that is not stopping anything.
class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.tertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.tertiary),
            ),
          ),
        ],
      ),
    );
  }
}

void _report(BuildContext context, String? refusal) {
  if (refusal == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(refusal)));
}
