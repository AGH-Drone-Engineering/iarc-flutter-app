import 'package:flutter/material.dart';

import '../models/drone.dart';
import '../services/command_tracker.dart';

class AckAlertBanner extends StatelessWidget {
  const AckAlertBanner({
    super.key,
    required this.failures,
    required this.onDismiss,
    required this.onRetryStatus,
  });

  final List<AckFailure> failures;
  final void Function(int droneId) onDismiss;
  final void Function(int droneId) onRetryStatus;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final f in failures)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _AlertRow(
              failure: f,
              onDismiss: () => onDismiss(f.droneId),
              onRetryStatus: () => onRetryStatus(f.droneId),
            ),
          ),
      ],
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({
    required this.failure,
    required this.onDismiss,
    required this.onRetryStatus,
  });

  final AckFailure failure;
  final VoidCallback onDismiss;
  final VoidCallback onRetryStatus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final critical = failure.isCritical;

    final background = critical ? scheme.errorContainer : scheme.tertiaryContainer;
    final foreground =
        critical ? scheme.onErrorContainer : scheme.onTertiaryContainer;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: foreground.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            critical ? Icons.warning_amber_rounded : Icons.info_outline,
            color: foreground,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Drone.nameFor(failure.droneId),
                  style: TextStyle(fontWeight: FontWeight.w700, color: foreground),
                ),
                const SizedBox(height: 2),
                Text(
                  failure.description,
                  style: TextStyle(color: foreground),
                ),
                if (critical) ...[
                  const SizedBox(height: 6),
                  Text(
                    'The drone may not have received this command.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: foreground.withValues(alpha: 0.85)),
                  ),
                ],
              ],
            ),
          ),
          Column(
            children: [
              if (critical)
                IconButton(
                  onPressed: onRetryStatus,
                  tooltip: 'Ping drone',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.wifi_tethering, color: foreground),
                ),
              IconButton(
                onPressed: onDismiss,
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close, color: foreground),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
