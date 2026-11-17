import 'dart:typed_data';

import 'recognition.dart';
import 'track.dart';
import 'track_link.dart';

/// One recognised song kept on the device (F6). Links are stored so the
/// result can be reopened without recognising again.
class HistoryEntry {
  const HistoryEntry({
    this.id,
    required this.track,
    required this.source,
    required this.createdAt,
    this.recognitionId,
    this.flags = const [],
    this.confidence,
    this.links,
  });

  final int? id;
  final Track track;

  /// mic | file | hum | search
  final String source;
  final DateTime createdAt;
  final String? recognitionId;
  final List<String> flags;
  final double? confidence;
  final List<TrackLink>? links;

  Candidate get candidate => Candidate(track: track, confidence: confidence ?? 1, flags: flags);

  HistoryEntry copyWith({int? id, List<TrackLink>? links, DateTime? createdAt}) => HistoryEntry(
        id: id ?? this.id,
        track: track,
        source: source,
        createdAt: createdAt ?? this.createdAt,
        recognitionId: recognitionId,
        flags: flags,
        confidence: confidence,
        links: links ?? this.links,
      );
}

/// A sample recorded while offline, sent when the network comes back (F7).
class PendingSample {
  const PendingSample({
    this.id,
    required this.audio,
    required this.mode,
    required this.source,
    required this.createdAt,
    this.filenameHint,
    this.attempts = 0,
  });

  final int? id;
  final Uint8List audio;
  final String mode;
  final String source;
  final DateTime createdAt;
  final String? filenameHint;
  final int attempts;
}
