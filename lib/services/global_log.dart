import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/log.dart';

class GlobalLog extends ChangeNotifier {
  GlobalLog({this.capacity = 5000, this.maxSessions = 20});

  final int capacity;
  final int maxSessions;

  LogSession? _current;
  final List<LogSession> _past = [];

  Directory? _dir;
  IOSink? _sink;
  final List<LogEntry> _pending = [];
  Timer? _flushTimer;

  bool _traceEnabled = true;
  bool get traceEnabled => _traceEnabled;

  LogSession? get currentSession => _current;
  List<LogSession> get pastSessions => List.unmodifiable(_past);

  void setTraceEnabled(bool v) {
    if (_traceEnabled == v) return;
    _traceEnabled = v;
    add(LogLevel.info, 'app', 'Tracing ${v ? "enabled" : "disabled"}');
    notifyListeners();
  }

  Future<void> init() async {
    final now = DateTime.now();
    _current = LogSession(id: now.toIso8601String().replaceAll(':', '-'), startedAt: now);

    try {
      final base = await getApplicationDocumentsDirectory();
      _dir = Directory('${base.path}/logs');
      await _dir!.create(recursive: true);
      await _loadPastSessions();
      await _prune();
      _sink = File('${_dir!.path}/${_current!.id}.jsonl').openWrite(mode: FileMode.append);
    } catch (e) {
      debugPrint('Log persistence unavailable: $e');
    }

    _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) => flush());
    add(LogLevel.info, 'app', 'Session started');
    notifyListeners();
  }

  Future<void> _loadPastSessions() async {
    final dir = _dir;
    if (dir == null) return;

    final files = (await dir.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    for (final f in files) {
      final id = f.uri.pathSegments.last.replaceAll('.jsonl', '');
      if (id == _current?.id) continue;
      final started = DateTime.tryParse(_restoreColons(id));
      if (started == null) continue;
      _past.add(LogSession(id: id, startedAt: started));
    }
  }

  static String _restoreColons(String id) {
    final t = id.indexOf('T');
    if (t < 0) return id;
    return '${id.substring(0, t)}T${id.substring(t + 1).replaceAll('-', ':')}';
  }

  /// Past sessions are stored on disk only; entries load on demand.
  Future<void> loadSessionEntries(LogSession session) async {
    if (session.entries.isNotEmpty || _dir == null) return;
    final file = File('${_dir!.path}/${session.id}.jsonl');
    if (!await file.exists()) return;

    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        session.entries.add(LogEntry.fromJson(jsonDecode(line) as Map<String, Object?>));
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _prune() async {
    while (_past.length > maxSessions) {
      final old = _past.removeLast();
      try {
        await File('${_dir!.path}/${old.id}.jsonl').delete();
      } catch (_) {}
    }
  }

  void add(LogLevel level, String tag, String message) {
    final session = _current;
    if (session == null) return;
    if (level == LogLevel.trace && !_traceEnabled) return;

    final entry = LogEntry(level, tag, message);
    session.entries.add(entry);
    if (session.entries.length > capacity) {
      session.entries.removeRange(0, session.entries.length - capacity);
    }
    _pending.add(entry);
    notifyListeners();
  }

  Future<void> flush() async {
    if (_pending.isEmpty || _sink == null) return;
    final batch = List<LogEntry>.from(_pending);
    _pending.clear();
    try {
      for (final e in batch) {
        _sink!.writeln(jsonEncode(e.toJson()));
      }
      await _sink!.flush();
    } catch (e) {
      debugPrint('Log flush failed: $e');
    }
  }

  Future<void> clearCurrent() async {
    _current?.entries.clear();
    _pending.clear();
    notifyListeners();
  }

  Future<void> deleteAllSessions() async {
    for (final s in _past) {
      try {
        await File('${_dir!.path}/${s.id}.jsonl').delete();
      } catch (_) {}
    }
    _past.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    flush().then((_) => _sink?.close());
    super.dispose();
  }
}

final GlobalLog globalLog = GlobalLog();

const int _maxUnverifiedChars = 200;

/// Escapes control characters so unvalidated input cannot corrupt the log view
/// or the session file. [maxLength] <= 0 leaves the content uncapped.
String sanitizeForLog(String raw, {int maxLength = _maxUnverifiedChars}) {
  final capped = maxLength > 0;
  final buf = StringBuffer();
  var written = 0;
  for (final rune in raw.runes) {
    if (capped && written >= maxLength) break;
    if (rune == 0x0A || rune == 0x0D || rune == 0x09) {
      buf.write(rune == 0x09 ? r'\t' : r'\n');
      written += 2;
    } else if (rune < 0x20 || rune == 0x7F) {
      buf.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
      written += 4;
    } else {
      buf.writeCharCode(rune);
      written++;
    }
  }
  if (capped && raw.length > maxLength) buf.write(' … (${raw.length} chars)');
  return buf.toString();
}

/// Share of bytes that are printable ASCII — used to tell a firmware log line
/// from line noise.
double printableRatio(List<int> bytes) {
  if (bytes.isEmpty) return 0;
  final printable =
      bytes.where((b) => (b >= 0x20 && b < 0x7F) || b == 0x0A || b == 0x0D).length;
  return printable / bytes.length;
}

void logTrace(String tag, String m) => globalLog.add(LogLevel.trace, tag, m);
void logInfo(String m, [String tag = '']) => globalLog.add(LogLevel.info, tag, m);
void logWarn(String m, [String tag = '']) => globalLog.add(LogLevel.warn, tag, m);
void logError(String m, [String tag = '']) => globalLog.add(LogLevel.error, tag, m);
void logRx(String m, [String tag = '']) => globalLog.add(LogLevel.received, tag, m);
void logSnt(String m, [String tag = '']) => globalLog.add(LogLevel.sent, tag, m);
