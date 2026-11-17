import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/app_config.dart';
import 'api_client.dart';
import 'drive_sync.dart';
import 'google_account.dart';
import 'history.dart';
import 'integrity.dart';
import 'native_bridge.dart';
import 'pending_queue.dart';
import 'recognizer.dart';
import 'settings_store.dart';

/// `/v1/config`: cached on the device so the app starts offline with the last known values.
class ConfigRepository extends ValueNotifier<AppConfig> {
  ConfigRepository(this._api, this._settings) : super(_initial(_settings));

  final ApiClient _api;
  final SettingsStore _settings;

  static AppConfig _initial(SettingsStore settings) {
    final cached = settings.cachedConfig;
    if (cached == null) return AppConfig.defaults;
    try {
      final config = AppConfig.fromJson(cached);
      return config.platforms.isEmpty ? AppConfig.defaults : config;
    } catch (_) {
      return AppConfig.defaults;
    }
  }

  /// Returns whether the backend answered with a usable config.
  Future<bool> refresh() async {
    final server = _api.currentBaseUrl;
    try {
      final json = await _api.fetchConfigJson();
      // The address changed while waiting ("Cài đặt → Máy chủ" twice in a row): this answer
      // belongs to a server the app no longer talks to. Keeping it would pair the new server
      // with the old one's settings (platforms, Play Integrity project).
      if (_api.currentBaseUrl != server) return false;
      final config = AppConfig.fromJson(json);
      if (config.platforms.isEmpty) return false;
      value = config;
      await _settings.saveConfig(json);
      return true;
    } catch (_) {
      // Offline or server down: keep the cached/default config.
      return false;
    }
  }
}

/// Long-lived objects, created once in `main()` and reachable through [AppScope].
class AppServices {
  AppServices({
    required this.native,
    required this.settings,
    required this.api,
    required this.history,
    required this.pending,
    required this.config,
    required this.integrity,
    GoogleAccount? account,
    SyncService? sync,
    http.Client? httpClient,
  }) : results = ResultHandler(history) {
    final client = httpClient ?? http.Client();
    this.account = account ?? GoogleAccount(native: native, settings: settings, client: client);
    this.sync = sync ??
        SyncService(
          account: this.account,
          drive: DriveClient(client),
          settings: settings,
          history: history,
          onServerChanged: () async {
            await reconnect();
            unawaited(pending.process());
          },
        );
  }

  final NativeBridge native;
  final SettingsStore settings;
  final ApiClient api;
  final HistoryRepository history;
  final PendingQueue pending;
  final ConfigRepository config;
  final IntegrityService integrity;
  final ResultHandler results;

  /// Google account and Drive sync of the history and settings.
  late final GoogleAccount account;
  late final SyncService sync;

  /// Android 10+: music playing in other apps can be recognised (Quick Settings tile).
  bool playbackCaptureSupported = false;

  Set<String> _installed = const {};

  /// Platform ids whose app is installed (used to rank links).
  Set<String> get installedPlatforms => _installed;

  static Future<AppServices> create({NativeBridge? native, HistoryDb? db}) async {
    final bridge = native ?? MethodChannelNativeBridge();
    final settings = await SettingsStore.load();
    final integrity = IntegrityService(bridge);
    final api = ApiClient(
      baseUrl: defaultApiBaseUrl(),
      baseUrlOverride: () => settings.serverOverride,
      deviceId: () => settings.deviceId,
      integrity: integrity,
    );
    HistoryDb historyDb;
    try {
      historyDb = db ?? await SqliteHistoryDb.open();
    } catch (e) {
      debugPrint('SQLite unavailable, history kept in memory: $e');
      historyDb = MemoryHistoryDb();
    }
    final history = HistoryRepository(historyDb);
    await history.load();
    final services = AppServices(
      native: bridge,
      settings: settings,
      api: api,
      history: history,
      pending: PendingQueue(native: bridge, api: api, history: history, settings: settings),
      config: ConfigRepository(api, settings),
      integrity: integrity,
    );
    try {
      services.playbackCaptureSupported = await bridge.playbackCaptureSupported();
    } catch (_) {}
    unawaited(services._warmUp());
    return services;
  }

  Future<void> _warmUp() async {
    await reconnect();
    pending.start();
    sync.start();
  }

  /// The app is in the foreground again: results recognised in the background (Quick Settings
  /// tile, offline queue) are in the database, and other devices may have synced.
  Future<void> onResume() async {
    await history.load();
    sync.onResume();
  }

  /// Loads `/v1/config` and what depends on it; also called after the backend address
  /// changed in "Cài đặt → Máy chủ". Returns whether the backend answered.
  Future<bool> reconnect() async {
    final ok = await config.refresh();
    await integrity.prepare(config.value.cloudProjectNumber);
    await refreshInstalledApps();
    return ok;
  }

  Future<void> refreshInstalledApps() async {
    final byPackage = {
      for (final p in config.value.platforms)
        if (p.androidPackage != null) p.androidPackage!: p.id,
    };
    try {
      final installed = await native.installedPackages(byPackage.keys.toList());
      _installed = {for (final pkg in installed) byPackage[pkg]!};
    } catch (_) {
      _installed = const {};
    }
  }
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing above $context');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
