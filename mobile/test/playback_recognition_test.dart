import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tim_nhac/app.dart';
import 'package:tim_nhac/models/app_config.dart';
import 'package:tim_nhac/models/history_entry.dart';
import 'package:tim_nhac/models/recognition.dart';
import 'package:tim_nhac/models/track.dart';
import 'package:tim_nhac/screens/result_screen.dart';
import 'package:tim_nhac/screens/settings_screen.dart';
import 'package:tim_nhac/services/app_services.dart';
import 'package:tim_nhac/services/native_bridge.dart';
import 'package:tim_nhac/services/playback_recognition.dart';
import 'package:tim_nhac/services/recognizer.dart';

import 'fakes.dart';

/// "Nhạc đang phát trên máy": the background session started by the Quick Settings tile.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ListenOutcome> run(AppServices s, FakeNative native) => runPlaybackRecognition(
        native: native,
        api: s.api,
        settings: s.settings,
        history: s.history,
        config: const SampleConfig(),
      );

  test('a match is saved as "playback" and notified with its history entry', () {
    fakeAsync((async) {
      final native = FakeNative();
      final fields = <Map<String, String>>[];
      late AppServices services;
      ListenOutcome? outcome;
      fakeServices(native: native, handler: (r) async {
        final f = multipartFields(r);
        fields.add(f);
        return f['stage'] == 'early'
            ? jsonResponse(recognitionJson(status: 'no_match', stage: 'early', isFinal: false))
            : jsonResponse(recognitionJson());
      }).then((s) {
        services = s;
        return run(s, native).then((o) => outcome = o);
      });
      async.elapse(const Duration(seconds: 14));
      expect(outcome, isA<Matched>());
      // Same cascade as the "Nghe" button: 6 s probe then the 12 s sample, both tagged.
      expect(fields.map((f) => f['stage']), ['early', 'full']);
      expect(fields.map((f) => f['source']), ['playback', 'playback']);
      final entry = services.history.entries.single;
      expect(entry.source, 'playback');
      expect(native.notifications.single, ('Đã nhận diện bài hát', 'Nơi Này Có Anh — Sơn Tùng M-TP'));
      expect(native.notificationIds.single, entry.id);
    });
  });

  test('silence is reported, nothing is sent or saved', () {
    fakeAsync((async) {
      final native = FakeNative()
        ..snapshot = sample(rms: 0.0001, durationMs: 6000)
        ..full = sample(rms: 0.0001);
      var requests = 0;
      late AppServices services;
      ListenOutcome? outcome;
      fakeServices(native: native, handler: (r) async {
        requests++;
        return jsonResponse(recognitionJson());
      }).then((s) {
        services = s;
        return run(s, native).then((o) => outcome = o);
      });
      async.elapse(const Duration(seconds: 14));
      expect(outcome, isA<Silent>());
      expect(requests, 0);
      expect(services.history.entries, isEmpty);
      expect(native.notifications.single.$1, 'Không thu được âm thanh');
      expect(native.notificationIds.single, isNull);
    });
  });

  test('the capture failing to start ends with a notification, not a hang', () {
    fakeAsync((async) {
      final native = FakeNative()..recordingStarts = false;
      ListenOutcome? outcome;
      fakeServices(native: native, handler: (r) async => jsonResponse(recognitionJson()))
          .then((s) => run(s, native).then((o) => outcome = o));
      async.elapse(const Duration(seconds: 1));
      expect(outcome, isA<Failed>());
      expect(native.notifications.single.$1, 'Chưa nhận diện được');
    });
  });

  test('every outcome has a notification text, except a cancelled run', () {
    final track = Track.fromJson(trackJson());
    final entry = HistoryEntry(id: 7, track: track, source: 'playback', createdAt: DateTime(2026));
    final result = RecognitionResult.fromJson(recognitionJson());
    expect(describeBackgroundOutcome(Matched(result, entry)), ('Đã nhận diện bài hát', 'Nơi Này Có Anh — Sơn Tùng M-TP', 7));
    expect(describeBackgroundOutcome(Candidates(RecognitionResult.fromJson(recognitionJson(status: 'candidates')))).$1,
        'Có thể là một trong các bài sau');
    expect(describeBackgroundOutcome(const NoMatch()).$1, 'Không nhận ra bài hát');
    expect(describeBackgroundOutcome(const SavedOffline()).$1, 'Đã lưu mẫu');
    expect(describeBackgroundOutcome(const Failed('Hết lượt')), ('Chưa nhận diện được', 'Hết lượt', null));
    expect(describeBackgroundOutcome(const Cancelled()).$1, isNull);
  });

  testWidgets('tapping a result notification opens its entry', (tester) async {
    final native = FakeNative();
    final s = await fakeServices(native: native, handler: (r) async => jsonResponse({'error': 'x'}, 404));
    final saved = await s.history.add(HistoryEntry(
      track: Track.fromJson(trackJson()),
      source: 'playback',
      createdAt: DateTime.now(),
    ));
    await tester.pumpWidget(TimNhacApp(services: s));
    await tester.pump();
    native.tapCtrl.add(saved.id!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ResultScreen), findsOneWidget);
  });

  group('settings', () {
    Future<FakeNative> open(WidgetTester tester, {required bool supported, int tile = QuickTileResult.added}) async {
      final native = FakeNative()
        ..playbackSupported = supported
        ..tileResult = tile;
      final s = await fakeServices(native: native, handler: (r) async => jsonResponse({'error': 'x'}, 404));
      s.playbackCaptureSupported = supported;
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppScope(services: s, child: const MaterialApp(home: SettingsScreen())));
      return native;
    }

    testWidgets('hidden where other apps cannot be captured (iOS, Android < 10)', (tester) async {
      await open(tester, supported: false);
      expect(find.text('Nhạc đang phát trên máy'), findsNothing);
    });

    testWidgets('adds the Quick Settings tile and starts a capture', (tester) async {
      final native = await open(tester, supported: true);
      expect(find.text('Nhạc đang phát trên máy'), findsOneWidget);
      await tester.tap(find.text('Thêm ô vào Cài đặt nhanh'));
      await tester.pump();
      expect(find.text('Đã thêm ô "Tìm Nhạc" vào Cài đặt nhanh'), findsOneWidget);
      await tester.tap(find.text('Nghe ngay nhạc đang phát nền'));
      await tester.pump();
      expect(native.playbackStarts, 1);
    });

    testWidgets('below Android 13 the steps to add the tile are shown', (tester) async {
      await open(tester, supported: true, tile: QuickTileResult.unavailable);
      await tester.tap(find.text('Thêm ô vào Cài đặt nhanh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('biểu tượng bút chì'), findsOneWidget);
    });
  });
}
