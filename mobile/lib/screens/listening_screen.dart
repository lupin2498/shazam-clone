import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../services/app_services.dart';
import '../services/recognizer.dart';
import '../widgets/waveform.dart';
import 'flows.dart';

/// "Đang nghe": waveform, elapsed time and a cancel button (section 3).
class ListeningScreen extends StatefulWidget {
  const ListeningScreen({super.key, required this.mode});

  final ListenMode mode;

  @override
  State<ListeningScreen> createState() => _ListeningScreenState();
}

class _ListeningScreenState extends State<ListeningScreen> {
  ListenSession? _session;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session != null) return;
    final s = AppScope.of(context);
    final session = ListenSession(
      native: s.native,
      api: s.api,
      config: s.config.value.sample,
      mode: widget.mode,
      results: s.results,
      pending: s.pending,
    );
    _session = session;
    session.start().then((outcome) {
      if (!mounted || outcome is Cancelled) return;
      showOutcome(context, outcome, source: widget.mode == ListenMode.hum ? 'hum' : 'mic');
    });
  }

  @override
  void dispose() {
    _session?.cancel();
    _session?.dispose();
    super.dispose();
  }

  String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = _session!;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) session.cancel();
      },
      child: Scaffold(
        backgroundColor: scheme.primary,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: session,
            builder: (context, _) {
              final searching = session.phase == ListenPhase.searching;
              final title = searching
                  ? S.searching
                  : (widget.mode == ListenMode.hum ? S.listeningHum : S.listening);
              final progress = session.elapsed.inMilliseconds / (session.totalSeconds * 1000);
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Spacer(),
                    Text(title,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: scheme.onPrimary)),
                    const SizedBox(height: 8),
                    Text(widget.mode == ListenMode.hum ? S.tapToHum : S.holdNear,
                        style: TextStyle(color: scheme.onPrimary.withValues(alpha: 0.8))),
                    const SizedBox(height: 40),
                    if (searching)
                      SizedBox(
                        height: 120,
                        child: Center(child: CircularProgressIndicator(color: scheme.onPrimary)),
                      )
                    else
                      LiveWaveform(levels: session.levels),
                    const SizedBox(height: 24),
                    LinearProgressIndicator(
                      value: searching ? null : progress.clamp(0, 1),
                      color: scheme.onPrimary,
                      backgroundColor: scheme.onPrimary.withValues(alpha: 0.2),
                    ),
                    const SizedBox(height: 8),
                    Text(_clock(session.elapsed),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(color: scheme.onPrimary)),
                    const Spacer(),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.onPrimary,
                        side: BorderSide(color: scheme.onPrimary),
                        minimumSize: const Size(160, 48),
                      ),
                      onPressed: () {
                        session.cancel();
                        Navigator.of(context).maybePop();
                      },
                      icon: const Icon(Icons.close),
                      label: const Text(S.cancel),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
