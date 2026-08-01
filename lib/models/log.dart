import 'package:flutter/material.dart';

enum LogLevel {
  trace('TRACE', Colors.blueGrey),
  info('INFO', Colors.grey),
  sent('SENT', Colors.purple),
  received('RECV', Colors.green),
  warn('WARN', Colors.deepOrange),
  error('ERROR', Color(0xFFB71C1C));

  const LogLevel(this.label, this.color);

  final String label;
  final Color color;

  static LogLevel fromWire(String s) =>
      LogLevel.values.firstWhere((l) => l.name == s, orElse: () => LogLevel.info);
}

class LogEntry {
  final LogLevel level;
  final String tag;
  final String message;
  final DateTime timestamp;

  LogEntry(this.level, this.tag, this.message, [DateTime? ts])
      : timestamp = ts ?? DateTime.now();

  factory LogEntry.fromJson(Map<String, Object?> j) => LogEntry(
        LogLevel.fromWire(j['l'] as String? ?? 'info'),
        j['g'] as String? ?? '',
        j['m'] as String? ?? '',
        DateTime.tryParse(j['t'] as String? ?? ''),
      );

  Map<String, Object?> toJson() => {
        't': timestamp.toIso8601String(),
        'l': level.name,
        'g': tag,
        'm': message,
      };

  String get clockTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  String get plainText =>
      '[$clockTime] ${level.label.padRight(5)} ${tag.isEmpty ? '' : '[$tag] '}$message';
}

class LogSession {
  final String id;
  final DateTime startedAt;
  final List<LogEntry> entries;

  LogSession({required this.id, required this.startedAt, List<LogEntry>? entries})
      : entries = entries ?? [];

  String get label {
    final d = startedAt;
    final date = '${d.year}-${_pad(d.month)}-${_pad(d.day)}';
    return '$date ${_pad(d.hour)}:${_pad(d.minute)}:${_pad(d.second)}';
  }

  static String _pad(int v) => v.toString().padLeft(2, '0');

  int countAtLeast(Set<LogLevel> levels) =>
      entries.where((e) => levels.contains(e.level)).length;
}
