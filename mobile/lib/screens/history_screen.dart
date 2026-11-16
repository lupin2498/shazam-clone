import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../models/history_entry.dart';
import '../services/app_services.dart';
import '../widgets/common.dart';
import 'flows.dart';

String dayLabel(DateTime d, {DateTime? now}) {
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final day = DateUtils.dateOnly(d);
  final diff = today.difference(day).inDays;
  if (diff == 0) return S.today;
  if (diff == 1) return S.yesterday;
  return '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}/${day.year}';
}

/// "Lịch sử": by day, searchable, swipe to delete, samples waiting for network on top (F6, F7).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final history = services.history;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          decoration: const InputDecoration(
            hintText: S.historySearch,
            prefixIcon: Icon(Icons.search),
            border: InputBorder.none,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      body: ListenableBuilder(
        listenable: history,
        builder: (context, _) {
          final entries = history.search(_query.text);
          final children = <Widget>[];
          if (history.pendingCount > 0) {
            children.add(Card(
              margin: const EdgeInsets.all(12),
              child: ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text('${S.pendingSection} (${history.pendingCount})'),
                subtitle: const Text(S.pendingItem),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => services.pending.process(),
                ),
              ),
            ));
          }
          final searching = _query.text.trim().isNotEmpty;
          if (entries.isEmpty && searching) {
            // History is not empty: the query just matches nothing.
            children.add(const ListTile(leading: Icon(Icons.search_off), title: Text(S.historyNoMatch)));
            return ListView(children: children);
          }
          if (entries.isEmpty && history.pendingCount == 0) {
            return const MessageView(icon: Icons.history, title: S.historyEmpty);
          }
          String? lastDay;
          for (final e in entries) {
            final day = dayLabel(e.createdAt);
            if (day != lastDay) {
              lastDay = day;
              children.add(Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(day, style: Theme.of(context).textTheme.titleSmall),
              ));
            }
            children.add(_HistoryTile(entry: e));
          }
          return ListView(children: children);
        },
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final history = AppScope.of(context).history;
    final time = TimeOfDay.fromDateTime(entry.createdAt).format(context);
    final icon = switch (entry.source) {
      'file' => Icons.audio_file,
      'hum' => Icons.record_voice_over,
      'search' => Icons.search,
      _ => Icons.mic,
    };
    return Dismissible(
      key: ValueKey('history-${entry.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Theme.of(context).colorScheme.errorContainer,
        child: const Icon(Icons.delete),
      ),
      onDismissed: (_) async {
        await history.remove(entry.id!);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text(S.deleted),
          action: SnackBarAction(label: S.undo, onPressed: () => history.restore(entry)),
        ));
      },
      child: TrackTile(
        track: entry.track,
        subtitle: '${entry.track.artistLine} · $time',
        trailing: Icon(icon, size: 18),
        onTap: () => openResult(context, entry),
      ),
    );
  }
}
