import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/log.dart';
import '../services/global_log.dart';
import '../widgets/collapsible_log_text.dart';

class LogsTab extends StatefulWidget {
  const LogsTab({super.key});

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> {
  final Set<LogLevel> _levels = {
    LogLevel.info,
    LogLevel.sent,
    LogLevel.received,
    LogLevel.warn,
    LogLevel.error,
  };
  final _searchCtrl = TextEditingController();
  final _fromCtrl = TextEditingController();
  final _toCtrl = TextEditingController();
  String? _sessionId;
  String _search = '';
  Duration? _from;
  Duration? _to;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  LogSession? _resolveSession(GlobalLog glog) {
    if (_sessionId == null || _sessionId == glog.currentSession?.id) {
      return glog.currentSession;
    }
    for (final s in glog.pastSessions) {
      if (s.id == _sessionId) return s;
    }
    return glog.currentSession;
  }

  /// Parses a wall-clock time as written in the log: `13`, `13:57`, `13:57:06`
  /// or `13:57:06.201`. Null when the text is not a time at all; blank is not an
  /// error, it just means the bound is open.
  ///
  /// [padToEnd] fills the components that were left off with their highest value
  /// rather than zero, so `13:57` as an upper bound covers the whole minute
  /// instead of collapsing onto its first millisecond.
  static Duration? _parseClock(String raw, {required bool padToEnd}) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final m = RegExp(r'^(\d{1,2})(?::(\d{1,2})?)?(?::(\d{1,2})?)?(?:[.,](\d{1,3}))?$')
        .firstMatch(text);
    if (m == null) return null;

    int part(int group, int max) {
      final g = m.group(group);
      if (g == null) return padToEnd ? max : 0;
      return int.parse(g);
    }

    final hours = int.parse(m.group(1)!);
    final minutes = part(2, 59);
    final seconds = part(3, 59);
    final millis = m.group(4) == null
        ? (padToEnd ? 999 : 0)
        : int.parse(m.group(4)!.padRight(3, '0'));
    if (hours > 23 || minutes > 59 || seconds > 59) return null;

    return Duration(
        hours: hours, minutes: minutes, seconds: seconds, milliseconds: millis);
  }

  static Duration _timeOfDay(DateTime ts) => Duration(
      hours: ts.hour,
      minutes: ts.minute,
      seconds: ts.second,
      milliseconds: ts.millisecond);

  bool _inWindow(DateTime ts) {
    final from = _from;
    final to = _to;
    if (from == null && to == null) return true;
    final at = _timeOfDay(ts);
    // An upper bound below the lower one reads as a window across midnight,
    // which is the only way to express one when the bounds are times of day.
    if (from != null && to != null && to < from) return at >= from || at <= to;
    if (from != null && at < from) return false;
    if (to != null && at > to) return false;
    return true;
  }

  List<LogEntry> _filter(LogSession session) {
    final q = _search.toLowerCase();
    return session.entries.where((e) {
      if (!_levels.contains(e.level)) return false;
      if (!_inWindow(e.timestamp)) return false;
      if (q.isEmpty) return true;
      return e.message.toLowerCase().contains(q) || e.tag.toLowerCase().contains(q);
    }).toList();
  }

  static String _windowLabel(Duration? from, Duration? to) {
    String fmt(Duration d) {
      final h = d.inHours.toString().padLeft(2, '0');
      final m = (d.inMinutes % 60).toString().padLeft(2, '0');
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
      return '$h:$m:$s.$ms';
    }

    return '${from == null ? "start" : fmt(from)} .. ${to == null ? "end" : fmt(to)}';
  }

