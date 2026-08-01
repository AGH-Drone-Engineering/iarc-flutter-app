import 'dart:async';

import 'package:flutter/material.dart';

import '../models/drone.dart';
import '../models/mission_message.dart';
import '../services/command_tracker.dart';

class DroneStatusTile extends StatefulWidget {
  const DroneStatusTile({
    super.key,
    required this.drone,
    this.awaitingAck = false,
    this.failure,
    this.onTap,
    this.selected = false,
  });

  final Drone drone;
  final bool awaitingAck;
  final AckFailure? failure;
  final VoidCallback? onTap;
  final bool selected;

  @override
  State<DroneStatusTile> createState() => _DroneStatusTileState();
}

class _DroneStatusTileState extends State<DroneStatusTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Color _stateColor(ColorScheme scheme) {
    final d = widget.drone;
    if (widget.failure?.isCritical ?? false) return scheme.error;
    if (!d.hasEverReported) return scheme.outline;
    if (d.isStale) return scheme.error;
    return switch (d.state) {
      DroneState.killed || DroneState.error => scheme.error,
      DroneState.idle || DroneState.landed || DroneState.boot => scheme.outline,
      _ => Colors.green,
    };
  }

  String get _lastSeenText {
    final since = widget.drone.sinceLastSeen;
    if (since == null) return 'never seen';
    if (since.inSeconds < 2) return 'just now';
    if (since.inSeconds < 60) return '${since.inSeconds}s ago';
    if (since.inMinutes < 60) return '${since.inMinutes}m ago';
    if (since.inHours < 24) return '${since.inHours}h ago';
    return '${since.inDays}d ago';
  }

  String _telemetryLine(Drone d) {
    if (d.position == null) return 'no telemetry';
    return [
      '${d.position!.latitude.toStringAsFixed(6)}, '
          '${d.position!.longitude.toStringAsFixed(6)}',
      if (d.altitude != null) '${d.altitude!.toStringAsFixed(1)} m',
    ].join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = widget.drone;
    final stateColor = _stateColor(scheme);

    return Material(
      color: widget.selected
          ? scheme.secondaryContainer
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            d.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          d.hasEverReported ? d.state.wire : '—',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: stateColor,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        if (widget.awaitingAck) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _telemetryLine(d),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (d.battery != null)
                    Text(
                      '${d.battery!.toStringAsFixed(1)} V',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  Text(
                    _lastSeenText,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: d.isStale ? scheme.error : null,
                        ),
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
