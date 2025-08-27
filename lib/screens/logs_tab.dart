import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/global_log.dart';
import '../state/app_state.dart';

class LogsTab extends StatelessWidget {
  const LogsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final glog = context.watch<GlobalLog>();

    final logs = glog.logs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Status bar
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.all(12),
          child: Text(app.connectionStatus),
        ),

        // Controls row: Verbose switch + Clear button
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Row(
                children: [
                  Switch.adaptive(
                    value: glog.verbose,
                    onChanged: (v) => context.read<GlobalLog>().setVerbose(v),
                  ),
                  const SizedBox(width: 6),
                  const Text('Verbose'),
                ],
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () => context.read<GlobalLog>().clear(),
                icon: const Icon(Icons.delete_sweep),
                label: const Text('Clear logs'),
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        // Logs list
        Expanded(
          child: logs.isEmpty
              ? const Center(child: Text('No logs yet'))
              : ListView.builder(
            reverse: true,
            itemCount: logs.length,
            itemBuilder: (_, i) {
              final log = logs[logs.length - 1 - i];
              final color =
                  colorMap[log.level] ?? Theme.of(context).colorScheme.onSurface;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: SelectableText(
                  '[${log.timestamp.toIso8601String()}] ${log.message}',
                  style: TextStyle(fontFamily: 'monospace', color: color),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
