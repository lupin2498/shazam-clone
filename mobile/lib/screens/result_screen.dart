import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../models/history_entry.dart';
import '../models/track.dart';
import '../models/track_link.dart';
import '../services/api_client.dart';
import '../services/app_services.dart';
import '../services/link_sorter.dart';
import '../widgets/common.dart';
import '../widgets/link_tile.dart';

/// "Kết quả": artwork, title, artist, labels, then every link found, split into
/// "Nghe" and "Tải/Mua". Links appear platform by platform as the backend finds them.
class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.entry});

  final HistoryEntry entry;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  late HistoryEntry _entry = widget.entry;
  final List<TrackLink> _links = [];
  StreamSubscription<LinksEvent>? _sub;
  bool _loading = false;
  String? _error;
  bool _started = false;

  AppServices get _services => AppScope.of(context);
  Track get _track => _entry.track;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final stored = _entry.links;
    if (stored != null && stored.isNotEmpty) {
      _links.addAll(stored); // F6: reopen from history without recognising again
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _load() {
    _sub?.cancel();
    setState(() {
      _links.clear();
      _loading = true;
      _error = null;
    });
    final variant = _entry.flags.contains('maybe_beat') ? 'beat' : null;
    _sub = _services.api
        .streamLinks(_track.id, country: _services.settings.country, variant: variant)
        .listen(
      (event) {
        if (!mounted) return;
        setState(() => _links.addAll(event.links));
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = e is ApiException ? e.message : S.networkError;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _loading = false);
        _persist();
      },
    );
  }

  Future<void> _persist() async {
    final id = _entry.id;
    if (id == null) return;
    await _services.history.saveLinks(id, List.of(_links));
    _entry = _entry.copyWith(links: List.of(_links));
  }

  Future<void> _open(TrackLink link) async {
    final platform = _services.config.value.platform(link.platform);
    final ok = await _services.native.openUrl(link.url, androidPackage: platform.androidPackage);
    if (!ok && mounted) showSnack(context, S.cannotOpen);
  }

  Future<void> _report(TrackLink link) async {
    final reasons = _services.config.value.reportReasons;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text(S.reportLink),
        children: [
          for (final r in reasons)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, r.id), child: Text(r.label)),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    try {
      final hidden = await _services.api.reportLink(link.id, reason);
      if (!mounted) return;
      if (hidden || reason == 'violation') {
        setState(() => _links.removeWhere((l) => l.id == link.id));
        await _persist();
      }
      if (mounted) showSnack(context, hidden ? S.linkHidden : S.reportSent);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  Future<void> _reportWrong() async {
    final id = _entry.recognitionId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.reportWrongTitle),
        content: Text('${_track.title} — ${_track.artistLine}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.reportWrong)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _services.api.reportRecognition(id);
      if (mounted) showSnack(context, S.reportWrongBody);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  void _share() {
    final groups = groupLinks(_links);
    final best = groups.listen.where((l) => l.exact).firstOrNull ?? groups.listen.firstOrNull;
    final text = ['${_track.title} — ${_track.artistLine}', if (best != null) best.url].join('\n');
    _services.native.shareText(text, title: S.share);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _services.config.value;
    final groups = groupLinks(
      _links,
      preferred: _services.settings.preferredPlatforms,
      installedPlatforms: _services.installedPlatforms,
    );

    Widget tile(TrackLink l) {
      final platform = config.platform(l.platform);
      return LinkTile(
        link: l,
        platform: platform,
        installed: _services.installedPlatforms.contains(l.platform),
        onOpen: () => _open(l),
        onReport: () => _report(l),
      );
    }

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(tooltip: S.share, onPressed: _share, icon: const Icon(Icons.share)),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'wrong' ? _reportWrong() : _load(),
            itemBuilder: (_) => [
              if (_entry.recognitionId != null) const PopupMenuItem(value: 'wrong', child: Text(S.reportWrong)),
              const PopupMenuItem(value: 'refresh', child: Text(S.refresh)),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _load(),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Hero(tag: 'art-${_track.id}', child: TrackArtwork(_track, size: 220, radius: 16)),
                  const SizedBox(height: 16),
                  Text(_track.title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                  const SizedBox(height: 4),
                  Text(_track.artistLine,
                      style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary),
                      textAlign: TextAlign.center),
                  if (_track.album != null) Text(_track.album!, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  TrackLabels(track: _track, flags: _entry.flags),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (_loading) ...[
              const LinearProgressIndicator(),
              const Padding(padding: EdgeInsets.all(8), child: Text(S.findingLinks, textAlign: TextAlign.center)),
            ],
            if (_error != null)
              ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(_error!),
                trailing: TextButton(onPressed: _load, child: const Text(S.tryAgain)),
              ),
            _SectionHeader(S.listenGroup, count: groups.listen.length),
            if (groups.listen.isEmpty && !_loading)
              const ListTile(title: Text(S.noListenLinks))
            else
              ...groups.listen.map(tile),
            _SectionHeader(S.getGroup, count: groups.get.length),
            if (!_loading && !groups.hasFreeDownload)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Card(
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline),
                        const SizedBox(width: 12),
                        Expanded(child: Text(groups.get.isEmpty ? S.noGetLinks : S.noFreeDownload)),
                      ],
                    ),
                  ),
                ),
              ),
            ...groups.get.map(tile),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(count > 0 ? '$title ($count)' : title, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}
