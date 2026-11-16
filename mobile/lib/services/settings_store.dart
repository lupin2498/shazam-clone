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
    notifyListeners();
  }

  /// Platforms whose links always come first in the "Nghe" group, in order.
  List<String> get preferredPlatforms => _prefs.getStringList(_kPreferred) ?? const [];

  Future<void> setPreferredPlatforms(List<String> ids) async {
    await _prefs.setStringList(_kPreferred, ids);
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
    if (url == null) {
      await _prefs.remove(_kServer);
    } else {
      await _prefs.setString(_kServer, url);
    }
    // The cached /v1/config belongs to the previous server.
    await _prefs.remove(_kConfig);
    notifyListeners();
  }

  bool get micExplained => _prefs.getBool(_kMicExplained) ?? false;

  Future<void> markMicExplained() => _prefs.setBool(_kMicExplained, true);

  bool get notificationsAsked => _prefs.getBool(_kNotificationsAsked) ?? false;

  Future<void> markNotificationsAsked() => _prefs.setBool(_kNotificationsAsked, true);

  /// "Xóa dữ liệu": forget preferences and start over with a new anonymous id.
  Future<void> reset() async {
    for (final key in [_kDeviceId, _kCountry, _kPreferred, _kMicExplained, _kNotificationsAsked]) {
      await _prefs.remove(key);
    }
    notifyListeners();
  }
}
