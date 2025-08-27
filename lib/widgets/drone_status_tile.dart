import 'dart:async';
import 'package:flutter/material.dart';

class DroneStatusTile extends StatefulWidget {
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
  State<DroneStatusTile> createState() => _DroneStatusTileState();
}

class _DroneStatusTileState extends State<DroneStatusTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant DroneStatusTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lastMessageAt != widget.lastMessageAt) {
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lastSeen = _formatAgo(widget.lastMessageAt);
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.droneId,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Last seen: $lastSeen',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Points: ${widget.points}',
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatAgo(DateTime? ts) {
    if (ts == null) return '—';
    var diff = DateTime.now().difference(ts);
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
