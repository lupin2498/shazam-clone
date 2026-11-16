import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../models/history_entry.dart';
import '../models/recognition.dart';
import '../services/app_services.dart';
import '../services/native_bridge.dart';
import '../services/recognizer.dart';
import '../widgets/common.dart';
import 'listening_screen.dart';
import 'outcome_screens.dart';
import 'result_screen.dart';
import 'trim_screen.dart';

/// Tap on the listen button: explain and ask for the microphone the first time (section 10),
/// then open the listening screen.
Future<void> startListening(BuildContext context, ListenMode mode, {bool replace = false}) async {
  final services = AppScope.of(context);
  final native = services.native;
  if (!await native.hasMicPermission()) {
    if (!context.mounted) return;
    if (!services.settings.micExplained) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.mic),
          title: const Text(S.micTitle),
          content: const Text(S.micRationale),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.notNow)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.allow)),
          ],
        ),
      );
      if (ok != true) return;
      await services.settings.markMicExplained();
    }
    final granted = await native.requestMicPermission();
    if (!granted) {
      if (!context.mounted) return;
      final permanentlyDenied = !await native.shouldShowMicRationale();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(S.micDenied),
        action: permanentlyDenied ? SnackBarAction(label: S.openSettings, onPressed: native.openAppSettings) : null,
      ));
      return;
    }
  }
  if (!context.mounted) return;
  final route = MaterialPageRoute<void>(builder: (_) => ListeningScreen(mode: mode));
  if (replace) {
    await Navigator.of(context).pushReplacement(route);
  } else {
    await Navigator.of(context).push(route);
  }
}

/// "Chọn file": system picker (no storage permission), then the trim screen.
Future<void> pickAndTrim(BuildContext context) async {
  final native = AppScope.of(context).native;
  PickedFile? file;
  try {
    file = await native.pickAudioFile();
  } catch (_) {
    if (context.mounted) showSnack(context, S.fileError);
    return;
  }
  if (file == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrimScreen(file: file!)));
}

void openResult(BuildContext context, HistoryEntry entry, {bool replace = false}) {
  final route = MaterialPageRoute<void>(builder: (_) => ResultScreen(entry: entry));
  replace ? Navigator.of(context).pushReplacement(route) : Navigator.of(context).push(route);
}

/// Screen for a recognition outcome; null when there is nothing to show (cancelled).
Route<void>? outcomeRoute(ListenOutcome outcome, {required String source}) => switch (outcome) {
      Matched(:final entry) => MaterialPageRoute<void>(builder: (_) => ResultScreen(entry: entry)),
      Candidates(:final result) =>
        MaterialPageRoute<void>(builder: (_) => CandidatesScreen(result: result, source: source)),
      Cancelled() => null,
      _ => MaterialPageRoute<void>(builder: (_) => OutcomeScreen(outcome: outcome, source: source)),
    };

/// Shows the outcome, replacing the current screen (listening) or on top of it (trim).
void showOutcome(BuildContext context, ListenOutcome outcome, {required String source, bool replace = true}) {
  final route = outcomeRoute(outcome, source: source);
  final navigator = Navigator.of(context);
  if (route == null) {
    if (replace) navigator.maybePop();
  } else if (replace) {
    navigator.pushReplacement(route);
  } else {
    navigator.push(route);
  }
}

/// User picked one of the candidates: save it and show its links.
Future<void> chooseCandidate(BuildContext context, RecognitionResult result, Candidate c, String source) async {
  final services = AppScope.of(context);
  final entry = await services.history.add(HistoryEntry(
    track: c.track,
    source: source,
    createdAt: DateTime.now(),
    recognitionId: result.id,
    flags: c.flags,
    confidence: c.confidence,
  ));
  if (context.mounted) openResult(context, entry, replace: true);
}
