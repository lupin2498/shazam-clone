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

class AudioProbe {
  const AudioProbe({required this.durationMs, this.name});

  final int durationMs;
  final String? name;
}

/// Everything the app needs from Android. Implemented over platform channels
/// (android/app/src/main/kotlin/vn/timnhac/app/MainActivity.kt) and faked in tests.
abstract class NativeBridge {
  Stream<double> get levels;
  Stream<PickedFile> get sharedFiles;
  Stream<bool> get connectivity;

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
  Future<void> notify(String title, String body);
  Future<bool> requestNotificationPermission();
  Future<bool> integrityPrepare(String cloudProjectNumber);
  Future<String?> integrityToken(String requestHash);
}

class MethodChannelNativeBridge implements NativeBridge {
  static const _channel = MethodChannel('vn.timnhac/native');
  static const _levels = EventChannel('vn.timnhac/levels');
  static const _shared = EventChannel('vn.timnhac/shared_files');
  static const _connectivity = EventChannel('vn.timnhac/connectivity');

  Stream<double>? _levelStream;
  Stream<PickedFile>? _sharedStream;
  Stream<bool>? _connectivityStream;

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
  Future<void> notify(String title, String body) => _call('notify', {'title': title, 'body': body});

  @override
  Future<bool> requestNotificationPermission() async => await _call<bool>('requestNotificationPermission') ?? false;

  @override
  Future<bool> integrityPrepare(String cloudProjectNumber) async =>
      await _call<bool>('integrityPrepare', {'cloudProjectNumber': cloudProjectNumber}) ?? false;

  @override
  Future<String?> integrityToken(String requestHash) => _call<String>('integrityToken', {'requestHash': requestHash});
}
