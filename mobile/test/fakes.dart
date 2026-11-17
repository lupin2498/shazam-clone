import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tim_nhac/models/app_config.dart';
import 'package:tim_nhac/services/api_client.dart';
import 'package:tim_nhac/services/app_services.dart';
import 'package:tim_nhac/services/history.dart';
import 'package:tim_nhac/services/integrity.dart';
import 'package:tim_nhac/services/native_bridge.dart';
import 'package:tim_nhac/services/pending_queue.dart';
import 'package:tim_nhac/services/settings_store.dart';

EncodedSample sample({double rms = 0.1, int bytes = 1000, int durationMs = 12000}) =>
    EncodedSample(aac: Uint8List(bytes), rms: rms, durationMs: durationMs);

class FakeNative implements NativeBridge {
  final levelCtrl = StreamController<double>.broadcast();
  final sharedCtrl = StreamController<PickedFile>.broadcast();
  final connectivityCtrl = StreamController<bool>.broadcast();
  final tapCtrl = StreamController<int>.broadcast();

  bool micGranted = true;
  bool online = true;
  bool recordingStarts = true;

  /// Failures injected by tests: thrown by the matching call when set.
  Object? startError, snapshotError, stopError, cancelError, openError, previewStopError;

  /// Completes the permission check later, as a busy device would.
  Completer<void>? micPermissionGate;
  Completer<AudioProbe>? probeGate;
  Completer<bool>? previewGate;

  /// Play Integrity: prepare() succeeds from the Nth call on (0 = never).
  int integrityReadyFromCall = 0;
  int integrityPrepareCalls = 0;
  int integrityTokenCalls = 0;

  /// The next N token requests fail (an expired provider: INTEGRITY_TOKEN_PROVIDER_INVALID).
  int integrityTokenFailures = 0;
  EncodedSample snapshot = sample(durationMs: 6000);
  EncodedSample full = sample();
  final calls = <String>[];
  final opened = <(String, String?)>[];
  final notifications = <(String, String)>[];

  @override
  Stream<double> get levels => levelCtrl.stream;
  @override
  Stream<PickedFile> get sharedFiles => sharedCtrl.stream;
  @override
  Stream<bool> get connectivity => connectivityCtrl.stream;

  @override
  Future<bool> hasMicPermission() async {
    await micPermissionGate?.future;
    return micGranted;
  }
  @override
  Future<bool> shouldShowMicRationale() async => true;
  @override
  Future<bool> requestMicPermission() async => micGranted;
  @override
  Future<void> openAppSettings() async {}

  @override
  Future<bool> startRecording({required int maxSeconds}) async {
    calls.add('start:$maxSeconds');
    if (startError != null) throw startError!;
    return recordingStarts;
  }

  @override
  Future<EncodedSample> snapshotRecording({required int maxMs}) async {
    calls.add('snapshot:$maxMs');
    if (snapshotError != null) throw snapshotError!;
    return snapshot;
  }

  @override
  Future<EncodedSample> stopRecording() async {
    calls.add('stop');
    if (stopError != null) throw stopError!;
    return full;
  }

  @override
  Future<void> cancelRecording() async {
    calls.add('cancel');
    if (cancelError != null) throw cancelError!;
  }

  @override
  Future<PickedFile?> pickAudioFile() async => const PickedFile(uri: 'content://x/1', name: 'song.mp3');
  @override
  Future<AudioProbe> probeAudio(String uri) async {
    calls.add('probe');
    if (probeGate != null) return probeGate!.future;
    return const AudioProbe(durationMs: 200000, name: 'song.mp3');
  }
  @override
  Future<List<double>> audioWaveform(String uri, {int buckets = 160}) async => List.filled(buckets, 0.5);

  @override
  Future<EncodedSample> encodeSegment(String uri, {required int startMs, required int durationMs}) async {
    calls.add('segment:$startMs:$durationMs');
    return sample(durationMs: durationMs);
  }

  @override
  Future<bool> previewPlay(String uri, {required int startMs, required int durationMs}) async {
    calls.add('previewPlay');
    if (previewGate != null) return previewGate!.future;
    return true;
  }

  @override
  Future<void> previewStop() async {
    calls.add('previewStop');
    if (previewStopError != null) throw previewStopError!;
  }

  @override
  Future<bool> openUrl(String url, {String? androidPackage}) async {
    if (openError != null) throw openError!;
    opened.add((url, androidPackage));
    return true;
  }

  @override
  Future<void> shareText(String text, {String? title}) async => calls.add('share');
  @override
  Future<Set<String>> installedPackages(List<String> packages) async => {'com.spotify.music'};
  @override
  Future<bool> isOnline() async => online;

  /// History id attached to each notification, in the same order as [notifications].
  final notificationIds = <int?>[];

  @override
  Future<void> notify(String title, String body, {int? historyId}) async {
    notifications.add((title, body));
    notificationIds.add(historyId);
  }

  @override
  Stream<int> get notificationTaps => tapCtrl.stream;

