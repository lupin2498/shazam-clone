import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../models/track.dart';
import '../services/app_services.dart';
import '../services/native_bridge.dart';
import '../services/recognizer.dart';
import '../widgets/common.dart';
import '../widgets/waveform.dart';
import 'flows.dart';
import 'scan_screen.dart';

/// "Cắt đoạn file": whole-file waveform, a 10–15 s window (default 12 s at 30 % of the
/// file to skip silent intros), preview, recognise, or scan the whole file (section 3, 5).
class TrimScreen extends StatefulWidget {
  const TrimScreen({super.key, required this.file});

  final PickedFile file;

  @override
  State<TrimScreen> createState() => _TrimScreenState();
}

class _TrimScreenState extends State<TrimScreen> {
  int? _durationMs;
  List<double> _peaks = const [];
  int _startMs = 0;
  int _lengthMs = 12000;
  bool _busy = false;
  bool _playing = false;
  String? _error;
  Timer? _previewTimer;
  AppServices? _scope;

  AppServices get _services => _scope!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scope != null) return;
    _scope = AppScope.of(context);
    _probe();
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    if (_playing) _stopPreviewQuietly(_services.native);
    super.dispose();
  }

  /// Stops "Nghe thử" without letting a platform error escape (nobody awaits it).
  static void _stopPreviewQuietly(NativeBridge native) {
    unawaited(native.previewStop().catchError((Object _) {}));
  }

  Future<void> _probe() async {
    final sample = _services.config.value.sample;
    try {
      final probe = await _services.native.probeAudio(widget.file.uri);
      if (!mounted) return; // left while a large or remote file was being read
      final duration = probe.durationMs;
      if (duration < 3000) throw StateError('too short');
      final length = min(sample.fileDefaultS * 1000, duration);
      final start = (duration * sample.fileDefaultPosition).round().clamp(0, max(0, duration - length)).toInt();
      setState(() {
        _durationMs = duration;
        _lengthMs = length;
        _startMs = start;
      });
      final peaks = await _services.native.audioWaveform(widget.file.uri, buckets: 160);
      if (mounted) setState(() => _peaks = peaks);
    } catch (_) {
      if (mounted) setState(() => _error = S.fileError);
    }
  }

  Future<void> _togglePreview() async {
    final native = _services.native;
    if (_playing) {
      _previewTimer?.cancel();
      try {
        await native.previewStop();
      } catch (_) {
        // The player is gone or broken: either way it is not playing for this screen any more.
      }
      if (mounted) setState(() => _playing = false);
      return;
    }
    final bool ok;
    try {
      ok = await native.previewPlay(widget.file.uri, startMs: _startMs, durationMs: _lengthMs);
    } catch (_) {
      return;
    }
    if (!mounted) {
      // Left while the platform was starting the player: dispose() saw _playing == false.
      if (ok) _stopPreviewQuietly(native);
      return;
    }
    if (!ok) return;
    setState(() => _playing = true);
    _previewTimer = Timer(Duration(milliseconds: _lengthMs), () {
      if (mounted) setState(() => _playing = false);
    });
  }

  Future<void> _recognize() async {
    if (_playing) await _togglePreview();
    if (!mounted) return;
    setState(() => _busy = true);
    final s = _services;
    try {
      final sample = await s.native.encodeSegment(widget.file.uri, startMs: _startMs, durationMs: _lengthMs);
      final outcome = await recognizeFileSample(
        native: s.native,
        api: s.api,
        results: s.results,
        pending: s.pending,
        sample: sample,
        config: s.config.value.sample,
        filenameHint: widget.file.name,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      // Keep the trim screen underneath so "Thử lại" can pick another segment.
      showOutcome(context, outcome, source: 'file', replace: false);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, S.fileError);
      }
    }
  }

  void _scan() {
    final duration = _durationMs;
    if (duration == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ScanScreen(file: widget.file, durationMs: duration),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sample = _services.config.value.sample;
    final duration = _durationMs;
    return Scaffold(
      appBar: AppBar(title: const Text(S.trimTitle)),
      body: _error != null
          ? MessageView(icon: Icons.error_outline, title: _error!)
          : duration == null
              ? const MessageView(icon: Icons.hourglass_top, title: S.loadingFile)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(widget.file.name ?? '', style: theme.textTheme.titleMedium, maxLines: 2),
                    Text(formatDuration(duration), style: theme.textTheme.bodySmall),
                    const SizedBox(height: 16),
                    const Text(S.trimHint),
                    const SizedBox(height: 12),
                    FileWaveform(
                      peaks: _peaks,
                      durationMs: duration,
                      startMs: _startMs,
                      lengthMs: _lengthMs,
                      minLengthMs: min(sample.fileMinS * 1000, duration),
                      maxLengthMs: min(sample.fileMaxS * 1000, duration),
                      onChanged: (start, length) => setState(() {
                        _startMs = start;
                        _lengthMs = length;
                      }),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${formatDuration(_startMs)} – ${formatDuration(_startMs + _lengthMs)} '
                      '(${(_lengthMs / 1000).round()} giây)',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _togglePreview,
                      icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                      label: Text(_playing ? S.stop : S.preview),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _busy ? null : _recognize,
                      icon: _busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.graphic_eq),
                      label: Text(_busy ? S.searching : S.recognizeSegment),
                    ),
                    if (duration >= sample.scanStepS * 2000) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _busy ? null : _scan,
                        icon: const Icon(Icons.manage_search),
                        label: const Text(S.scanWholeFile),
                      ),
                    ],
                  ],
                ),
    );
  }
}
