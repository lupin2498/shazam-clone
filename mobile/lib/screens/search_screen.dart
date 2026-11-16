import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../models/history_entry.dart';
import '../models/track.dart';
import '../services/api_client.dart';
import '../services/app_services.dart';
import '../widgets/common.dart';
import 'flows.dart';

/// "Gõ tên bài để tìm link thủ công" when recognition does not match.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<Track>? _results;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.length < 2) return;
    final services = AppScope.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await services.api.search(q, country: services.settings.country);
      if (mounted) setState(() => _results = results);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(Track track) async {
    final entry = await AppScope.of(context)
        .history
        .add(HistoryEntry(track: track, source: 'search', createdAt: DateTime.now()));
    if (mounted) openResult(context, entry);
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: S.searchHint, border: InputBorder.none),
          onSubmitted: (_) => _search(),
        ),
        actions: [IconButton(onPressed: _search, icon: const Icon(Icons.search))],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) ListTile(leading: const Icon(Icons.error_outline), title: Text(_error!)),
          Expanded(
            child: results == null
                ? const SizedBox.shrink()
                : results.isEmpty
                    ? const Center(child: Text(S.searchEmpty))
                    : ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (_, i) => TrackTile(
                          track: results[i],
                          subtitle: [
                            results[i].artistLine,
                            if (results[i].durationMs != null) formatDuration(results[i].durationMs),
                          ].join(' · '),
                          onTap: () => _open(results[i]),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
