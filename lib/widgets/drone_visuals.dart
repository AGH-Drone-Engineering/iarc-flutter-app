import 'package:flutter/material.dart';

import '../models/drone.dart';
import '../models/mission_message.dart';
import '../services/command_tracker.dart';
import '../services/demo_runner.dart';

/// Foreground that stays legible on [background]. Drone colours span light
/// amber to mid red, so neither a fixed white nor a fixed black works for all.
///
/// Picks whichever of black and white has the higher WCAG contrast ratio rather
/// than using [ThemeData.estimateBrightnessForColor]: that one asks "does this
/// colour look dark", which is a lower bar than "is text on it readable", and
/// it puts white on `Colors.red.shade300` at 3:1.
Color readableOn(Color background) {
  final luminance = background.computeLuminance();
  final onBlack = (luminance + 0.05) / 0.05;
  final onWhite = 1.05 / (luminance + 0.05);
  return onBlack >= onWhite ? Colors.black87 : Colors.white;
}

Color droneStateColor(Drone drone, ColorScheme scheme, {AckFailure? failure}) {
  if (failure?.isCritical ?? false) return scheme.error;
  if (!drone.hasEverReported) return scheme.outline;
  if (drone.isStale) return scheme.error;
  return switch (drone.state) {
    DroneState.killed || DroneState.error => scheme.error,
    DroneState.idle || DroneState.landed || DroneState.boot => scheme.outline,
    _ => Colors.green,
  };
}

IconData demoPhaseIcon(DemoPhase phase) => switch (phase) {
      DemoPhase.starting => Icons.flight_takeoff,
      DemoPhase.stepping => Icons.directions_run,
      DemoPhase.holding => Icons.pause_presentation,
      DemoPhase.landing => Icons.flight_land,
      DemoPhase.finished => Icons.check_circle,
      DemoPhase.stopped => Icons.pause_circle,
    };

String demoPhaseLabel(DemoPhase phase) => switch (phase) {
      DemoPhase.starting => 'taking off',
      DemoPhase.stepping => 'running',
      DemoPhase.holding => 'holding for formation',
      DemoPhase.landing => 'landing in place',
      DemoPhase.finished => 'finished',
      DemoPhase.stopped => 'stopped',
    };

Color demoPhaseColor(DemoPhase phase, ColorScheme scheme) => switch (phase) {
      DemoPhase.landing => scheme.error,
      DemoPhase.finished => Colors.green,
      DemoPhase.stopped => scheme.outline,
      _ => scheme.primary,
    };

/// Drone-coloured dot, optionally carrying a short label.
class DroneBadge extends StatelessWidget {
  const DroneBadge({
    super.key,
    required this.color,
    this.label,
    this.radius = 12,
  });

  final Color? color;
  final String? label;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final background =
        color ?? Theme.of(context).colorScheme.surfaceContainerHighest;

    return CircleAvatar(
      radius: radius,
      backgroundColor: background,
      child: label == null
          ? null
          : Text(
              label!,
              style: TextStyle(
                fontSize: radius * 0.85,
                fontWeight: FontWeight.w700,
                color: readableOn(background),
              ),
            ),
    );
  }
}
