import 'dart:math';

import 'package:material_ui/material_ui.dart';

/// Live level bars while listening ("Đang nghe": sóng âm).
class LiveWaveform extends StatelessWidget {
  const LiveWaveform({super.key, required this.levels, this.height = 120, this.color});

  final List<double> levels;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _LivePainter(List.of(levels), color ?? Theme.of(context).colorScheme.onPrimary),
      ),
    );
  }
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.levels, this.color);

  final List<double> levels;
  final Color color;
  static const bars = 40;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.width / bars * 0.55;
    final step = size.width / bars;
    for (var i = 0; i < bars; i++) {
      final idx = levels.length - bars + i;
      final level = idx >= 0 && idx < levels.length ? levels[idx] : 0.0;
      final h = max(4.0, level * size.height);
      final x = step * (i + 0.5);
      canvas.drawLine(Offset(x, size.height / 2 - h / 2), Offset(x, size.height / 2 + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}

/// Whole-file waveform with a draggable selection window (trim screen).
class FileWaveform extends StatelessWidget {
  const FileWaveform({
    super.key,
    required this.peaks,
    required this.durationMs,
    required this.startMs,
    required this.lengthMs,
    required this.onChanged,
    this.minLengthMs = 10000,
    this.maxLengthMs = 15000,
    this.height = 140,
  });

  final List<double> peaks;
  final int durationMs;
  final int startMs;
  final int lengthMs;
  final int minLengthMs;
  final int maxLengthMs;
  final double height;

  /// New (start, length) in milliseconds.
  final void Function(int startMs, int lengthMs) onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      double toX(int ms) => durationMs == 0 ? 0 : ms / durationMs * width;
      int toMs(double dx) => (dx / width * durationMs).round();
      final left = toX(startMs);
      final right = toX(startMs + lengthMs);

      void move(double dx) {
        final newStart = (startMs + toMs(dx)).clamp(0, max(0, durationMs - lengthMs)).toInt();
        onChanged(newStart, lengthMs);
      }

      void resizeRight(double dx) {
        final len = (lengthMs + toMs(dx)).clamp(minLengthMs, maxLengthMs).toInt();
        onChanged(startMs, min(len, durationMs - startMs));
      }

      void resizeLeft(double dx) {
        final end = startMs + lengthMs;
        final newStart = (startMs + toMs(dx)).clamp(max(0, end - maxLengthMs), max(0, end - minLengthMs)).toInt();
        onChanged(newStart, end - newStart);
      }

      return SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _PeaksPainter(peaks, scheme.primary.withValues(alpha: 0.35), scheme.primary, left, right),
              ),
            ),
            Positioned(
              left: left,
              width: max(right - left, 24),
              top: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (d) => move(d.delta.dx),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    border: Border.all(color: scheme.primary, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            _Handle(x: left - 14, onDrag: resizeLeft, color: scheme.primary),
            _Handle(x: right - 14, onDrag: resizeRight, color: scheme.primary),
          ],
        ),
      );
    });
  }
}

class _Handle extends StatelessWidget {
  const _Handle({required this.x, required this.onDrag, required this.color});

  final double x;
  final void Function(double dx) onDrag;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: x,
      top: 0,
      bottom: 0,
      width: 28,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: Center(
          child: Container(
            width: 8,
            height: 40,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
          ),
        ),
      ),
    );
  }
}

class _PeaksPainter extends CustomPainter {
  _PeaksPainter(this.peaks, this.dim, this.bright, this.selLeft, this.selRight);

  final List<double> peaks;
  final Color dim;
  final Color bright;
  final double selLeft;
  final double selRight;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    if (peaks.isEmpty) {
      canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = dim..strokeWidth = 2);
      return;
    }
    final step = size.width / peaks.length;
    final paint = Paint()..strokeWidth = max(1.0, step * 0.6);
    final top = peaks.reduce(max);
    final scale = top <= 0 ? 1.0 : 1 / top;
    for (var i = 0; i < peaks.length; i++) {
      final x = step * (i + 0.5);
      final h = max(2.0, peaks[i] * scale * (size.height - 8));
      paint.color = x >= selLeft && x <= selRight ? bright : dim;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_PeaksPainter old) =>
      old.peaks != peaks || old.selLeft != selLeft || old.selRight != selRight || old.bright != bright;
}

/// The big round listen button with a pulse animation.
class ListenButton extends StatefulWidget {
  const ListenButton({super.key, required this.onPressed, required this.icon, this.size = 200});

  final VoidCallback onPressed;
  final IconData icon;
  final double size;

  @override
  State<ListenButton> createState() => _ListenButtonState();
}

class _ListenButtonState extends State<ListenButton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    return SizedBox(
      width: size * 1.5,
      height: size * 1.5,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => Container(
              width: size * (1 + _pulse.value * 0.45),
              height: size * (1 + _pulse.value * 0.45),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.onPrimary.withValues(alpha: 0.18 * (1 - _pulse.value)),
              ),
            ),
          ),
          Semantics(
            button: true,
            label: 'Nhận diện bài hát',
            child: Material(
              shape: const CircleBorder(),
              color: scheme.onPrimary,
              elevation: 8,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onPressed,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Icon(widget.icon, size: size * 0.45, color: scheme.primary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
