import 'package:flutter/foundation.dart';

import '../config.dart';
import '../l10n/strings.dart';
import '../models/app_config.dart';
import 'api_client.dart';
import 'app_services.dart';
import 'history.dart';
import 'integrity.dart';
import 'native_bridge.dart';
import 'pending_queue.dart';
import 'recognizer.dart';
import 'settings_store.dart';

/// "Nhạc đang phát trên máy" (Android 10+), in the headless engine PlaybackCaptureService starts
/// once the user tapped the Quick Settings tile and accepted the capture.
///
/// Same listening session as the "Nghe" button (6 s probe, 12 s sample, silence check, offline
/// queue), over the audio other apps play instead of the microphone. The result is saved in the
/// history and reported as a notification; tapping it opens the entry in the app.
Future<void> playbackCaptureEntry(NativeBridge native) async {
  try {
    final settings = await SettingsStore.load();
    final integrity = IntegrityService(native);
    final api = ApiClient(
      baseUrl: defaultApiBaseUrl(),
      baseUrlOverride: () => settings.serverOverride,
      deviceId: () => settings.deviceId,
      integrity: integrity,
    );
    HistoryDb db;
    try {
      db = await SqliteHistoryDb.open();
    } catch (e) {
      debugPrint('SQLite unavailable, background result kept in memory: $e');
      db = MemoryHistoryDb();
    }
    // The last /v1/config the app received: no extra request before listening.
    final config = ConfigRepository(api, settings).value;
    await integrity.prepare(config.cloudProjectNumber);
    await runPlaybackRecognition(
      native: native,
      api: api,
      settings: settings,
      history: HistoryRepository(db),
      config: config.sample,
    );
  } catch (e) {
    debugPrint('Background recognition failed: $e');
    await _safeNotify(native, S.bgFailedTitle, S.genericError);
  } finally {
    await native.finishBackgroundTask();
  }
}

/// One background recognition; returns its outcome after notifying it.
Future<ListenOutcome> runPlaybackRecognition({
  required NativeBridge native,
  required ApiClient api,
  required SettingsStore settings,
  required HistoryRepository history,
  required SampleConfig config,
}) async {
  final session = ListenSession(
    native: native,
    api: api,
    config: config,
    mode: ListenMode.listen,
    results: ResultHandler(history),
    pending: PendingQueue(native: native, api: api, history: history, settings: settings),
    source: 'playback',
  );
  ListenOutcome outcome;
  try {
    outcome = await session.start();
  } catch (e) {
    debugPrint('Background listening failed: $e');
    outcome = const Failed(S.genericError);
  } finally {
    session.dispose();
  }
  final (title, body, historyId) = describeBackgroundOutcome(outcome);
  if (title != null) await _safeNotify(native, title, body, historyId: historyId);
  return outcome;
}

/// Notification for a background recognition: (title, body, history id to open). No title when
/// nothing should be shown (cancelled from the notification).
@visibleForTesting
(String?, String, int?) describeBackgroundOutcome(ListenOutcome outcome) => switch (outcome) {
      Matched(:final result, :final entry) => (
          S.notifyMatchedTitle,
          S.notifyMatched(result.top!.track.title, result.top!.track.artistLine),
          entry.id,
        ),
      Candidates(:final result) => (
          S.candidatesTitle,
          result.candidates.take(3).map((c) => S.notifyMatched(c.track.title, c.track.artistLine)).join('\n'),
          null,
        ),
      NoMatch() => (S.notifyNoMatchTitle, S.bgNoMatchBody, null),
      Silent() => (S.bgSilentTitle, S.bgSilentBody, null),
      SavedOffline() => (S.savedOffline, S.savedOfflineHint, null),
      Failed(:final message) => (S.bgFailedTitle, message, null),
      Cancelled() => (null, '', null),
    };

Future<void> _safeNotify(NativeBridge native, String title, String body, {int? historyId}) async {
  try {
    await native.notify(title, body, historyId: historyId);
  } catch (e) {
    debugPrint('Notification failed: $e');
  }
}
