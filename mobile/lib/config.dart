/// Build-time configuration.
///
/// Point the app at a backend with
/// `flutter run --dart-define=API_BASE_URL=https://api.example.com`.
/// The default targets a backend running on the development machine, as seen
/// from the Android emulator.
library;

const String kApiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8000');

/// Sent as `X-App-Version`; keep in sync with `version:` in pubspec.yaml.
const String kAppVersion = '1.0.0';

/// Default country for link lookups (Apple Music storefront, Spotify market...).
const String kDefaultCountry = 'VN';
