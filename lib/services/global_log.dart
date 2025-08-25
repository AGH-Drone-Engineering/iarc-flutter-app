// lib/services/global_log.dart
import 'dart:collection';
import 'package:flutter/material.dart';

import '../models/log.dart';

final Map<LogLevels, Color> colorMap = {
  LogLevels.warn: Colors.deepOrange,
  LogLevels.error: Colors.red.shade900,
  LogLevels.info: Colors.grey,
  LogLevels.received: Colors.green,
  LogLevels.sent: Colors.purple
};

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

final GlobalLog globalLog = GlobalLog();

void addLog(LogLevels level, String message, [DateTime? ts]) =>
    globalLog.add(level, message, ts);
void clearLogs() => globalLog.clear();

// Convenience shorthands:
void logInfo(String m) => addLog(LogLevels.info, m);
void logWarn(String m) => addLog(LogLevels.warn, m);
void logError(String m) => addLog(LogLevels.error, m);
void logRx(String m) => addLog(LogLevels.received, m);
void logSnt(String m) => addLog(LogLevels.sent, m);
