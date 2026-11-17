import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'native_bridge.dart';
import 'settings_store.dart';

/// Why the Google account cannot be used right now.
class GoogleAuthException implements Exception {
  const GoogleAuthException(this.code, [this.message]);

  /// `needs_sign_in` (Google wants the user: expired or revoked), `not_configured` (the app is not
  /// registered with Google, or no iOS client id), `network`, `cancelled`, `google_error`.
  final String code;
  final String? message;

  bool get isNetwork => code == 'network';

  @override
  String toString() => 'GoogleAuthException($code${message == null ? '' : ': $message'})';
}

/// The Google account behind "Đồng bộ Google Drive": sign-in, sign-out and access tokens.
///
/// The platform does the sign-in (Google Identity Services on Android, the system browser with
/// PKCE on iOS) for two scopes only: the e-mail address and the app's own hidden folder on Drive.
class GoogleAccount extends ChangeNotifier {
  GoogleAccount({
    required this.native,
    required this.settings,
    required http.Client client,
    this.iosClientId = kGoogleIosClientId,
    DateTime Function()? clock,
  })  : _http = client,
        _clock = clock ?? DateTime.now;

  final NativeBridge native;
  final SettingsStore settings;
  final String iosClientId;
  final http.Client _http;
  final DateTime Function() _clock;

  String? _token;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  /// False on an iOS build made without `GOOGLE_IOS_CLIENT_ID`.
  bool get configured => !_isIOS || iosClientId.isNotEmpty;

  String? get email => settings.syncEmail;
  bool get signedIn => email != null;

  /// A valid access token, renewed without showing anything. [rejected] is a token the Drive
  /// API refused (401). Throws [GoogleAuthException] (`needs_sign_in` when the user must sign in).
  Future<String> accessToken({String? rejected}) async {
    if (!signedIn) throw const GoogleAuthException('needs_sign_in');
    final cached = _token;
    if (rejected == null && cached != null && _clock().isBefore(_expires)) return cached;
    final auth = await _authorize(interactive: false, invalidToken: rejected ?? cached);
    if (auth == null) throw const GoogleAuthException('needs_sign_in');
    _remember(auth);
    return auth.accessToken;
  }

  /// Shows Google's account choice and consent. False when the user cancelled.
  Future<bool> signIn() async {
    final auth = await _authorize(interactive: true);
    if (auth == null) return false;
    _remember(auth);
    final address = auth.email ?? await _fetchEmail(auth.accessToken);
    if (address == null || address.isEmpty) throw const GoogleAuthException('google_error', 'no e-mail');
    await settings.setSyncEmail(address);
    notifyListeners();
    return true;
  }

  /// Forgets the account and its token on this device. The app's access is not revoked at
  /// Google: other devices on the same account stay signed in (the user can remove the access
  /// in their Google Account, "Bảo mật → Ứng dụng bên thứ ba").
  Future<void> signOut() async {
    try {
      await native.googleSignOut(email: email, accessToken: _token, iosClientId: _isIOS ? iosClientId : null);
    } catch (e) {
      debugPrint('Google sign-out: $e');
    }
    _token = null;
    _expires = DateTime.fromMillisecondsSinceEpoch(0);
    await settings.clearSyncState();
    notifyListeners();
  }

  Future<GoogleAuthorization?> _authorize({required bool interactive, String? invalidToken}) async {
    if (!configured) throw const GoogleAuthException('not_configured');
    try {
      return await native.googleAuthorize(
        interactive: interactive,
        // Interactive sign-in offers the account choice; renewals stay on the signed-in account.
        email: interactive ? null : email,
        invalidToken: invalidToken,
        iosClientId: _isIOS ? iosClientId : null,
      );
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') return null;
      throw GoogleAuthException(e.code, e.message);
    } on MissingPluginException {
      throw const GoogleAuthException('not_configured');
    }
  }

  void _remember(GoogleAuthorization auth) {
    _token = auth.accessToken;
    // Android does not say how long; Google tokens last an hour and asking again is cheap.
    final seconds = auth.expiresIn ?? 45 * 60;
    _expires = _clock().add(Duration(seconds: seconds > 120 ? seconds - 60 : seconds));
  }

  Future<String?> _fetchEmail(String token) async {
    try {
      final resp = await _http
          .get(Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'),
              headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      return body is Map ? body['email'] as String? : null;
    } catch (e) {
      debugPrint('userinfo: $e');
      return null;
    }
  }
}
