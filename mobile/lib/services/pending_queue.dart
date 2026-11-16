import 'dart:async';
import 'dart:typed_data';

import '../l10n/strings.dart';
import '../models/history_entry.dart';
import '../models/recognition.dart';
import 'api_client.dart';
import 'history.dart';
import 'native_bridge.dart';
import 'settings_store.dart';

/// Samples recorded without network (F7): stored in `pending_sample`, sent when the
/// connection comes back, then deleted. A notification reports the result.
class PendingQueue {
  PendingQueue({required this.native, required this.api, required this.history, required this.settings});

  final NativeBridge native;
  final ApiClient api;
  final HistoryRepository history;
  final SettingsStore settings;

  StreamSubscription<bool>? _sub;
  bool _processing = false;

  void start() {
    _sub ??= native.connectivity.listen((online) {
      if (online) unawaited(process());
    });
    unawaited(process());
  }

  Future<void> dispose() async => _sub?.cancel();

  Future<void> save(Uint8List audio, {required String mode, required String source, String? filenameHint}) async {
    await history.db.insertPending(PendingSample(
      audio: audio,
      mode: mode,
      source: source,
      filenameHint: filenameHint,
      createdAt: DateTime.now(),
    ));
    await history.refreshPendingCount();
    // Section 10: the notification permission is asked only once the offline queue is used.
    if (!settings.notificationsAsked) {
      await settings.markNotificationsAsked();
      try {
        await native.requestNotificationPermission();
      } catch (_) {}
    }
  }

  /// Sends every queued sample. Stops at the first network error.
  Future<void> process() async {
    if (_processing) return;
    _processing = true;
    try {
      for (final sample in await history.db.pending()) {
        try {
          final r = await api.recognize(
            audio: sample.audio,
            mode: sample.mode,
            source: sample.source,
            stage: 'full',
            sessionId: 'pending-${sample.id}-${sample.createdAt.millisecondsSinceEpoch}',
            filenameHint: sample.filenameHint,
          );
          await history.db.deletePending(sample.id!);
          await _report(r, sample);
        } on ApiException catch (e) {
          if (e.isNetwork) break;
          if (_rejectedForGood(e)) {
            // Sending it again can only fail the same way, and it would block every sample
            // queued after it.
            await history.db.deletePending(sample.id!);
          } else {
            // Quota, server trouble, app too old, no server address: keep it for later.
            await history.db.bumpAttempts(sample.id!);
            break;
          }
        }
      }
    } finally {
      _processing = false;
      await history.refreshPendingCount();
    }
  }

  /// The backend refused the sample itself (bad or too large audio, request it cannot read).
  static bool _rejectedForGood(ApiException e) =>
      e.code == 'invalid_sample' || e.code == 'payload_too_large' || e.statusCode == 413 || e.statusCode == 422;

  Future<void> _report(RecognitionResult r, PendingSample sample) async {
    final top = r.top;
    if (top == null || r.status == RecognitionStatus.noMatch) {
      await _notify(S.notifyNoMatchTitle, S.notifyNoMatchBody);
      return;
    }
    try {
      await history.add(HistoryEntry(
        track: top.track,
        source: sample.source,
        createdAt: DateTime.now(),
        recognitionId: r.id,
        flags: top.flags,
        confidence: top.confidence,
      ));
    } catch (_) {
      // Storage full or broken: the sample is already gone, so at least tell the user the
      // song (process() runs unawaited; an error here would also stop the queue).
    }
    await _notify(S.notifyMatchedTitle, S.notifyMatched(top.track.title, top.track.artistLine));
  }

  Future<void> _notify(String title, String body) async {
    try {
      await native.notify(title, body);
    } catch (_) {}
  }
}
