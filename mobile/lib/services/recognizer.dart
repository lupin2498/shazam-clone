import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import '../models/app_config.dart';
import '../models/history_entry.dart';
import '../models/recognition.dart';
import 'api_client.dart';
import 'history.dart';
import 'native_bridge.dart';
import 'pending_queue.dart';

enum ListenMode { listen, hum }

sealed class ListenOutcome {
  const ListenOutcome();
}

/// One song recognised; already saved to history.
class Matched extends ListenOutcome {
  const Matched(this.result, this.entry);
  final RecognitionResult result;
  final HistoryEntry entry;
}

/// Up to 3 candidates (cover / no-vocals / humming): the user picks one.
class Candidates extends ListenOutcome {
  const Candidates(this.result);
  final RecognitionResult result;
}

class NoMatch extends ListenOutcome {
  const NoMatch();
}

/// The sample was almost silent and was not sent (saves engine calls).
class Silent extends ListenOutcome {
  const Silent();
}

/// No network: the sample was queued (F7).
class SavedOffline extends ListenOutcome {
  const SavedOffline();
}

class Failed extends ListenOutcome {
  const Failed(this.message);
  final String message;
}

class Cancelled extends ListenOutcome {
  const Cancelled();
}

enum ListenPhase { starting, listening, searching, done }

/// Turns a recognition result into history and an outcome. Shared by the
/// microphone, file and offline-queue paths.
class ResultHandler {
  ResultHandler(this.history);

  final HistoryRepository history;

  Future<ListenOutcome> handle(RecognitionResult r, {required String source}) async {
    switch (r.status) {
      case RecognitionStatus.matched:
        final top = r.top;
        if (top == null) return const NoMatch(); // "matched" without a candidate
        final entry = HistoryEntry(
          track: top.track,
          source: source,
          createdAt: DateTime.now(),
          recognitionId: r.id,
          flags: top.flags,
          confidence: top.confidence,
        );
        try {
          return Matched(r, await history.add(entry));
        } catch (e) {
          // The song was found: a storage problem must not take the result away.
          debugPrint('history not saved: $e');
          return Matched(r, entry);
        }
      case RecognitionStatus.candidates:
        return Candidates(r);
      case RecognitionStatus.noMatch:
        return const NoMatch();
    }
  }
}

