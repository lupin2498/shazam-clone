import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Preferences (section 3, "Cài đặt") plus the anonymous device id.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kDeviceId = 'device_id';
  static const _kCountry = 'country';
  static const _kPreferred = 'preferred_platforms';
  static const _kConfig = 'config_json';
  static const _kMicExplained = 'mic_explained';
  static const _kNotificationsAsked = 'notifications_asked';
  static const _kServer = 'server_url';
  static const _kSettingsUpdatedAt = 'settings_updated_at';
  static const _kSyncEmail = 'sync_email';
  static const _kSyncLastAt = 'sync_last_at';
  static const _kSyncSettingsAt = 'sync_settings_at';
  static const _kHistoryClearedAt = 'history_cleared_at';
  static const _syncProgressKeys = [_kSyncLastAt, _kSyncSettingsAt, _kHistoryClearedAt];
  static const _syncKeys = [_kSyncEmail, ..._syncProgressKeys];

  static Future<SettingsStore> load() async => SettingsStore(await SharedPreferences.getInstance());

  /// Random id generated on first launch: not tied to the hardware or the user.
  String get deviceId {
    final existing = _prefs.getString(_kDeviceId);
    if (existing != null) return existing;
    final id = _newDeviceId();
    _prefs.setString(_kDeviceId, id);
    return id;
  }

  static String _newDeviceId() {
    final rnd = Random.secure();
    return List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  String get country => _prefs.getString(_kCountry) ?? kDefaultCountry;

  Future<void> setCountry(String value) async {
    await _prefs.setString(_kCountry, value);
    await _touch();
    notifyListeners();
  }

  /// Platforms whose links always come first in the "Nghe" group, in order.
  List<String> get preferredPlatforms => _prefs.getStringList(_kPreferred) ?? const [];

  Future<void> setPreferredPlatforms(List<String> ids) async {
    await _prefs.setStringList(_kPreferred, ids);
    await _touch();
    notifyListeners();
  }

  Map<String, dynamic>? get cachedConfig {
    final raw = _prefs.getString(_kConfig);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveConfig(Map<String, dynamic> json) => _prefs.setString(_kConfig, jsonEncode(json));

  /// Backend address chosen in "Cài đặt → Máy chủ" (already validated by `ServerAddress.parse`);
  /// null means the address the app was built with. Read by `ApiClient.currentBaseUrl`.
  String? get serverOverride => _prefs.getString(_kServer);

  Future<void> setServerOverride(String? url) async {
    await _writeServer(url);
    await _touch();
    notifyListeners();
  }

  Future<void> _writeServer(String? url) async {
    if (url == null) {
      await _prefs.remove(_kServer);
    } else {
      await _prefs.setString(_kServer, url);
    }
    // The cached /v1/config belongs to the previous server.
    await _prefs.remove(_kConfig);
  }

  // ---- Google Drive sync (lib/services/drive_sync.dart) ----

  /// When the user last changed a synced setting (country, preferred platforms, server), ms since
  /// epoch; 0 = never. The newer side wins when two devices disagree.
  int get settingsUpdatedAt => _prefs.getInt(_kSettingsUpdatedAt) ?? 0;

  /// Always later than what this device already has or last synced, even if its clock went
  /// back: a change made here must win over the values it replaces.
  Future<void> _touch() => _prefs.setInt(
      _kSettingsUpdatedAt,
      max(DateTime.now().millisecondsSinceEpoch, max(settingsUpdatedAt, syncSettingsAt) + 1));

  /// Settings that came from another device: stored as they are, with their own date.
  /// Returns whether the backend address changed.
  Future<bool> applySyncedSettings({
    required String? country,
    required List<String> preferredPlatforms,
    required String? serverUrl,
    required int updatedAt,
  }) async {
    if (country == null) {
      await _prefs.remove(_kCountry);
    } else {
      await _prefs.setString(_kCountry, country);
    }
    await _prefs.setStringList(_kPreferred, preferredPlatforms);
    final serverChanged = serverUrl != serverOverride;
    if (serverChanged) await _writeServer(serverUrl);
    await _prefs.setInt(_kSettingsUpdatedAt, updatedAt);
    notifyListeners();
    return serverChanged;
  }

  /// The country the user chose, null when it is the default (not synced as a choice).
  String? get countryChoice => _prefs.getString(_kCountry);

  /// Google account whose Drive is synced; null when signed out.
  String? get syncEmail => _prefs.getString(_kSyncEmail);

  Future<void> setSyncEmail(String email) => _prefs.setString(_kSyncEmail, email);

  /// Last successful sync, ms since epoch (0 = never).
  int get syncLastAt => _prefs.getInt(_kSyncLastAt) ?? 0;

  /// [settingsUpdatedAt] as of the last sync: a newer value means a local change to upload.
  int get syncSettingsAt => _prefs.getInt(_kSyncSettingsAt) ?? 0;

  /// Entries recorded up to this time were cleared ("Xóa dữ liệu" on every device), ms.
  int get historyClearedAt => _prefs.getInt(_kHistoryClearedAt) ?? 0;

  Future<void> setHistoryClearedAt(int ms) => _prefs.setInt(_kHistoryClearedAt, ms);

  Future<void> saveSyncState({
    required int lastAt,
    required int settingsAt,
    required int historyClearedAt,
  }) async {
    await _prefs.setInt(_kSyncLastAt, lastAt);
    await _prefs.setInt(_kSyncSettingsAt, settingsAt);
    await _prefs.setInt(_kHistoryClearedAt, historyClearedAt);
  }

  /// Signed out: forget the account and what was synced (local data stays). With
  /// [keepAccount], only the progress (another account was chosen: start over with it).
  Future<void> clearSyncState({bool keepAccount = false}) async {
    for (final key in keepAccount ? _syncProgressKeys : _syncKeys) {
      await _prefs.remove(key);
    }
  }

  bool get micExplained => _prefs.getBool(_kMicExplained) ?? false;

  Future<void> markMicExplained() => _prefs.setBool(_kMicExplained, true);

  bool get notificationsAsked => _prefs.getBool(_kNotificationsAsked) ?? false;

  Future<void> markNotificationsAsked() => _prefs.setBool(_kNotificationsAsked, true);

  /// "Xóa dữ liệu": forget preferences and start over with a new anonymous id. The backend
  /// address stays (it is where the app works, not personal data).
  Future<void> reset() async {
    for (final key in [
      _kDeviceId,
      _kCountry,
      _kPreferred,
      _kMicExplained,
      _kNotificationsAsked,
      _kSettingsUpdatedAt,
      ..._syncKeys,
    ]) {
      await _prefs.remove(key);
    }
    notifyListeners();
  }
}