  bool playbackSupported = false;
  int playbackStarts = 0;
  int tileResult = QuickTileResult.added;
  int finishCalls = 0;

  @override
  Future<bool> playbackCaptureSupported() async => playbackSupported;

  @override
  Future<bool> startPlaybackCapture() async {
    playbackStarts++;
    return playbackSupported;
  }

  @override
  Future<int> requestAddQuickSettingsTile() async => tileResult;

  @override
  Future<void> finishBackgroundTask() async => finishCalls++;

  /// What googleAuthorize answers (null = cancelled / needs the user), or throws [googleError].
  GoogleAuthorization? googleAuth = const GoogleAuthorization(accessToken: 'token-1', email: 'an@example.com');
  Object? googleError;

  /// When set, interactive and silent requests answer differently.
  GoogleAuthorization? Function({required bool interactive, String? invalidToken})? googleAnswer;
  final googleCalls = <({bool interactive, String? email, String? invalidToken, String? iosClientId})>[];
  int googleSignOuts = 0;

  @override
  Future<GoogleAuthorization?> googleAuthorize({
    required bool interactive,
    String? email,
    String? invalidToken,
    String? iosClientId,
  }) async {
    googleCalls.add((interactive: interactive, email: email, invalidToken: invalidToken, iosClientId: iosClientId));
    if (googleError != null) throw googleError!;
    final answer = googleAnswer;
    return answer != null ? answer(interactive: interactive, invalidToken: invalidToken) : googleAuth;
  }

  @override
  Future<void> googleSignOut({String? email, String? accessToken, String? iosClientId}) async => googleSignOuts++;

  @override
  Future<bool> requestNotificationPermission() async => true;
  @override
  Future<bool> integrityPrepare(String cloudProjectNumber) async {
    integrityPrepareCalls++;
    return integrityReadyFromCall > 0 && integrityPrepareCalls >= integrityReadyFromCall;
  }

  @override
  Future<String?> integrityToken(String requestHash) async {
    integrityTokenCalls++;
    if (integrityTokenFailures > 0) {
      integrityTokenFailures--;
      throw StateError('INTEGRITY_TOKEN_PROVIDER_INVALID');
    }
    return 'token-for-$requestHash';
  }
}

Map<String, dynamic> trackJson({String id = 'trk_1', String title = 'Nơi Này Có Anh', bool instrumental = false}) => {
      'id': id,
      'title': title,
      'artists': ['Sơn Tùng M-TP'],
      'album': 'Nơi Này Có Anh',
      'duration_ms': 260000,
      'artwork_url': null,
      'is_instrumental': instrumental,
      'work_title': null,
      'genres': ['Pop'],
    };

Map<String, dynamic> recognitionJson({
  String status = 'matched',
  String stage = 'full',
  bool isFinal = true,
  List<Map<String, dynamic>>? candidates,
}) =>
    {
      'id': 'rec_1',
      'status': status,
      'engine': 'acrcloud',
      'stage': stage,
      'final': isFinal,
      'latency_ms': 900,
      'quota_remaining': 29,
      'candidates': candidates ??
          (status == 'no_match'
              ? []
              : [
                  {'track': trackJson(), 'confidence': 0.95, 'rank': 1, 'flags': <String>[]},
                ]),
    };

http.Response jsonResponse(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// Recorded request: form fields for multipart bodies.
class Recorded {
  Recorded(this.request, this.fields);
  final http.BaseRequest request;
  final Map<String, String> fields;
}

Map<String, String> multipartFields(http.Request r) {
  final body = latin1.decode(r.bodyBytes);
  final fields = <String, String>{};
  final re = RegExp(r'name="([^"]+)"\r\n\r\n([^\r]*)\r\n');
  for (final m in re.allMatches(body)) {
    fields[m[1]!] = m[2]!;
  }
  return fields;
}

Future<AppServices> fakeServices({
  FakeNative? native,
  required Future<http.Response> Function(http.Request) handler,
  http.Client? client,
  HistoryDb? db,
  Duration streamStallTimeout = const Duration(seconds: 20),
}) async {
  SharedPreferences.setMockInitialValues({});
  final bridge = native ?? FakeNative();
  final settings = await SettingsStore.load();
  final integrity = IntegrityService(bridge);
  final api = ApiClient(
    baseUrl: 'http://test',
    baseUrlOverride: () => settings.serverOverride,
    deviceId: () => settings.deviceId,
    integrity: integrity,
    client: client ?? MockClient(handler),
    streamStallTimeout: streamStallTimeout,
  );
  final history = HistoryRepository(db ?? MemoryHistoryDb());
  final config = ConfigRepository(api, settings);
  config.value = AppConfig.defaults;
  return AppServices(
    native: bridge,
    settings: settings,
    api: api,
    history: history,
    pending: PendingQueue(native: bridge, api: api, history: history, settings: settings),
    config: config,
    integrity: integrity,
    httpClient: MockClient(handler),
  );
}
