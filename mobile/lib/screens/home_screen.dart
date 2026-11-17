import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../l10n/strings.dart';
import '../services/app_services.dart';
import '../services/native_bridge.dart';
import '../services/recognizer.dart';
import '../widgets/common.dart';
import '../widgets/waveform.dart';
import 'flows.dart';
import 'history_screen.dart';
import 'result_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'trim_screen.dart';

bool isOutdated(String current, String minimum) {
  List<int> parts(String v) => RegExp(r'\d+').allMatches(v).map((m) => int.parse(m[0]!)).take(3).toList();
  final a = parts(current), b = parts(minimum);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x < y;
  }
  return false;
}

/// "Trang chủ": listen button, "Chọn file", Nghe / Ngân nga switch and the 3 latest results.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ListenMode _mode = ListenMode.listen;
  StreamSubscription<PickedFile>? _shared;
  StreamSubscription<int>? _taps;
  AppLifecycleListener? _lifecycle;

  /// "OK" on the outdated-app banner hides it until the app is started again.
  bool _outdatedDismissed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Files shared from other apps ("Chia sẻ" → Tìm Nhạc) go straight to the trim screen.
    _shared ??= AppScope.of(context).native.sharedFiles.listen((file) {
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrimScreen(file: file)));
    });
    // A result notification (background recognition, offline queue) opens its entry.
    _taps ??= AppScope.of(context).native.notificationTaps.listen(_openEntry, onError: (Object _) {});
    final services = AppScope.of(context);
    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(services.onResume()));
  }

  Future<void> _openEntry(int id) async {
    final history = AppScope.of(context).history;
    await history.load(); // saved by the background engine while this list was in memory
    if (!mounted) return;
    final entry = history.entries.where((e) => e.id == id).firstOrNull;
    if (entry == null) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ResultScreen(entry: entry)));
  }

  @override
  void dispose() {
    _shared?.cancel();
    _taps?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final onPrimary = scheme.onPrimary;
    return Scaffold(
      backgroundColor: scheme.primary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: onPrimary,
        title: const Text(S.appName),
        actions: [
          IconButton(tooltip: S.searchByName, onPressed: () => _push(const SearchScreen()), icon: const Icon(Icons.search)),
          IconButton(tooltip: S.history, onPressed: () => _push(const HistoryScreen()), icon: const Icon(Icons.history)),
          IconButton(tooltip: S.settings, onPressed: () => _push(const SettingsScreen()), icon: const Icon(Icons.settings)),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([services.history, services.config]),
          builder: (context, _) {
            final recent = services.history.recent;
            final outdated =
                !_outdatedDismissed && isOutdated(kAppVersion, services.config.value.minAppVersion);
            return Column(
              children: [
                if (outdated)
                  MaterialBanner(
                    content: const Text(S.appOutdated),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _outdatedDismissed = true),
                        child: const Text(S.ok),
                      ),
                    ],
                  ),
                if (services.history.pendingCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ActionChip(
                      avatar: const Icon(Icons.cloud_upload_outlined, size: 18),
                      label: Text(S.pendingChip(services.history.pendingCount)),
                      onPressed: () => _push(const HistoryScreen()),
                    ),
                  ),
                const SizedBox(height: 12),
                SegmentedButton<ListenMode>(
                  style: SegmentedButton.styleFrom(
                    foregroundColor: onPrimary,
                    selectedForegroundColor: scheme.primary,
                    selectedBackgroundColor: onPrimary,
                    side: BorderSide(color: onPrimary.withValues(alpha: 0.6)),
                  ),
                  segments: const [
                    ButtonSegment(value: ListenMode.listen, icon: Icon(Icons.hearing), label: Text(S.modeListen)),
                    ButtonSegment(value: ListenMode.hum, icon: Icon(Icons.record_voice_over), label: Text(S.modeHum)),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                Expanded(
                  child: LayoutBuilder(builder: (context, constraints) {
                    // The button shrinks on short screens so the recent list stays visible.
                    final size = ((constraints.maxHeight - 110) / 1.5).clamp(96.0, 200.0);
                    return Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListenButton(
                              size: size,
                              icon: _mode == ListenMode.hum ? Icons.record_voice_over : Icons.graphic_eq,
                              onPressed: () => startListening(context, _mode),
                            ),
                            Text(
                              _mode == ListenMode.hum ? S.tapToHum : S.tapToListen,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: onPrimary),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: onPrimary,
                                side: BorderSide(color: onPrimary.withValues(alpha: 0.8)),
                              ),
                              onPressed: () => pickAndTrim(context),
                              icon: const Icon(Icons.audio_file),
                              label: const Text(S.pickFile),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
                if (recent.isNotEmpty)
                  Material(
                    color: scheme.surface,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          title: Text(S.recent, style: Theme.of(context).textTheme.titleMedium),
                          trailing: TextButton(
                            onPressed: () => _push(const HistoryScreen()),
                            child: const Text(S.seeAll),
                          ),
                        ),
                        for (final e in recent)
                          TrackTile(track: e.track, onTap: () => openResult(context, e)),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
