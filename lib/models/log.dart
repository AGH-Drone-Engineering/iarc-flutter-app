enum LogLevels {
  error,
  warn,
  info,
  received,
  sent
}

class Log {
  final LogLevels level;
  final String message;
  final DateTime timestamp;
  Log(this.level, this.message, [DateTime? ts])
      : timestamp = ts ?? DateTime.now();
}