  Future<void> _copy(List<LogEntry> entries, LogSession session) async {
    final text = [
      '# IARC 2026 log — session ${session.label}',
      '# ${entries.length} entries, levels: ${_levels.map((l) => l.label).join(",")}',
      if (_from != null || _to != null) '# window: ${_windowLabel(_from, _to)}',
      if (_search.isNotEmpty) '# filter: "$_search"',
      '',
      ...entries.map((e) => e.plainText),
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${entries.length} lines')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final glog = context.watch<GlobalLog>();
    final session = _resolveSession(glog);

    if (session == null) {
      return const Center(child: Text('No logs yet'));
    }

    final isCurrent = session.id == glog.currentSession?.id;
    final entries = _filter(session);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SessionBar(
            session: session,
            isCurrent: isCurrent,
            onSelect: (s) async {
              setState(() => _sessionId = s.id);
              await glog.loadSessionEntries(s);
            },
          ),
          _FilterBar(
            levels: _levels,
            session: session,
            searchController: _searchCtrl,
            fromController: _fromCtrl,
            toController: _toCtrl,
            onToggle: (level, on) => setState(() {
              on ? _levels.add(level) : _levels.remove(level);
            }),
            onSearch: (v) => setState(() => _search = v),
            onFrom: (v) => setState(() => _from = _parseClock(v, padToEnd: false)),
            onTo: (v) => setState(() => _to = _parseClock(v, padToEnd: true)),
          ),
          _ActionBar(
            count: entries.length,
            total: session.entries.length,
            chars: entries.fold<int>(0, (n, e) => n + e.plainText.length + 1),
            isCurrent: isCurrent,
            onCopy: entries.isEmpty ? null : () => _copy(entries, session),
            onClear: isCurrent ? glog.clearCurrent : null,
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      session.entries.isEmpty
                          ? 'No logs in this session'
                          : 'Nothing matches the filter',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : ListView.separated(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, thickness: 0.3),
                    itemBuilder: (_, i) => _LogRow(entry: entries[entries.length - 1 - i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SessionBar extends StatelessWidget {
  const _SessionBar({
    required this.session,
    required this.isCurrent,
    required this.onSelect,
  });

  final LogSession session;
  final bool isCurrent;
  final ValueChanged<LogSession> onSelect;

  @override
  Widget build(BuildContext context) {
    final glog = context.watch<GlobalLog>();
    final all = [?glog.currentSession, ...glog.pastSessions];

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          const Icon(Icons.history, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: session.id,
                items: [
                  for (final s in all)
                    DropdownMenuItem(
                      value: s.id,
                      child: Text(
                        s.id == glog.currentSession?.id
                            ? '${s.label}  (current)'
                            : s.label,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                ],
                onChanged: (id) {
                  final picked = all.firstWhere((s) => s.id == id);
                  onSelect(picked);
                },
              ),
            ),
          ),
          if (isCurrent)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.fiber_manual_record, size: 12, color: Colors.green),
            ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.levels,
    required this.session,
    required this.searchController,
    required this.fromController,
    required this.toController,
    required this.onToggle,
    required this.onSearch,
    required this.onFrom,
    required this.onTo,
  });

  final Set<LogLevel> levels;
  final LogSession session;
  final TextEditingController searchController;
  final TextEditingController fromController;
  final TextEditingController toController;
  final void Function(LogLevel, bool) onToggle;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFrom;
  final ValueChanged<String> onTo;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        children: [
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final level in LogLevel.values) ...[
                  FilterChip(
                    label: Text(
                      '${level.label} ${session.countAtLeast({level})}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: levels.contains(level),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    selectedColor: level.color.withValues(alpha: 0.25),
                    side: BorderSide(color: level.color.withValues(alpha: 0.6)),
                    onSelected: (on) => onToggle(level, on),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Capture trace',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              Switch.adaptive(
                value: context.watch<GlobalLog>().traceEnabled,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: context.read<GlobalLog>().setTraceEnabled,
              ),
            ],
          ),
          SizedBox(
            height: 38,
            child: TextField(
              controller: searchController,
              onChanged: onSearch,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter text…',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          searchController.clear();
                          onSearch('');
                        },
                      ),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.schedule, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: _ClockField(
                  controller: fromController,
                  hint: 'from 13:57:06',
                  onChanged: onFrom,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _ClockField(
                  controller: toController,
                  hint: 'to 13:58',
                  onChanged: onTo,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One end of the wall-clock window. Blank means open; text that is not a time
/// is shown as an error rather than silently ignored.
class _ClockField extends StatelessWidget {
  const _ClockField({
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final raw = controller.text.trim();
    final bad = raw.isNotEmpty &&
        _LogsTabState._parseClock(raw, padToEnd: false) == null;

    return SizedBox(
      height: 38,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: TextInputType.datetime,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          errorText: bad ? 'hh:mm:ss' : null,
          errorStyle: const TextStyle(fontSize: 10, height: 0.6),
          suffixIcon: raw.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.count,
    required this.total,
    required this.chars,
    required this.isCurrent,
    required this.onCopy,
    required this.onClear,
  });

  final int count;
  final int total;
  final int chars;
  final bool isCurrent;
  final VoidCallback? onCopy;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final size = chars < 1024 ? '$chars chars' : '${(chars / 1024).toStringAsFixed(1)} kB';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text(
            '${count == total ? "$total entries" : "$count of $total"} · $size',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy_all, size: 18),
            label: const Text('Copy'),
          ),
          if (isCurrent)
            TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: const Text('Clear'),
            ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                entry.clockTime,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: entry.level.color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  entry.level.label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: entry.level.color,
                  ),
                ),
              ),
              if (entry.tag.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  entry.tag,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          CollapsibleLogText(
            text: entry.message,
            color: entry.level.color,
            maxLines: 3,
          ),
        ],
      ),
    );
  }
}
