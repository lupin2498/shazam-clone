import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_nhac/models/app_config.dart';
import 'package:tim_nhac/models/recognition.dart';
import 'package:tim_nhac/models/track.dart';
import 'package:tim_nhac/models/track_link.dart';
import 'package:tim_nhac/screens/history_screen.dart';
import 'package:tim_nhac/screens/home_screen.dart';
import 'package:tim_nhac/services/history.dart';
import 'package:tim_nhac/services/integrity.dart';
import 'package:tim_nhac/services/link_sorter.dart';
import 'package:tim_nhac/services/sse.dart';

import 'fakes.dart';

TrackLink link(String platform, LinkKind kind, {bool exact = true, double score = 1, String? license, String? url}) =>
    TrackLink(
      id: 'lnk_${platform}_${kind.wire}_$exact',
      platform: platform,
      kind: kind,
      exact: exact,
      url: url ?? 'https://$platform.example/${kind.wire}/$exact',
      score: score,
      license: license,
    );

void main() {
  group('SSE parser', () {
    test('parses events, multi-line data and ignores comments', () async {
      const raw = ': keep-alive\n'
          'event: track\ndata: {"id":"trk_1"}\n\n'
          'event: links\ndata: {"adapter":"spotify",\ndata: "links":[]}\n\n'
          'data: no event name\n\n';
      final events = await Stream.value(raw).transform(const SseParser()).toList();
      expect(events.map((e) => e.event), ['track', 'links', 'message']);
      expect(jsonDecode(events[1].data), {'adapter': 'spotify', 'links': []});
      expect(events[2].data, 'no event name');
    });

    test('handles chunks split anywhere', () async {
      final events = await Stream.fromIterable(['ev', 'ent: done\nda', 'ta: {"count":3}\n', '\n'])
          .transform(const SseParser())
          .toList();
      expect(events.single.event, 'done');
      expect(jsonDecode(events.single.data), {'count': 3});
    });
  });

  group('models', () {
    test('recognition response from the backend', () {
      final r = RecognitionResult.fromJson(recognitionJson(status: 'candidates', candidates: [
        {'track': trackJson(), 'confidence': 0.8, 'rank': 1, 'flags': ['cover']},
        {'track': trackJson(id: 'trk_2', title: 'Khác'), 'confidence': 0.5, 'rank': 2, 'flags': ['cover']},
      ]));
      expect(r.status, RecognitionStatus.candidates);
      expect(r.candidates, hasLength(2));
      expect(r.top!.isCover, isTrue);
      expect(r.top!.track.artistLine, 'Sơn Tùng M-TP');
    });

    test('track link round trip', () {
      final l = TrackLink.fromJson({
        'id': 'lnk_1', 'platform': 'jamendo', 'kind': 'free_download', 'match': 'exact',
        'url': 'https://jamendo.com/t/1', 'license': 'CC BY 3.0', 'score': 0.9,
      });
      expect(l.kind, LinkKind.freeDownload);
      expect(l.isOpenLicense, isTrue);
      expect(TrackLink.fromJson(l.toJson()).toJson(), l.toJson());
    });

    test('config parses platforms and colours', () {
      final c = AppConfig.fromJson({
        'platforms': [
          {'id': 'zing_mp3', 'name': 'Zing MP3', 'color': '#8D22C3', 'android_package': 'com.zing.mp3',
           'offline_in_app': true, 'enabled': true},
        ],
        'sample': {'early_probe_s': 5, 'full_s': 11},
        'integrity': {'cloud_project_number': '123'},
      });
      expect(c.platform('zing_mp3').color.toARGB32(), 0xFF8D22C3);
      expect(c.sample.earlyProbeS, 5);
      expect(c.cloudProjectNumber, '123');
      expect(c.platform('unknown').name, 'unknown');
    });

    test('duration and version helpers', () {
      expect(formatDuration(260000), '4:20');
      expect(formatDuration(0), '0:00');
      expect(formatDuration(3723000), '1:02:03');
      expect(isOutdated('1.0.0', '1.0.1'), isTrue);
      expect(isOutdated('1.2.0', '1.1.9'), isFalse);
      expect(isOutdated('1.0.0', '1.0.0'), isFalse);
    });

    test('history day labels', () {
      final now = DateTime(2026, 11, 16, 10);
      expect(dayLabel(DateTime(2026, 11, 16, 8), now: now), 'Hôm nay');
      expect(dayLabel(DateTime(2026, 11, 15, 23), now: now), 'Hôm qua');
      expect(dayLabel(DateTime(2026, 1, 2), now: now), '02/01/2026');
    });

    test('Vietnamese folding for history search', () {
      expect(foldVietnamese('Nơi Này Có Anh – Sơn Tùng'), 'noi nay co anh – son tung');
      expect(foldVietnamese('ĐEN VÂU Hồ Ngọc Hà Mỹ Tâm Ưng Hoàng Phúc'), 'den vau ho ngoc ha my tam ung hoang phuc');
    });

    test('integrity request hash matches the backend format', () {
      // sha256("dev|sess|full|abc") computed the same way as backend request_hash().
      expect(requestHash('dev', ['sess', 'full', 'abc']), sha256Hex(utf8.encode('dev|sess|full|abc')));
      expect(requestHash('dev', ['x']).length, 64);
    });
  });

  group('link ordering (section 7)', () {
    final links = [
      link('youtube', LinkKind.listen, exact: false, score: 0),
      link('deezer', LinkKind.listen),
      link('spotify', LinkKind.listen),
      link('zing_mp3', LinkKind.listen, exact: false),
      link('zing_mp3', LinkKind.offlineInApp, exact: false),
      link('itunes', LinkKind.buy),
      link('bandcamp', LinkKind.buy, exact: false),
      link('jamendo', LinkKind.freeDownload, license: 'CC BY 3.0'),
      link('deezer', LinkKind.listen), // duplicate from another adapter
    ];

    test('preferred platforms, then installed apps, then exact before search', () {
      final g = groupLinks(links, preferred: ['zing_mp3'], installedPlatforms: {'spotify'});
      expect(g.listen.map((l) => l.platform), ['zing_mp3', 'spotify', 'deezer', 'youtube']);
      expect(g.get.map((l) => '${l.platform}:${l.kind.wire}'),
          ['jamendo:free_download', 'itunes:buy', 'zing_mp3:offline_in_app', 'bandcamp:buy']);
      expect(g.hasFreeDownload, isTrue);
    });

    test('every link is kept (no cap)', () {
      final many = [for (var i = 0; i < 12; i++) link('p$i', LinkKind.listen)];
      expect(groupLinks(many).listen, hasLength(12));
    });

    test('labels', () {
      final spotify = AppConfig.defaults.platform('spotify');
      final zing = AppConfig.defaults.platform('zing_mp3');
      expect(linkLabel(link('spotify', LinkKind.listen), spotify), 'Chính xác');
      expect(linkLabel(link('zing_mp3', LinkKind.listen, exact: false), zing), 'Tìm trên Zing MP3');
      expect(linkLabel(link('itunes', LinkKind.buy), AppConfig.defaults.platform('itunes')), 'Mua và tải');
      expect(linkLabel(link('soundcloud', LinkKind.freeDownload), AppConfig.defaults.platform('soundcloud')),
          'Tải miễn phí — nghệ sĩ cho phép');
      expect(linkLabel(link('jamendo', LinkKind.freeDownload, license: 'CC BY 3.0'),
          AppConfig.defaults.platform('jamendo')), 'Tải — CC BY 3.0');
      expect(linkLabel(link('spotify', LinkKind.offlineInApp), spotify), 'Mở app để tải offline');
    });
  });
}
