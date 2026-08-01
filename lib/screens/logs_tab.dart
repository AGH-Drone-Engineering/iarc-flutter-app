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
  String? _sessionId;
  String _search = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
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

  List<LogEntry> _filter(LogSession session) {
    final q = _search.toLowerCase();
    return session.entries.where((e) {
      if (!_levels.contains(e.level)) return false;
      if (q.isEmpty) return true;
      return e.message.toLowerCase().contains(q) || e.tag.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _copy(List<LogEntry> entries, LogSession session) async {
    final text = [
      '# IARC 2026 log — session ${session.label}',
      '# ${entries.length} entries, levels: ${_levels.map((l) => l.label).join(",")}',
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
            onToggle: (level, on) => setState(() {
              on ? _levels.add(level) : _levels.remove(level);
            }),
            onSearch: (v) => setState(() => _search = v),
          ),
          _ActionBar(
            count: entries.length,
            total: session.entries.length,
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
    required this.onToggle,
    required this.onSearch,
  });

  final Set<LogLevel> levels;
  final LogSession session;
  final TextEditingController searchController;
  final void Function(LogLevel, bool) onToggle;
  final ValueChanged<String> onSearch;

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
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.count,
    required this.total,
    required this.isCurrent,
    required this.onCopy,
    required this.onClear,
  });

  final int count;
  final int total;
  final bool isCurrent;
  final VoidCallback? onCopy;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text(
            count == total ? '$total entries' : '$count of $total',
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
