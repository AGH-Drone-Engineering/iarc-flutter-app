import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

class ConnectionBar extends StatelessWidget {
  const ConnectionBar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final connected = app.isConnected;
    final scheme = Theme.of(context).colorScheme;
    final foreground =
        connected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;

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
            color: foreground,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              app.connectionStatus,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: foreground),
            ),
          ),
          Text(
            app.config.transport.label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}
