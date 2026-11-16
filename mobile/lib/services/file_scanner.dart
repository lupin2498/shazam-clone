import 'dart:math';

import '../models/app_config.dart';
import '../models/recognition.dart';
import '../models/track.dart';
import 'api_client.dart';
import 'native_bridge.dart';
import 'recognizer.dart';

class ScanHit {
  ScanHit({required this.candidate, required this.startMs, required this.endMs, required this.recognitionId});

  final Candidate candidate;
  final int startMs;
  int endMs;
  final String recognitionId;

  Track get track => candidate.track;
}

class ScanProgress {
  const ScanProgress({required this.done, required this.total, required this.hits, this.error});

  final int done;
  final int total;
  final List<ScanHit> hits;
  final String? error;

  bool get finished => done >= total || error != null;
}

/// "Quét cả file" (section 5): segments every [SampleConfig.scanStepS] seconds,
/// consecutive identical results merged into one entry per song with its time range.
Stream<ScanProgress> scanFile({
  required NativeBridge native,
  required ApiClient api,
  required String uri,
  required int durationMs,
  required SampleConfig config,
  String? filenameHint,
}) async* {
  final step = config.scanStepS * 1000;
  final segment = config.fileDefaultS * 1000;
  final starts = <int>[for (var s = 0; s + 5000 <= durationMs; s += step) s];
  if (starts.isEmpty) starts.add(0);
  final hits = <ScanHit>[];
  final scanId = newSessionId();
  yield ScanProgress(done: 0, total: starts.length, hits: const []);
  for (var i = 0; i < starts.length; i++) {
    final start = starts[i];
    try {
      final sample = await native.encodeSegment(uri, startMs: start, durationMs: min(segment, durationMs - start));
      if (sample.rms >= config.silenceRms && sample.aac.isNotEmpty) {
        final r = await api.recognize(
          audio: sample.aac,
          mode: 'auto',
          source: 'file',
          stage: 'full',
          sessionId: '$scanId-$i',
          filenameHint: filenameHint,
        );
        final top = r.top;
        if (r.status == RecognitionStatus.matched && top != null) {
          final last = hits.isEmpty ? null : hits.last;
          if (last != null && last.track.id == top.track.id) {
            last.endMs = min(start + step, durationMs);
          } else {
            hits.add(ScanHit(
                candidate: top, startMs: start, endMs: min(start + step, durationMs), recognitionId: r.id));
          }
        }
      }
    } on ApiException catch (e) {
      yield ScanProgress(done: i, total: starts.length, hits: List.of(hits), error: e.message);
      return;
    } catch (_) {
      // Undecodable segment: skip it.
    }
    yield ScanProgress(done: i + 1, total: starts.length, hits: List.of(hits));
  }
}
