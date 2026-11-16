import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../models/app_config.dart';
import '../models/track.dart';
import '../models/track_link.dart';
import '../services/link_sorter.dart';
import 'common.dart';

/// One row of the result list: logo, title found on the platform, duration and a
/// "Chính xác" / "Tìm trên …" label (section 7).
class LinkTile extends StatelessWidget {
  const LinkTile({
    super.key,
    required this.link,
    required this.platform,
    required this.onOpen,
    required this.onReport,
    this.installed = false,
  });

  final TrackLink link;
  final PlatformInfo platform;
  final bool installed;
  final VoidCallback onOpen;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = linkLabel(link, platform);
    final details = <String>[
      platform.name,
      if (link.durationMs != null) formatDuration(link.durationMs),
      if (link.kind == LinkKind.offlineInApp && platform.offlineNote != null) platform.offlineNote!,
      if (link.license != null && !label.contains(link.license!)) link.license!,
    ];
    final title = link.kind == LinkKind.offlineInApp
        ? '${S.openAppOffline} ${platform.name}'
        : (link.exact ? (link.title ?? platform.name) : S.searchOn(platform.name));
    return ListTile(
      leading: PlatformBadge(platform),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(details.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onOpen,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Tag(text: label, exact: link.exact, scheme: theme.colorScheme),
          PopupMenuButton<String>(
            tooltip: S.reportLink,
            onSelected: (_) => onReport(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'report', child: Text(S.reportLink))],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.exact, required this.scheme});

  final String text;
  final bool exact;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final bg = exact ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = exact ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 120),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Text(text,
            style: TextStyle(color: fg, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
