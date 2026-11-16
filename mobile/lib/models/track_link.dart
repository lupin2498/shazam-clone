enum LinkKind {
  listen('listen'),
  buy('buy'),
  freeDownload('free_download'),
  offlineInApp('offline_in_app');

  const LinkKind(this.wire);
  final String wire;

  static LinkKind parse(String? value) =>
      LinkKind.values.firstWhere((k) => k.wire == value, orElse: () => LinkKind.listen);
}

class TrackLink {
  const TrackLink({
    required this.id,
    required this.platform,
    required this.kind,
    required this.exact,
    required this.url,
    this.title,
    this.durationMs,
    this.score = 0,
    this.license,
  });

  final String id;
  final String platform;
  final LinkKind kind;

  /// `exact`: a specific track page. Otherwise a deep search link ("Tìm trên …").
  final bool exact;
  final String url;
  final String? title;
  final int? durationMs;
  final double score;
  final String? license;

  bool get isOpenLicense => license != null && (license!.startsWith('CC') || license == 'Public Domain');

  factory TrackLink.fromJson(Map<String, dynamic> j) => TrackLink(
        id: j['id'] as String,
        platform: j['platform'] as String,
        kind: LinkKind.parse(j['kind'] as String?),
        exact: j['match'] == 'exact',
        url: j['url'] as String,
        title: j['title'] as String?,
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        score: (j['score'] as num?)?.toDouble() ?? 0,
        license: j['license'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'platform': platform,
        'kind': kind.wire,
        'match': exact ? 'exact' : 'search',
        'url': url,
        'title': title,
        'duration_ms': durationMs,
        'score': score,
        'license': license,
      };
}
