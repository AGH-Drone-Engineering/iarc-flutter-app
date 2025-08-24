// lib/screens/logs_tab.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/global_log.dart'; // GlobalLog + LogLevels + logs list
import '../state/app_state.dart';     // For connectionStatus

// Use Color (works for both MaterialColor and plain Color)

class LogsTab extends StatelessWidget {
  const LogsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();       // connection status
    final glog = context.watch<GlobalLog>();     // global logs source

    final logs = glog.logs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.all(12),
          child: Text(app.connectionStatus),
        ),
        const Divider(height: 1),
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
                child: Text(
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
