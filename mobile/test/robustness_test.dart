// Lớp lỗi "trạng thái kẹt": một lỗi giữa chừng không được để màn hình quay mãi.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tim_nhac/models/app_config.dart';
import 'package:tim_nhac/models/history_entry.dart';
import 'package:tim_nhac/services/api_client.dart';
import 'package:tim_nhac/services/history.dart';
import 'package:tim_nhac/services/recognizer.dart';

import 'fakes.dart';

http.Response html(int status) => http.Response.bytes(
      utf8.encode('<html><body><h1>$status Bad Gateway</h1></body></html>'),
      status,
      headers: {'content-type': 'text/html'},
    );

const _oneEvent = 'event: links\ndata: {"adapter":"spotify","links":['
    '{"id":"l1","platform":"spotify","kind":"listen","match":"exact","url":"https://open.spotify.com/track/1"}]}\n\n';

/// History storage that fails on insert (disk full, corrupted database...).
class BrokenHistoryDb extends MemoryHistoryDb {
  @override
  Future<int> insert(HistoryEntry entry) async => throw StateError('disk full');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiClient only throws ApiException', () {
    test('an HTML error page from a proxy is a server error, not a FormatException', () async {
      final s = await fakeServices(handler: (_) async => html(502));
      await expectLater(
        s.api.recognize(audio: sample().aac, mode: 'auto', source: 'mic', stage: 'full'),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'http_502')
            .having((e) => e.isNetwork, 'isNetwork', false)
            .having((e) => e.message, 'message', 'Máy chủ đang bận. Vui lòng thử lại sau.')),
      );
      await expectLater(s.api.search('abc', country: 'VN'), throwsA(isA<ApiException>()));
      await expectLater(s.api.fetchLinks('trk_1', country: 'VN'), throwsA(isA<ApiException>()));
      await expectLater(s.api.streamLinks('trk_1', country: 'VN').toList(), throwsA(isA<ApiException>()));
    });

    test('a 2xx answer that is not the expected JSON object is a bad response', () async {
      for (final body in ['<html>ok</html>', '[1,2,3]', '', '"text"', '{"id":7,"status":"matched"}']) {
        final s = await fakeServices(handler: (_) async => http.Response(body, 200));
        await expectLater(
          s.api.recognize(audio: sample().aac, mode: 'auto', source: 'mic', stage: 'full'),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'bad_response')),
          reason: body,
        );
      }
    });

    test('FastAPI default error bodies ({"detail": ...}) keep the status code', () async {
      final s = await fakeServices(handler: (_) async => jsonResponse({'detail': 'Invalid multipart data.'}, 400));
      await expectLater(
        s.api.reportRecognition('rec_1'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'http_400').having((e) => e.statusCode, 's', 400)),
      );
    });
  });

  group('link stream', () {
    // Real time with a short limit: the cancellation of the HTTP body completes through a
    // root-zone future, which fake_async cannot advance.
    test('a stream that goes silent ends with a network error instead of loading forever', () async {
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final s = await fakeServices(
        handler: (_) async => html(500),
        client: MockClient.streaming((request, _) async => http.StreamedResponse(body.stream, 200)),
        streamStallTimeout: const Duration(milliseconds: 150),
      );
      final events = <LinksEvent>[];
      Object? error;
      final finished = Completer<void>();
      final watch = Stopwatch()..start();
      s.api.streamLinks('trk_1', country: 'VN').listen(events.add,
          onError: (Object e) => error = e, onDone: finished.complete);
      body.add(utf8.encode(_oneEvent)); // one platform answers, then the connection goes dead
      await finished.future.timeout(const Duration(seconds: 10),
          onTimeout: () => fail('the link stream never ended: the result screen would load forever'));
      expect(events, hasLength(1));
      expect(error, isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', true));
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(140));
      expect(body.hasListener, isFalse, reason: 'the connection is released');
    });

    // The screens run under fake time in widget tests: Stream.timeout left the stream open
    // there after "done", and the result screen never stopped loading.
    testWidgets('the stall guard works under fake time: ends on "done", errors when silent',
        (tester) async {
      const done = '${_oneEvent}event: done\ndata: {"count":1}\n\n';
      final s = await fakeServices(handler: (_) async => http.Response.bytes(utf8.encode(done), 200));
      final log = <String>[];
      s.api.streamLinks('trk_1', country: 'VN').listen((e) => log.add(e.adapter),
          onError: (Object e) => log.add('error'), onDone: () => log.add('end'));
      await tester.pump(const Duration(seconds: 1));
      expect(log, ['spotify', 'end']);

      final body = StreamController<List<int>>();
      final silent = await fakeServices(
        handler: (_) async => html(500),
        client: MockClient.streaming((request, _) async => http.StreamedResponse(body.stream, 200)),
        streamStallTimeout: const Duration(seconds: 20),
      );
      log.clear();
      silent.api.streamLinks('trk_1', country: 'VN').listen((e) => log.add(e.adapter),
          onError: (Object e) => log.add('error'), onDone: () => log.add('end'));
      body.add(utf8.encode(_oneEvent));
      await tester.pump(const Duration(seconds: 19));
      expect(log, ['spotify'], reason: 'still waiting before the limit');
      await tester.pump(const Duration(seconds: 2));
      expect(log, ['spotify', 'error', 'end']);
      expect(body.hasListener, isFalse, reason: 'the connection is released');
    });

    test('a stream cut before "done" reports an error but keeps what arrived', () async {
      final s = await fakeServices(
          handler: (_) async => http.Response.bytes(utf8.encode(_oneEvent), 200));
      final events = <LinksEvent>[];
      Object? error;
      final finished = Completer<void>();
      s.api.streamLinks('trk_1', country: 'VN').listen(events.add,
          onError: (Object e) => error = e, onDone: finished.complete);
      await finished.future;
      expect(events.single.links.single.id, 'l1');
      expect(error, isA<ApiException>());
    });

    test('one unreadable event does not lose the other platforms', () async {
      const body = 'event: links\ndata: {not json}\n\n'
          'event: links\ndata: {"adapter":"x","links":[{"id":1}]}\n\n'
          '$_oneEvent'
          'event: done\ndata: {"count":1}\n\n';
      final s = await fakeServices(handler: (_) async => http.Response.bytes(utf8.encode(body), 200));
      final events = await s.api.streamLinks('trk_1', country: 'VN').toList();
      expect(events.map((e) => e.adapter), ['spotify']);
    });

    test('the connection breaking mid-stream is a network error', () async {
      final s = await fakeServices(
        handler: (_) async => html(500),
        client: MockClient.streaming((request, _) async => http.StreamedResponse(
            Stream.fromIterable([utf8.encode(_oneEvent)])
                .asyncMap<List<int>>((chunk) async => chunk)
                .transform(StreamTransformer.fromHandlers(handleDone: (sink) {
              sink.addError(const SocketException('Connection reset by peer'));
              sink.close();
            })),
            200)),
      );
      await expectLater(
        s.api.streamLinks('trk_1', country: 'VN').toList(),
        throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', true)),
      );
    });
  });

  group('ListenSession always ends', () {
    late FakeNative native;

    ListenSession session(dynamic services, {ListenMode mode = ListenMode.listen}) => ListenSession(
          native: native,
          api: services.api,
          config: const SampleConfig(),
          mode: mode,
          results: services.results,
          pending: services.pending,
        );

    setUp(() => native = FakeNative());

    /// Runs one tap for 30 virtual seconds and returns how it ended (null = still hanging).
    ListenOutcome? run(Future<http.Response> Function(http.Request) handler, {HistoryDb? db}) {
      ListenOutcome? outcome;
      fakeAsync((async) {
        fakeServices(native: native, handler: handler, db: db)
            .then((s) => session(s).start().then((o) => outcome = o));
        async.elapse(const Duration(seconds: 30));
      });
      return outcome;
    }

    Future<http.Response> noMatchThenMatch(http.Request r) async => multipartFields(r)['stage'] == 'early'
        ? jsonResponse(recognitionJson(status: 'no_match', stage: 'early', isFinal: false))
        : jsonResponse(recognitionJson());

    test('the encoder failing when recording stops', () {
      native.stopError = PlatformException(code: 'native_error', message: 'MediaCodec failed');
      expect(run(noMatchThenMatch), isA<Failed>());
    });

    test('the microphone failing to open with an exception', () {
      native.startError = PlatformException(code: 'permission', message: 'Chưa có quyền micro');
      expect(run(noMatchThenMatch), isA<Failed>());
    });

    test('a proxy error page as the answer to the full sample', () {
      final outcome = run((r) async => multipartFields(r)['stage'] == 'early'
          ? jsonResponse(recognitionJson(status: 'no_match', stage: 'early', isFinal: false))
          : html(502));
      expect(outcome, isA<Failed>().having((f) => f.message, 'message', contains('Máy chủ đang bận')));
    });

    test('the probe matched but stopping the microphone throws', () {
      native.cancelError = PlatformException(code: 'native_error');
      final outcome = run((r) async => jsonResponse(recognitionJson(stage: 'early')));
      expect(outcome, isA<Matched>());
      expect(native.calls, isNot(contains('stop')));
    });

    test('history cannot be written: the result is still shown', () {
      final outcome = run((r) async => jsonResponse(recognitionJson(stage: 'early')), db: BrokenHistoryDb());
      expect(outcome, isA<Matched>().having((m) => m.entry.id, 'entry.id', isNull));
      final full = run(noMatchThenMatch, db: BrokenHistoryDb());
      expect(full, isA<Matched>());
    });

    test('"matched" without any candidate is treated as no match', () {
      final outcome = run((r) async => jsonResponse(recognitionJson(candidates: [])));
      expect(outcome, isA<NoMatch>());
    });

    test('cancel does not leak an error when the native side fails', () {
      native.cancelError = PlatformException(code: 'native_error');
      final errors = <Object>[];
      ListenOutcome? outcome;
      runZonedGuarded(() {
        fakeAsync((async) {
          late ListenSession s;
          fakeServices(native: native, handler: noMatchThenMatch).then((services) {
            s = session(services);
            s.start().then((o) => outcome = o);
          });
          async.elapse(const Duration(seconds: 2));
          s.cancel();
          async.elapse(const Duration(seconds: 1));
        });
      }, (e, _) => errors.add(e));
      expect(outcome, isA<Cancelled>());
      expect(errors, isEmpty);
    });
  });
}
