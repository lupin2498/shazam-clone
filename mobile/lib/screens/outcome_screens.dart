import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../models/recognition.dart';
import '../services/recognizer.dart';
import '../widgets/common.dart';
import 'flows.dart';
import 'search_screen.dart';

/// "Nhiều ứng viên": up to 3 candidates with their confidence (section 3).
class CandidatesScreen extends StatelessWidget {
  const CandidatesScreen({super.key, required this.result, required this.source});

  final RecognitionResult result;
  final String source;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(S.candidatesTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(S.candidatesHint),
          const SizedBox(height: 12),
          for (final c in result.candidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CandidateTile(candidate: c, onTap: () => chooseCandidate(context, result, c, source)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TrackLabels(track: c.track, flags: c.flags),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => Navigator.of(context)
                .pushReplacement(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
            icon: const Icon(Icons.search),
            label: const Text(S.tipSearch),
          ),
        ],
      ),
    );
  }
}

/// No match, silence, offline queue or error, each with its way out (section 3).
class OutcomeScreen extends StatelessWidget {
  const OutcomeScreen({super.key, required this.outcome, required this.source});

  final ListenOutcome outcome;
  final String source;

  bool get _fromMic => source == 'mic' || source == 'hum';

  @override
  Widget build(BuildContext context) {
    final retry = _fromMic
        ? FilledButton.icon(
            onPressed: () =>
                startListening(context, source == 'hum' ? ListenMode.hum : ListenMode.listen, replace: true),
            icon: const Icon(Icons.refresh),
            label: const Text(S.tryAgain),
          )
        : FilledButton.icon(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.content_cut),
            label: const Text(S.tryAgain),
          );
    final search = OutlinedButton.icon(
      onPressed: () =>
          Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
      icon: const Icon(Icons.search),
      label: const Text(S.tipSearch),
    );
    final hum = OutlinedButton.icon(
      onPressed: () => startListening(context, ListenMode.hum, replace: true),
      icon: const Icon(Icons.record_voice_over),
      label: const Text(S.tipHum),
    );

    final Widget body = switch (outcome) {
      NoMatch() => MessageView(
          icon: Icons.search_off,
          title: S.noMatch,
          body: '${S.noMatchHint}\n\n• ${S.tipCloser}\n• ${S.tipHum}\n• ${S.tipSearch}',
          actions: [retry, if (source != 'hum') hum, search],
        ),
      Silent() => MessageView(icon: Icons.volume_off, title: S.silent, body: S.silentHint, actions: [retry]),
      SavedOffline() => MessageView(
          icon: Icons.cloud_off,
          title: S.savedOffline,
          body: S.savedOfflineHint,
          actions: [FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('OK'))],
        ),
      Failed(:final message) =>
        MessageView(icon: Icons.error_outline, title: S.genericError, body: message, actions: [retry, search]),
      _ => const SizedBox.shrink(),
    };
    return Scaffold(appBar: AppBar(), body: body);
  }
}
