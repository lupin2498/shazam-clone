import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../models/app_config.dart';
import '../models/recognition.dart';
import '../models/track.dart';

/// Coloured round badge with the platform's initials.
/// Official logos must be added per each brand's guidelines before release (section 7).
class PlatformBadge extends StatelessWidget {
  const PlatformBadge(this.platform, {super.key, this.size = 40});

  final PlatformInfo platform;
  final double size;

  String get _initials {
    final words = platform.name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    return platform.name.substring(0, platform.name.length >= 2 ? 2 : 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final fg = platform.color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: platform.color, shape: BoxShape.circle),
      child: Text(
        _initials,
        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: size * 0.36),
      ),
    );
  }
}

class TrackArtwork extends StatelessWidget {
  const TrackArtwork(this.track, {super.key, this.size = 56, this.radius = 8});

  final Track track;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      color: scheme.primaryContainer,
      child: Icon(Icons.music_note, size: size * 0.5, color: scheme.onPrimaryContainer),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: track.artworkUrl == null
          ? placeholder
          : Image.network(
              track.artworkUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}

/// "Không lời", "Có thể là bản beat", "bản cover của…", "Tác phẩm: …" (sections 3 and 5).
class TrackLabels extends StatelessWidget {
  const TrackLabels({super.key, required this.track, this.flags = const []});

  final Track track;
  final List<String> flags;

  @override
  Widget build(BuildContext context) {
    final labels = <(IconData, String)>[
      if (track.isInstrumental) (Icons.piano, S.instrumental),
      if (flags.contains('maybe_beat')) (Icons.graphic_eq, S.maybeBeat),
      if (flags.contains('cover')) (Icons.queue_music, S.coverOf),
      if (flags.contains('melody')) (Icons.record_voice_over, S.melodyMatch),
      if (track.workTitle != null && track.workTitle != track.title) (Icons.menu_book, S.work(track.workTitle!)),
    ];
    if (labels.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final (icon, text) in labels)
          Chip(
            avatar: Icon(icon, size: 16),
            label: Text(text),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class TrackTile extends StatelessWidget {
  const TrackTile({super.key, required this.track, this.subtitle, this.trailing, this.onTap});

  final Track track;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: TrackArtwork(track, size: 48, radius: 6),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle ?? track.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

class CandidateTile extends StatelessWidget {
  const CandidateTile({super.key, required this.candidate, this.onTap});

  final Candidate candidate;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              TrackArtwork(candidate.track, size: 64),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(candidate.track.title, style: Theme.of(context).textTheme.titleMedium),
                    Text(candidate.track.artistLine),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: candidate.confidence.clamp(0, 1)),
                    const SizedBox(height: 4),
                    Text(S.confidence(candidate.confidence), style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.icon, required this.title, this.body, this.actions = const []});

  final IconData icon;
  final String title;
  final String? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(body!, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 24),
            ...actions.map((a) => Padding(padding: const EdgeInsets.only(bottom: 8), child: a)),
          ],
        ),
      ),
    );
  }
}

void showSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
