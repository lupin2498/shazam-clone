import 'dart:async';

import 'package:flutter/services.dart';

/// AAC (ADTS) sample produced on the device, with its RMS level for the silence check.
class EncodedSample {
  const EncodedSample({required this.aac, required this.rms, required this.durationMs});

  final Uint8List aac;

  /// 0..1, 1 = full scale.
  final double rms;
  final int durationMs;

  static EncodedSample fromMap(Map<Object?, Object?> m) => EncodedSample(
        aac: (m['aac'] as Uint8List?) ?? Uint8List(0),
        rms: (m['rms'] as num?)?.toDouble() ?? 0,
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      );
}

class PickedFile {
  const PickedFile({required this.uri, this.name});

  /// `content://` URI; decoded natively, never copied.
  final String uri;
  final String? name;
}

/// Access to the Google account used by "Đồng bộ Google Drive".
class GoogleAuthorization {
  const GoogleAuthorization({required this.accessToken, this.email, this.expiresIn});

  final String accessToken;

  /// Known on Android; on iOS the Dart side asks Google (userinfo).
  final String? email;

  /// Seconds the token stays valid; null when the platform does not say (Android caches and
  /// renews tokens itself, asking again is cheap).
  final int? expiresIn;

  static GoogleAuthorization? fromMap(Map<Object?, Object?>? m) {
    final token = m?['accessToken'];
    if (token is! String || token.isEmpty) return null;
    return GoogleAuthorization(
      accessToken: token,
      email: m!['email'] as String?,
      expiresIn: (m['expiresIn'] as num?)?.toInt(),
    );
  }
}

/// `requestAddQuickSettingsTile` results (Android StatusBarManager codes, -1 = not available).
abstract final class QuickTileResult {
  static const unavailable = -1;
  static const notAdded = 0;
  static const alreadyAdded = 1;
  static const added = 2;
}

class AudioProbe {
  const AudioProbe({required this.durationMs, this.name});

  final int durationMs;
  final String? name;
}

/// Everything the app needs from the platform. Implemented over platform channels by
/// android/app/src/main/kotlin/vn/timnhac/app/MainActivity.kt and ios/Runner/NativeBridge.swift
/// (the same contract on both), and faked in tests. The background capture engine on Android
/// answers a subset (PlaybackCaptureService.kt).
abstract class NativeBridge {
  Stream<double> get levels;
  Stream<PickedFile> get sharedFiles;
  Stream<bool> get connectivity;

  /// Taps on a result notification: the id of the history entry to open.
  Stream<int> get notificationTaps;

  Future<bool> hasMicPermission();
  Future<bool> shouldShowMicRationale();
  Future<bool> requestMicPermission();
  Future<void> openAppSettings();

  Future<bool> startRecording({required int maxSeconds});
  Future<EncodedSample> snapshotRecording({required int maxMs});
  Future<EncodedSample> stopRecording();
  Future<void> cancelRecording();

  Future<PickedFile?> pickAudioFile();
  Future<AudioProbe> probeAudio(String uri);
  Future<List<double>> audioWaveform(String uri, {int buckets = 160});
  Future<EncodedSample> encodeSegment(String uri, {required int startMs, required int durationMs});
  Future<bool> previewPlay(String uri, {required int startMs, required int durationMs});
  Future<void> previewStop();

  Future<bool> openUrl(String url, {String? androidPackage});
  Future<void> shareText(String text, {String? title});
  Future<Set<String>> installedPackages(List<String> packages);
  Future<bool> isOnline();

  /// Tapping the notification opens [historyId] (through [notificationTaps]) when given.
  Future<void> notify(String title, String body, {int? historyId});
  Future<bool> requestNotificationPermission();
  Future<bool> integrityPrepare(String cloudProjectNumber);
  Future<String?> integrityToken(String requestHash);

  /// Android 10+: music other apps are playing can be recognised ("Nhạc đang phát trên máy").
  Future<bool> playbackCaptureSupported();

  /// Asks for consent and recognises what other apps play; the result arrives as a
  /// notification. False when not supported.
  Future<bool> startPlaybackCapture();

  /// Android 13+: the system dialog adding the Quick Settings tile. A [QuickTileResult] code.
  Future<int> requestAddQuickSettingsTile();

  /// The background capture engine is done (does nothing in the app).
  Future<void> finishBackgroundTask();

  /// Google account for Drive sync (scopes: e-mail, the app's hidden Drive folder). Null when the
  /// user cancelled, or when [interactive] is false and Google needs to show something.
  /// [invalidToken] is a token the Drive API rejected. [iosClientId] is the OAuth client of the
  /// iOS app (Android needs none). Throws [PlatformException] with code `not_configured`,
  /// `network` or `google_error`.
  Future<GoogleAuthorization?> googleAuthorize({
    required bool interactive,
    String? email,
    String? invalidToken,
    String? iosClientId,
  });

  /// Forgets the account on this device and revokes the app's access.
  Future<void> googleSignOut({String? email, String? accessToken, String? iosClientId});
}

class MethodChannelNativeBridge implements NativeBridge {
  static const _channel = MethodChannel('vn.timnhac/native');
  static const _levels = EventChannel('vn.timnhac/levels');
  static const _shared = EventChannel('vn.timnhac/shared_files');
  static const _connectivity = EventChannel('vn.timnhac/connectivity');
  static const _notificationTaps = EventChannel('vn.timnhac/notification_taps');

  Stream<double>? _levelStream;
  Stream<PickedFile>? _sharedStream;
  Stream<bool>? _connectivityStream;
  Stream<int>? _tapStream;