String newSessionId() {
  final rnd = Random.secure();
  return List.generate(12, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// One tap on the listen button (section 3 and 5):
///  * records up to 12 s (15 s when humming) while showing the waveform;
///  * at 6 s sends a first probe; a confident match stops listening early;
///  * at the end sends the full sample, which the backend runs through the engine cascade;
///  * near-silent samples are not sent; without network the sample is queued.
class ListenSession extends ChangeNotifier {
  ListenSession({
    required this.native,
    required this.api,
    required this.config,
    required this.mode,
    required this.results,
    required this.pending,
    String? source,
  }) : _sourceOverride = source;

  final NativeBridge native;
  final ApiClient api;
  final SampleConfig config;
  final ListenMode mode;

  /// `playback` when the "microphone" is the audio other apps play (Android background capture).
  final String? _sourceOverride;
  final ResultHandler results;
  final PendingQueue pending;

  final String sessionId = newSessionId();
  final List<double> levels = [];
  ListenPhase phase = ListenPhase.starting;
  Duration elapsed = Duration.zero;
  ListenOutcome? outcome;

  final _done = Completer<ListenOutcome>();
  Future<ListenOutcome> get done => _done.future;

  Timer? _ticker;
  StreamSubscription<double>? _levelSub;
  int _ticks = 0;
  bool _earlySent = false;
  bool _stopping = false;

  int get totalSeconds => mode == ListenMode.hum ? config.humS : config.fullS;
  String get _modeWire => mode == ListenMode.hum ? 'hum' : 'auto';
  String get _source => _sourceOverride ?? (mode == ListenMode.hum ? 'hum' : 'mic');
  bool get isClosed => _done.isCompleted;

  Future<ListenOutcome> start() async {
    bool started;
    try {
      started = await native.startRecording(maxSeconds: totalSeconds + 1);
    } catch (_) {
      started = false; // permission revoked meanwhile, platform error...
    }
    if (isClosed) return done; // cancelled while the microphone was opening
    if (!started) {
      _finish(Failed(_sourceOverride == 'playback' ? S.playbackStartFailed : S.micBusy));
      return done;
    }
    phase = ListenPhase.listening;
    _levelSub = native.levels.listen((level) {
      levels.add(level);
      if (levels.length > 64) levels.removeAt(0);
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    notifyListeners();
    return done;
  }

  void _tick() {
    if (isClosed) return;
    _ticks++;
    elapsed = Duration(milliseconds: _ticks * 100);
    if (mode == ListenMode.listen && !_earlySent && elapsed.inMilliseconds >= config.earlyProbeS * 1000) {
      _earlySent = true;
      unawaited(_sendEarly());
    }
    if (elapsed.inMilliseconds >= totalSeconds * 1000) unawaited(_stopAndSend());
    notifyListeners();
  }

  Future<void> _sendEarly() async {
    final RecognitionResult r;
    try {
      final sample = await native.snapshotRecording(maxMs: config.earlyProbeS * 1000);
      if (isClosed || _stopping || sample.rms < config.silenceRms || sample.aac.isEmpty) return;
      r = await api.recognize(
          audio: sample.aac, mode: 'auto', source: _source, stage: 'early', sessionId: sessionId);
    } catch (_) {
      return; // The probe is best effort; the full sample decides.
    }
    if (isClosed || r.status != RecognitionStatus.matched) return;
    // This probe now ends the session (the ticker is stopped, the full sample will not be
    // sent): from here on every path must reach _finish, or the screen listens forever.
    _stopping = true;
    _ticker?.cancel();
    try {
      await native.cancelRecording();
    } catch (_) {}
    await _complete(r);
  }

  /// Ends listening and sends what was recorded.
  Future<void> _stopAndSend() async {
    if (_stopping || isClosed) return;
    _stopping = true;
    _ticker?.cancel();
    try {
      final sample = await native.stopRecording();
      if (isClosed) return;
      phase = ListenPhase.searching;
      notifyListeners();
      if (sample.rms < config.silenceRms || sample.aac.isEmpty) {
        _finish(const Silent());
        return;
      }
      await _sendFull(sample.aac);
    } catch (_) {
      // Encoder or storage failure. The ticker is already stopped, so nothing else would
      // ever end the session: report the failure instead of spinning forever.
      _finish(const Failed(S.genericError));
    }
  }

  Future<void> _sendFull(Uint8List aac) async {
    if (!await native.isOnline()) {
      await pending.save(aac, mode: _modeWire, source: _source);
      _finish(const SavedOffline());
      return;
    }
    try {
      final r = await api.recognize(audio: aac, mode: _modeWire, source: _source, stage: 'full', sessionId: sessionId);
      if (isClosed) return;
      await _complete(r);
    } on ApiException catch (e) {
      if (isClosed) return;
      if (e.isNetwork) {
        await pending.save(aac, mode: _modeWire, source: _source);
        _finish(const SavedOffline());
      } else {
        _finish(Failed(e.message));
      }
    }
  }

  Future<void> _complete(RecognitionResult r) async {
    if (isClosed) return;
    ListenOutcome outcome;
    try {
      outcome = await results.handle(r, source: _source);
    } catch (_) {
      outcome = const Failed(S.genericError);
    }
    _finish(outcome);
  }

  void cancel() {
    if (isClosed) return;
    _ticker?.cancel();
    unawaited(native.cancelRecording().catchError((Object _) {}));
    _finish(const Cancelled());
  }

  void _finish(ListenOutcome o) {
    if (isClosed) return;
    outcome = o;
    phase = ListenPhase.done;
    _ticker?.cancel();
    _levelSub?.cancel();
    _done.complete(o);
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _levelSub?.cancel();
    super.dispose();
  }
}

/// Recognises a sample cut from a file (F2).
Future<ListenOutcome> recognizeFileSample({
  required NativeBridge native,
  required ApiClient api,
  required ResultHandler results,
  required PendingQueue pending,
  required EncodedSample sample,
  required SampleConfig config,
  String? filenameHint,
}) async {
  if (sample.rms < config.silenceRms || sample.aac.isEmpty) return const Silent();
  if (!await native.isOnline()) {
    await pending.save(sample.aac, mode: 'auto', source: 'file', filenameHint: filenameHint);
    return const SavedOffline();
  }
  try {
    final r = await api.recognize(
        audio: sample.aac, mode: 'auto', source: 'file', stage: 'full', filenameHint: filenameHint);
    return await results.handle(r, source: 'file');
  } on ApiException catch (e) {
    if (e.isNetwork) {
      await pending.save(sample.aac, mode: 'auto', source: 'file', filenameHint: filenameHint);
      return const SavedOffline();
    }
    return Failed(e.message);
  }
}
