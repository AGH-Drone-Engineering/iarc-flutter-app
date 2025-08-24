// lib/services/global_log.dart
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Single source of truth for log levels.
enum LogLevels { error, warn, info, received }

/// Log entry model.
class Log {
  final LogLevels level;
  final String message;
  final DateTime timestamp;
  Log(this.level, this.message, [DateTime? ts])
      : timestamp = ts ?? DateTime.now();
}

/// Global logger: keeps logs and notifies listeners on changes.
class GlobalLog extends ChangeNotifier {
  GlobalLog({this.capacity = 500});
  final int capacity;

  final List<Log> _logs = [];
  UnmodifiableListView<Log> get logs => UnmodifiableListView(_logs);

  void add(LogLevels level, String message, [DateTime? ts]) {
    _logs.add(Log(level, message, ts));
    if (_logs.length > capacity) {
      _logs.removeRange(0, _logs.length - capacity);
    }
    notifyListeners(); // <-- UI gets rebuilt
  }

  void clear() {
    _logs.clear();
    notifyListeners(); // <-- UI gets rebuilt
  }
}

/// App-wide singleton instance.
final GlobalLog globalLog = GlobalLog();

/// Top-level helpers you can call from anywhere (no imports of ChangeNotifier needed).
void addLog(LogLevels level, String message, [DateTime? ts]) =>
    globalLog.add(level, message, ts);
void clearLogs() => globalLog.clear();

// Convenience shorthands:
void logInfo(String m) => addLog(LogLevels.info, m);
void logWarn(String m) => addLog(LogLevels.warn, m);
void logError(String m) => addLog(LogLevels.error, m);
void logRx(String m) => addLog(LogLevels.received, m);