  @override
  Stream<double> get levels =>
      _levelStream ??= _levels.receiveBroadcastStream().map((e) => (e as num).toDouble()).asBroadcastStream();

  @override
  Stream<PickedFile> get sharedFiles => _sharedStream ??= _shared.receiveBroadcastStream().map((e) {
        final m = e as Map<Object?, Object?>;
        return PickedFile(uri: m['uri'] as String, name: m['name'] as String?);
      }).asBroadcastStream();

  @override
  Stream<bool> get connectivity =>
      _connectivityStream ??= _connectivity.receiveBroadcastStream().map((e) => e as bool).asBroadcastStream();

  @override
  Stream<int> get notificationTaps =>
      _tapStream ??= _notificationTaps.receiveBroadcastStream().map((e) => (e as num).toInt()).asBroadcastStream();

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) => _channel.invokeMethod<T>(method, args);

  @override
  Future<bool> hasMicPermission() async => await _call<bool>('hasMicPermission') ?? false;

  @override
  Future<bool> shouldShowMicRationale() async => await _call<bool>('shouldShowMicRationale') ?? false;

  @override
  Future<bool> requestMicPermission() async => await _call<bool>('requestMicPermission') ?? false;

  @override
  Future<void> openAppSettings() => _call('openAppSettings');

  @override
  Future<bool> startRecording({required int maxSeconds}) async =>
      await _call<bool>('startRecording', {'maxSeconds': maxSeconds}) ?? false;

  @override
  Future<EncodedSample> snapshotRecording({required int maxMs}) async =>
      EncodedSample.fromMap((await _call<Map<Object?, Object?>>('snapshotRecording', {'maxMs': maxMs}))!);

  @override
  Future<EncodedSample> stopRecording() async =>
      EncodedSample.fromMap((await _call<Map<Object?, Object?>>('stopRecording'))!);

  @override
  Future<void> cancelRecording() => _call('cancelRecording');

  @override
  Future<PickedFile?> pickAudioFile() async {
    final m = await _call<Map<Object?, Object?>>('pickAudioFile');
    return m == null ? null : PickedFile(uri: m['uri'] as String, name: m['name'] as String?);
  }

  @override
  Future<AudioProbe> probeAudio(String uri) async {
    final m = (await _call<Map<Object?, Object?>>('probeAudio', {'uri': uri}))!;
    return AudioProbe(durationMs: (m['durationMs'] as num).toInt(), name: m['name'] as String?);
  }

  @override
  Future<List<double>> audioWaveform(String uri, {int buckets = 160}) async {
    final list = await _call<List<Object?>>('audioWaveform', {'uri': uri, 'buckets': buckets});
    return (list ?? const []).map((e) => (e as num).toDouble()).toList();
  }

  @override
  Future<EncodedSample> encodeSegment(String uri, {required int startMs, required int durationMs}) async =>
      EncodedSample.fromMap((await _call<Map<Object?, Object?>>(
          'encodeSegment', {'uri': uri, 'startMs': startMs, 'durationMs': durationMs}))!);

  @override
  Future<bool> previewPlay(String uri, {required int startMs, required int durationMs}) async =>
      await _call<bool>('previewPlay', {'uri': uri, 'startMs': startMs, 'durationMs': durationMs}) ?? false;

  @override
  Future<void> previewStop() => _call('previewStop');

  @override
  Future<bool> openUrl(String url, {String? androidPackage}) async =>
      await _call<bool>('openUrl', {'url': url, 'package': androidPackage}) ?? false;

  @override
  Future<void> shareText(String text, {String? title}) => _call('shareText', {'text': text, 'title': title});

  @override
  Future<Set<String>> installedPackages(List<String> packages) async {
    final list = await _call<List<Object?>>('installedPackages', {'packages': packages});
    return (list ?? const []).cast<String>().toSet();
  }

  @override
  Future<bool> isOnline() async => await _call<bool>('isOnline') ?? true;

  @override
  Future<void> notify(String title, String body, {int? historyId}) =>
      _call('notify', {'title': title, 'body': body, 'historyId': historyId});

  @override
  Future<bool> requestNotificationPermission() async => await _call<bool>('requestNotificationPermission') ?? false;

  @override
  Future<bool> integrityPrepare(String cloudProjectNumber) async =>
      await _call<bool>('integrityPrepare', {'cloudProjectNumber': cloudProjectNumber}) ?? false;

  @override
  Future<String?> integrityToken(String requestHash) => _call<String>('integrityToken', {'requestHash': requestHash});

  @override
  Future<bool> playbackCaptureSupported() async {
    try {
      return await _call<bool>('playbackCaptureSupported') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> startPlaybackCapture() async => await _call<bool>('startPlaybackCapture') ?? false;

  @override
  Future<int> requestAddQuickSettingsTile() async =>
      await _call<int>('requestAddQuickSettingsTile') ?? QuickTileResult.unavailable;

  @override
  Future<void> finishBackgroundTask() => _call('finishBackgroundTask');

  @override
  Future<GoogleAuthorization?> googleAuthorize({
    required bool interactive,
    String? email,
    String? invalidToken,
    String? iosClientId,
  }) async =>
      GoogleAuthorization.fromMap(await _call<Map<Object?, Object?>>('googleAuthorize', {
        'interactive': interactive,
        'email': email,
        'invalidToken': invalidToken,
        'iosClientId': iosClientId,
      }));

  @override
  Future<void> googleSignOut({String? email, String? accessToken, String? iosClientId}) =>
      _call('googleSignOut', {'email': email, 'accessToken': accessToken, 'iosClientId': iosClientId});
}
