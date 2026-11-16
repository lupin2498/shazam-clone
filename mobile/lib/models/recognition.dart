import 'track.dart';

enum RecognitionStatus { matched, candidates, noMatch }

class Candidate {
  const Candidate({required this.track, required this.confidence, this.rank = 1, this.flags = const []});

  final Track track;
  final double confidence;
  final int rank;

  /// `maybe_beat`, `cover` (matched through melody only) or `melody` (hum mode).
  final List<String> flags;

  bool get maybeBeat => flags.contains('maybe_beat');
  bool get isCover => flags.contains('cover');
  bool get isMelody => flags.contains('melody');

  factory Candidate.fromJson(Map<String, dynamic> j) => Candidate(
        track: Track.fromJson(j['track'] as Map<String, dynamic>),
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        rank: (j['rank'] as num?)?.toInt() ?? 1,
        flags: ((j['flags'] as List?) ?? const []).cast<String>(),
      );
}

class RecognitionResult {
  const RecognitionResult({
    required this.id,
    required this.status,
    required this.stage,
    required this.isFinal,
    required this.candidates,
    this.engine,
    this.latencyMs = 0,
    this.quotaRemaining,
  });

  final String id;
  final RecognitionStatus status;
  final String stage;

  /// False for a 6 s probe without a match: keep listening.
  final bool isFinal;
  final List<Candidate> candidates;
  final String? engine;
  final int latencyMs;
  final int? quotaRemaining;

  Candidate? get top => candidates.isEmpty ? null : candidates.first;

  static RecognitionStatus _status(String? s) => switch (s) {
        'matched' => RecognitionStatus.matched,
        'candidates' => RecognitionStatus.candidates,
        _ => RecognitionStatus.noMatch,
      };

  factory RecognitionResult.fromJson(Map<String, dynamic> j) => RecognitionResult(
        id: j['id'] as String,
        status: _status(j['status'] as String?),
        stage: (j['stage'] as String?) ?? 'full',
        isFinal: (j['final'] as bool?) ?? true,
        engine: j['engine'] as String?,
        latencyMs: (j['latency_ms'] as num?)?.toInt() ?? 0,
        quotaRemaining: (j['quota_remaining'] as num?)?.toInt(),
        candidates: ((j['candidates'] as List?) ?? const [])
            .map((c) => Candidate.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}
