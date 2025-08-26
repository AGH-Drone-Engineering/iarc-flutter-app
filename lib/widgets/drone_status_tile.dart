import 'package:flutter/material.dart';

class DroneStatusTile extends StatelessWidget {
  final DateTime? lastMessageAt;
  final String droneId;
  final int points;

  const DroneStatusTile({
    super.key,
    required this.lastMessageAt,
    required this.droneId,
    required this.points,
  });

  @override
  Widget build(BuildContext context) {
    final rel = lastMessageAt != null ? _relativeTime(lastMessageAt!) : "no signal";
    final ptsLabel = points == 1 ? 'point' : 'points';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(
          droneId,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        subtitle: Text(rel),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              points.toString(),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              ptsLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: .7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _relativeTime(DateTime time) {
    final now = DateTime.now();
    Duration diff = now.difference(time);
    if (diff.isNegative) diff = Duration.zero;

    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      return m == 0 ? '${h}h ago' : '${h}h ${m}m ago';
    }
    final d = diff.inDays;
    final h = diff.inHours.remainder(24);
    return h == 0 ? '${d}d ago' : '${d}d ${h}h ago';
  }
}
