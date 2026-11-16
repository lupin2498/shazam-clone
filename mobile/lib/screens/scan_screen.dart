import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../models/history_entry.dart';
import '../models/track.dart';
import '../services/app_services.dart';
import '../services/file_scanner.dart';
import '../services/native_bridge.dart';
import '../widgets/common.dart';
import 'flows.dart';

/// "Quét cả file": every song found in a long recording, with its time range.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.file, required this.durationMs});

  final PickedFile file;
  final int durationMs;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  StreamSubscription<ScanProgress>? _sub;
  ScanProgress? _progress;
  final Map<String, HistoryEntry> _saved = {};
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final s = AppScope.of(context);
    _sub = scanFile(
      native: s.native,
      api: s.api,
      uri: widget.file.uri,
      durationMs: widget.durationMs,
      config: s.config.value.sample,
      filenameHint: widget.file.name,
    ).listen((p) {
      if (!mounted) return;
      setState(() => _progress = p);
      if (p.finished) _saveHits(p.hits);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Results are saved to history automatically (section 3, step 6).
  Future<void> _saveHits(List<ScanHit> hits) async {
    final history = AppScope.of(context).history;
    for (final hit in hits) {
      if (_saved.containsKey(hit.track.id)) continue;
      _saved[hit.track.id] = await history.add(HistoryEntry(
        track: hit.track,
        source: 'file',
        createdAt: DateTime.now(),
        recognitionId: hit.recognitionId,
        flags: hit.candidate.flags,
        confidence: hit.candidate.confidence,
      ));
    }
    if (mounted) setState(() {});
  }

  void _open(ScanHit hit) {
    final entry = _saved[hit.track.id] ??
        HistoryEntry(
          track: hit.track,
          source: 'file',
          createdAt: DateTime.now(),
          recognitionId: hit.recognitionId,
          flags: hit.candidate.flags,
          confidence: hit.candidate.confidence,
        );
    openResult(context, entry);
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final hits = p?.hits ?? const <ScanHit>[];
    return Scaffold(
      appBar: AppBar(title: const Text(S.scanResults)),
      body: Column(
        children: [
          if (p == null || !p.finished) ...[
            LinearProgressIndicator(value: p == null || p.total == 0 ? null : p.done / p.total),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(p == null ? S.scanning : S.scanProgress(p.done, p.total)),
            ),
          ],
          if (p?.error != null) ListTile(leading: const Icon(Icons.error_outline), title: Text(p!.error!)),
          Expanded(
            child: hits.isEmpty
                ? (p != null && p.finished ? const Center(child: Text(S.scanEmpty)) : const SizedBox.shrink())
                : ListView.builder(
                    itemCount: hits.length,
                    itemBuilder: (_, i) {
                      final hit = hits[i];
                      return TrackTile(
                        track: hit.track,
                        subtitle: '${formatDuration(hit.startMs)} – ${formatDuration(hit.endMs)} · '
                            '${hit.track.artistLine}',
                        onTap: () => _open(hit),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
