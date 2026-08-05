import 'package:flutter/material.dart';

import '../models/drone.dart';
import 'drone_visuals.dart';

/// The single place a mine's identity is rendered, so the mine model can grow
/// without every screen that shows one having to follow.
class MineIdentity extends StatelessWidget {
  const MineIdentity({super.key, required this.mine, this.radius = 11});

  final MineReport mine;
  final double radius;

  /// Short enough to sit inside the badge; [MineReport.name] is the long form.
  static String labelFor(MineReport mine) => '${mine.tag}';

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${mine.name} — by ${Drone.nameFor(mine.reportedBy)}\n'
          '${mine.position.latitude.toStringAsFixed(7)}, '
          '${mine.position.longitude.toStringAsFixed(7)}',
      child: DroneBadge(
        color: Drone.byId(mine.reportedBy)?.color,
        label: labelFor(mine),
        radius: radius,
      ),
    );
  }
}
