import '../l10n/strings.dart';
import '../models/app_config.dart';
import '../models/track_link.dart';

class LinkGroups {
  const LinkGroups(this.listen, this.get);

  /// "Nghe"
  final List<TrackLink> listen;

  /// "Tải/Mua": buy, free download, offline download in the official app.
  final List<TrackLink> get;

  bool get hasFreeDownload => get.any((l) => l.kind == LinkKind.freeDownload && l.exact);
}

/// Splits links into the two groups of the result screen and orders them (section 7):
/// the user's preferred platforms first, then apps installed on the phone, then exact
/// matches before search links. Every link is kept: as many sources as were found.
LinkGroups groupLinks(
  Iterable<TrackLink> links, {
  List<String> preferred = const [],
  Set<String> installedPlatforms = const {},
}) {
  final seen = <String>{};
  final unique = <TrackLink>[];
  for (final l in links) {
    if (seen.add('${l.kind.wire}|${l.url}')) unique.add(l);
  }

  int preferredRank(TrackLink l) {
    final i = preferred.indexOf(l.platform);
    return i < 0 ? preferred.length : i;
  }

  int compareListen(TrackLink a, TrackLink b) {
    final byPreferred = preferredRank(a).compareTo(preferredRank(b));
    if (byPreferred != 0) return byPreferred;
    final byInstalled = (installedPlatforms.contains(a.platform) ? 0 : 1)
        .compareTo(installedPlatforms.contains(b.platform) ? 0 : 1);
    if (byInstalled != 0) return byInstalled;
    final byExact = (a.exact ? 0 : 1).compareTo(b.exact ? 0 : 1);
    if (byExact != 0) return byExact;
    return b.score.compareTo(a.score);
  }

  // Real items to download or buy first, then the official apps' offline download,
  // then search pages ("Tìm trên Bandcamp").
  int tier(TrackLink l) => l.kind == LinkKind.offlineInApp ? 1 : (l.exact ? 0 : 2);
  const kindOrder = {LinkKind.freeDownload: 0, LinkKind.buy: 1, LinkKind.offlineInApp: 2};
  int compareGet(TrackLink a, TrackLink b) {
    final byTier = tier(a).compareTo(tier(b));
    if (byTier != 0) return byTier;
    final byKind = kindOrder[a.kind]!.compareTo(kindOrder[b.kind]!);
    if (byKind != 0) return byKind;
    return compareListen(a, b);
  }

  final listen = unique.where((l) => l.kind == LinkKind.listen).toList()..sort(compareListen);
  final get = unique.where((l) => l.kind != LinkKind.listen).toList()..sort(compareGet);
  return LinkGroups(listen, get);
}

/// Text of the label/button shown for a link (section 7, "Nhãn trên nút").
String linkLabel(TrackLink link, PlatformInfo platform) {
  switch (link.kind) {
    case LinkKind.listen:
      return link.exact ? S.exact : S.searchOn(platform.name);
    case LinkKind.buy:
      return link.exact ? S.buyAndDownload : S.searchOn(platform.name);
    case LinkKind.freeDownload:
      if (!link.exact) return S.searchOn(platform.name);
      if (link.isOpenLicense) return S.creativeCommons(link.license!);
      if (link.platform == 'soundcloud' || link.platform == 'bandcamp') return S.freeByArtist;
      return S.freeDownload;
    case LinkKind.offlineInApp:
      return S.openAppOffline;
  }
}
