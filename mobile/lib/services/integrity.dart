import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'native_bridge.dart';

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Request hash bound into each Play Integrity token. Must match
/// `request_hash()` in backend/app/security/integrity.py.
String requestHash(String deviceId, List<String> parts) => sha256Hex(utf8.encode([deviceId, ...parts].join('|')));

/// Play Integrity standard requests. Disabled (returns no token) until the backend
/// publishes a Google Cloud project number in `/v1/config`.
class IntegrityService {
  IntegrityService(this._native);

  final NativeBridge _native;
  bool _ready = false;
  String? _preparedFor;

  Future<void> prepare(String? cloudProjectNumber) async {
    if (cloudProjectNumber == null || cloudProjectNumber.isEmpty || cloudProjectNumber == _preparedFor) return;
    _preparedFor = cloudProjectNumber;
    try {
      _ready = await _native.integrityPrepare(cloudProjectNumber);
    } catch (_) {
      _ready = false;
    }
  }

  Future<String?> token(String deviceId, List<String> parts) async {
    if (!_ready) return null;
    try {
      return await _native.integrityToken(requestHash(deviceId, parts));
    } catch (_) {
      return null;
    }
  }
}
