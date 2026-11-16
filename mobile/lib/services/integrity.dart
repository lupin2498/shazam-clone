import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'native_bridge.dart';

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Request hash bound into each Play Integrity token. Must match
/// `request_hash()` in backend/app/security/integrity.py.
String requestHash(String deviceId, List<String> parts) => sha256Hex(utf8.encode([deviceId, ...parts].join('|')));

/// Play Integrity standard requests. Disabled (returns no token) until the backend
/// publishes a Google Cloud project number in `/v1/config`.
///
/// A failed prepare (offline at start, Play services updating) is retried, at most once per
/// [retryAfter], and an expired token provider is prepared again: with `INTEGRITY_MODE=enforce`
/// a provider that stays unprepared means every request is refused until the app restarts.
/// The native side answers a failed token request with null or an error; both count as failed.
class IntegrityService {
  IntegrityService(this._native, {DateTime Function()? clock, this.retryAfter = const Duration(minutes: 1)})
      : _clock = clock ?? DateTime.now;

  final NativeBridge _native;
  final DateTime Function() _clock;

  /// Shortest wait between two prepare attempts after a failure (iOS and devices without
  /// Play services always fail: they must not pay a native call on every request).
  final Duration retryAfter;
  String? _project;
  bool _ready = false;
  DateTime? _failedAt;

  Future<void> prepare(String? cloudProjectNumber) async {
    if (cloudProjectNumber == null || cloudProjectNumber.isEmpty) return;
    if (cloudProjectNumber == _project && _ready) return;
    _project = cloudProjectNumber;
    await _prepareNow();
  }

  Future<bool> _prepareNow() async {
    final project = _project;
    if (project == null) return false;
    bool ok;
    try {
      ok = await _native.integrityPrepare(project);
    } catch (_) {
      ok = false;
    }
    if (project != _project) return _ready; // another project number arrived meanwhile
    _ready = ok;
    _failedAt = ok ? null : _clock();
    return ok;
  }

  Future<String?> token(String deviceId, List<String> parts) async {
    if (_project == null) return null;
    if (!_ready) {
      final failedAt = _failedAt;
      if (failedAt != null && _clock().difference(failedAt) < retryAfter) return null;
      if (!await _prepareNow()) return null;
    }
    final hash = requestHash(deviceId, parts);
    final token = await _request(hash);
    if (token != null) return token;
    // INTEGRITY_TOKEN_PROVIDER_INVALID and friends: a new provider, then one more try.
    if (!await _prepareNow()) return null;
    return _request(hash);
  }

  Future<String?> _request(String hash) async {
    try {
      return await _native.integrityToken(hash);
    } catch (_) {
      return null;
    }
  }
}
