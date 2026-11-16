class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artists,
    this.isrc,
    this.album,
    this.durationMs,
    this.artworkUrl,
    this.isInstrumental = false,
    this.workTitle,
    this.genres = const [],
    this.releaseDate,
  });

  final String id;
  final String title;
  final List<String> artists;
  final String? isrc;
  final String? album;
  final int? durationMs;
  final String? artworkUrl;
  final bool isInstrumental;

  /// Composition title for classical music and covers.
  final String? workTitle;
  final List<String> genres;
  final String? releaseDate;

  String get artistLine => artists.join(', ');

  factory Track.fromJson(Map<String, dynamic> j) => Track(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        artists: ((j['artists'] as List?) ?? const []).cast<String>(),
        isrc: j['isrc'] as String?,
        album: j['album'] as String?,
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        artworkUrl: j['artwork_url'] as String?,
        isInstrumental: (j['is_instrumental'] as bool?) ?? false,
        workTitle: j['work_title'] as String?,
        genres: ((j['genres'] as List?) ?? const []).cast<String>(),
        releaseDate: j['release_date'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artists': artists,
        'isrc': isrc,
        'album': album,
        'duration_ms': durationMs,
        'artwork_url': artworkUrl,
        'is_instrumental': isInstrumental,
        'work_title': workTitle,
        'genres': genres,
        'release_date': releaseDate,
      };
}

String formatDuration(int? ms) {
  if (ms == null || ms < 0) return '';
  final total = (ms / 1000).round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}
