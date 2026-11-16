import 'dart:ui' show Color;

/// A music platform as published by `GET /v1/config`.
class PlatformInfo {
  const PlatformInfo({
    required this.id,
    required this.name,
    required this.color,
    this.androidPackage,
    this.offlineInApp = false,
    this.offlineNote,
    this.enabled = true,
  });

  final String id;
  final String name;
  final Color color;
  final String? androidPackage;
  final bool offlineInApp;
  final String? offlineNote;
  final bool enabled;

  static Color _parseColor(String? hex) {
    final value = int.tryParse((hex ?? '').replaceFirst('#', ''), radix: 16) ?? 0x607D8B;
    return Color(0xFF000000 | value);
  }

  factory PlatformInfo.fromJson(Map<String, dynamic> j) => PlatformInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        color: _parseColor(j['color'] as String?),
        androidPackage: j['android_package'] as String?,
        offlineInApp: (j['offline_in_app'] as bool?) ?? false,
        offlineNote: j['offline_note'] as String?,
        enabled: (j['enabled'] as bool?) ?? true,
      );
}

class SampleConfig {
  const SampleConfig({
    this.earlyProbeS = 6,
    this.fullS = 12,
    this.humS = 15,
    this.fileDefaultS = 12,
    this.fileMinS = 10,
    this.fileMaxS = 15,
    this.fileDefaultPosition = 0.3,
    this.scanStepS = 30,
    this.silenceRms = 0.004,
  });

  final int earlyProbeS;
  final int fullS;
  final int humS;
  final int fileDefaultS;
  final int fileMinS;
  final int fileMaxS;
  final double fileDefaultPosition;
  final int scanStepS;
  final double silenceRms;

  factory SampleConfig.fromJson(Map<String, dynamic> j) => SampleConfig(
        earlyProbeS: (j['early_probe_s'] as num?)?.toInt() ?? 6,
        fullS: (j['full_s'] as num?)?.toInt() ?? 12,
        humS: (j['hum_s'] as num?)?.toInt() ?? 15,
        fileDefaultS: (j['file_default_s'] as num?)?.toInt() ?? 12,
        fileMinS: (j['file_min_s'] as num?)?.toInt() ?? 10,
        fileMaxS: (j['file_max_s'] as num?)?.toInt() ?? 15,
        fileDefaultPosition: (j['file_default_position'] as num?)?.toDouble() ?? 0.3,
        scanStepS: (j['scan_step_s'] as num?)?.toInt() ?? 30,
        silenceRms: (j['silence_rms'] as num?)?.toDouble() ?? 0.004,
      );
}

class ReportReason {
  const ReportReason(this.id, this.label);
  final String id;
  final String label;
}

class AppConfig {
  const AppConfig({
    required this.platforms,
    this.sample = const SampleConfig(),
    this.minAppVersion = '1.0.0',
    this.quotaPerDay = 30,
    this.engines = const ['ACRCloud', 'AudD'],
    this.reportReasons = defaultReasons,
    this.cloudProjectNumber,
    this.demoMode = false,
  });

  final List<PlatformInfo> platforms;
  final SampleConfig sample;
  final String minAppVersion;
  final int quotaPerDay;
  final List<String> engines;
  final List<ReportReason> reportReasons;
  final String? cloudProjectNumber;
  final bool demoMode;

  static const defaultReasons = [
    ReportReason('wrong_song', 'Sai bài'),
    ReportReason('broken', 'Link hỏng'),
    ReportReason('violation', 'Vi phạm bản quyền'),
    ReportReason('other', 'Lý do khác'),
  ];

  PlatformInfo platform(String id) => platforms.firstWhere(
        (p) => p.id == id,
        orElse: () => PlatformInfo(id: id, name: id, color: const Color(0xFF607D8B)),
      );

  List<PlatformInfo> get enabledPlatforms => platforms.where((p) => p.enabled).toList();

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        platforms: ((j['platforms'] as List?) ?? const [])
            .map((p) => PlatformInfo.fromJson(p as Map<String, dynamic>))
            .toList(),
        sample: SampleConfig.fromJson((j['sample'] as Map<String, dynamic>?) ?? const {}),
        minAppVersion: (j['min_app_version'] as String?) ?? '1.0.0',
        quotaPerDay: (j['quota_per_day'] as num?)?.toInt() ?? 30,
        engines: ((j['engines'] as List?) ?? const []).cast<String>(),
        reportReasons: ((j['report_reasons'] as List?) ?? const [])
            .map((r) => ReportReason(r['id'] as String, r['label'] as String))
            .toList(),
        cloudProjectNumber: (j['integrity'] as Map<String, dynamic>?)?['cloud_project_number'] as String?,
        demoMode: (j['demo_mode'] as bool?) ?? false,
      );

  /// Used until the first `/v1/config` response arrives (or when offline).
  static final AppConfig defaults = AppConfig(platforms: [
    _p('youtube', 'YouTube', 0xFF0000, 'com.google.android.youtube'),
    _p('youtube_music', 'YouTube Music', 0xFF0033, 'com.google.android.apps.youtube.music',
        offline: true, note: 'Cần YouTube Premium'),
    _p('spotify', 'Spotify', 0x1DB954, 'com.spotify.music', offline: true, note: 'Cần Spotify Premium'),
    _p('soundcloud', 'SoundCloud', 0xFF5500, 'com.soundcloud.android'),
    _p('apple_music', 'Apple Music', 0xFA243C, 'com.apple.android.music'),
    _p('itunes', 'iTunes Store', 0xEA4CC0, null),
    _p('deezer', 'Deezer', 0xA238FF, 'deezer.android.app'),
    _p('zing_mp3', 'Zing MP3', 0x8D22C3, 'com.zing.mp3', offline: true),
    _p('nct', 'NhacCuaTui', 0x2DAAED, 'ht.nct', offline: true),
    _p('tidal', 'TIDAL', 0x000000, 'com.aspiro.tidal'),
    _p('amazon_music', 'Amazon Music', 0x25D1DA, 'com.amazon.mp3'),
    _p('amazon_store', 'Amazon', 0xFF9900, null),
    _p('bandcamp', 'Bandcamp', 0x1DA0C3, 'com.bandcamp.android'),
    _p('jamendo', 'Jamendo', 0xE8195B, null),
    _p('internet_archive', 'Internet Archive', 0x666666, null),
    _p('free_music_archive', 'Free Music Archive', 0xD5354F, null),
    _p('musopen', 'Musopen', 0x2B5C8A, null),
  ]);

  static PlatformInfo _p(String id, String name, int rgb, String? pkg, {bool offline = false, String? note}) =>
      PlatformInfo(
        id: id,
        name: name,
        color: Color(0xFF000000 | rgb),
        androidPackage: pkg,
        offlineInApp: offline,
        offlineNote: note,
      );
}
