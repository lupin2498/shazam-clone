/// Build-time configuration.
library;

import 'package:flutter/foundation.dart';

/// Backend address compiled into the app; empty when the build did not set one.
///
///     flutter build apk --dart-define=API_BASE_URL=https://api.example.com
const String kApiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// Address used until the user picks another one in "Cài đặt → Máy chủ".
///
/// Debug and profile builds without `API_BASE_URL` talk to a backend running on the
/// development machine: `10.0.2.2` from the Android emulator, `127.0.0.1` from the iOS
/// simulator. A release build without it has no address and the app asks for one.
String defaultApiBaseUrl() {
  if (kApiBaseUrl.isNotEmpty) return kApiBaseUrl;
  if (kReleaseMode) return '';
  return defaultTargetPlatform == TargetPlatform.iOS ? 'http://127.0.0.1:8000' : 'http://10.0.2.2:8000';
}

/// Sent as `X-App-Version`; keep in sync with `version:` in pubspec.yaml.
const String kAppVersion = '1.0.0';

/// Default country for link lookups (Apple Music storefront, Spotify market...).
const String kDefaultCountry = 'VN';
