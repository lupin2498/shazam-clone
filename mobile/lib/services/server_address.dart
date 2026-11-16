import 'package:flutter/foundation.dart';

/// An address typed in "Cài đặt → Máy chủ" that cannot be used. [message] is shown as-is.
class ServerAddressException implements Exception {
  const ServerAddressException(this.message);

  final String message;

  @override
  String toString() => 'ServerAddressException: $message';
}

/// Rules for the backend address (design doc, section 10: samples travel encrypted).
///
/// Release builds accept `https://` only, with one exception: plain `http://` to a host on
/// the local network or the device itself, so the app can be tried against a backend
/// running on a computer next to the phone. Debug and profile builds accept any `http://`.
///
/// The check lives in Dart because the Flutter engine does not apply Android's network
/// security config or iOS App Transport Security to `dart:io` sockets.
abstract final class ServerAddress {
  static const emptyMessage = 'Hãy nhập địa chỉ máy chủ.';
  static const invalidMessage = 'Địa chỉ không hợp lệ. Ví dụ: https://api.example.com';
  static const httpsOnlyMessage =
      'Máy chủ ngoài mạng nội bộ phải dùng https://. Chỉ địa chỉ trong mạng nội bộ (ví dụ 192.168.1.10) được dùng http://.';

  /// Normalises what the user typed (scheme added when missing, trailing slashes removed).
  /// Throws [ServerAddressException] when the address is malformed or not allowed.
  static String parse(String input, {bool release = kReleaseMode}) {
    var text = input.trim();
    if (text.isEmpty) throw const ServerAddressException(emptyMessage);
    if (text.contains(RegExp(r'\s'))) throw const ServerAddressException(invalidMessage);
    if (!text.contains('://')) {
      final guess = Uri.tryParse('http://$text');
      text = (guess != null && isLocalHost(guess.host)) ? 'http://$text' : 'https://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ServerAddressException(invalidMessage);
    }
    if (!_schemeAllowed(uri, release: release)) throw const ServerAddressException(httpsOnlyMessage);
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path).toString();
  }

  /// Whether requests may be sent to [baseUrl] in this build.
  static bool isAllowed(String baseUrl, {bool release = kReleaseMode}) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) return false;
    return _schemeAllowed(uri, release: release);
  }

  static bool _schemeAllowed(Uri uri, {required bool release}) {
    if (uri.scheme == 'https') return true;
    if (uri.scheme != 'http') return false;
    return !release || isLocalHost(uri.host);
  }

  /// Loopback, private (RFC 1918), link-local and `.local` names: traffic stays on the
  /// local network. Includes 10.0.2.2, the development machine seen from the Android emulator.
  static bool isLocalHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.local') || h.endsWith('.localhost')) return true;
    final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
    if (v4 != null) {
      final a = int.parse(v4.group(1)!);
      final b = int.parse(v4.group(2)!);
      if ([a, b, int.parse(v4.group(3)!), int.parse(v4.group(4)!)].any((part) => part > 255)) return false;
      return a == 10 || a == 127 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);
    }
    if (h.contains(':')) {
      // IPv6: loopback, unique local (fc00::/7) and link-local (fe80::/10).
      return h == '::1' || h.startsWith('fc') || h.startsWith('fd') || RegExp(r'^fe[89ab]').hasMatch(h);
    }
    return false;
  }
}
