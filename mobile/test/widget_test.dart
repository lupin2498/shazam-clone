import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tim_nhac/app.dart';
import 'package:tim_nhac/models/app_config.dart';
import 'package:tim_nhac/models/history_entry.dart';
import 'package:tim_nhac/models/track.dart';
import 'package:tim_nhac/screens/result_screen.dart';
import 'package:tim_nhac/services/app_services.dart';

import 'fakes.dart';

const _links = 'event: links\ndata: {"adapter":"spotify","links":['
    '{"id":"l1","platform":"spotify","kind":"listen","match":"exact","url":"https://open.spotify.com/track/1",'
    '"title":"Nơi Này Có Anh","duration_ms":260000},'
    '{"id":"l2","platform":"spotify","kind":"offline_in_app","match":"exact","url":"https://open.spotify.com/track/1"}]}\n\n'
    'event: links\ndata: {"adapter":"zing_mp3","links":['
    '{"id":"l3","platform":"zing_mp3","kind":"listen","match":"search","url":"https://zingmp3.vn/tim-kiem/bai-hat?q=x"}]}\n\n'
    'event: done\ndata: {"count":3}\n\n';

Future<http.Response> _backend(http.Request r) async {
  if (r.url.path.endsWith('/links')) {
    return http.Response.bytes(utf8.encode(_links), 200, headers: {'content-type': 'text/event-stream'});
  }
  if (r.url.path.endsWith('/report')) return jsonResponse({'hidden': true}, 202);
  return jsonResponse({'error': 'not_found', 'message': 'x'}, 404);
}

Widget _wrap(AppServices s, Widget child) => AppScope(services: s, child: MaterialApp(home: child));

/// A tall phone so the whole result list is built.
void _tallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('home screen shows the listen button, mode switch and recent results', (tester) async {
    tester.view.physicalSize = const Size(720, 1280); // small phone, 360x640 dp
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final s = await fakeServices(handler: _backend);
    await s.history.add(HistoryEntry(
      track: Track.fromJson(trackJson()),
      source: 'mic',
      createdAt: DateTime.now(),
    ));
    await tester.pumpWidget(TimNhacApp(services: s));
    await tester.pump();

    expect(find.text('Chạm để nhận diện'), findsOneWidget);
    expect(find.text('Chọn file'), findsOneWidget);
    expect(find.text('Gần đây'), findsOneWidget);
    expect(find.text('Nơi Này Có Anh'), findsOneWidget);

    await tester.tap(find.text('Ngân nga'));
    await tester.pump();
    expect(find.text('Chạm rồi ngân nga hoặc huýt sáo'), findsOneWidget);
  });

  testWidgets('"app đã cũ" banner: neutral wording, OK hides it for this run', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final s = await fakeServices(handler: _backend);
    s.config.value = AppConfig(platforms: AppConfig.defaults.platforms, minAppVersion: '99.0.0');
    await tester.pumpWidget(TimNhacApp(services: s));
    await tester.pump();

    final banner = find.byType(MaterialBanner);
    expect(banner, findsOneWidget);
    // The app also ships on iOS: the store is not always Google Play.
    expect(find.textContaining('Google Play'), findsNothing);
    expect(find.textContaining('Phiên bản app đã cũ'), findsOneWidget);

    await tester.tap(find.descendant(of: banner, matching: find.text('OK')));
    await tester.pump();
    expect(find.byType(MaterialBanner), findsNothing);

    // A later config refresh (same minimum) does not bring it back during this run.
    s.config.value = AppConfig(platforms: AppConfig.defaults.platforms, minAppVersion: '99.0.0');
    await tester.pump();
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('result screen lists every link in "Nghe" and "Tải/Mua" and saves them', (tester) async {
    final native = FakeNative();
    final s = await fakeServices(native: native, handler: _backend);
    final entry = await s.history.add(HistoryEntry(
      track: Track.fromJson(trackJson(instrumental: true)),
      source: 'mic',
      createdAt: DateTime.now(),
      recognitionId: 'rec_1',
      flags: const ['maybe_beat'],
    ));
    _tallPhone(tester);
    await tester.pumpWidget(_wrap(s, ResultScreen(entry: entry)));
    await tester.pumpAndSettle();

    expect(find.text('Nghe (2)'), findsOneWidget);
    expect(find.text('Tải/Mua (1)'), findsOneWidget);
    expect(find.text('Không lời'), findsOneWidget);
    expect(find.text('Có thể là bản beat'), findsOneWidget);
    expect(find.text('Tìm trên Zing MP3'), findsWidgets);
    expect(find.textContaining('Không có bản tải miễn phí hợp pháp'), findsOneWidget);
    // Stored for F6 (reopen without recognising again).
    expect(s.history.entries.first.links, hasLength(3));

    await tester.tap(find.text('Nơi Này Có Anh').last);
    await tester.pump();
    expect(native.opened.single, ('https://open.spotify.com/track/1', 'com.spotify.music'));
  });

  testWidgets('a reported link disappears', (tester) async {
    final s = await fakeServices(handler: _backend);
    final entry = await s.history.add(HistoryEntry(
      track: Track.fromJson(trackJson()),
      source: 'mic',
      createdAt: DateTime.now(),
    ));
    _tallPhone(tester);
    await tester.pumpWidget(_wrap(s, ResultScreen(entry: entry)));
    await tester.pumpAndSettle();
    expect(find.text('Nghe (2)'), findsOneWidget);

    await tester.tap(find.byTooltip('Báo cáo link').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Báo cáo link').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vi phạm bản quyền'));
    await tester.pumpAndSettle();

    expect(find.text('Đã ẩn link này'), findsOneWidget);
    expect(find.text('Nghe (1)'), findsOneWidget);
  });
}
