import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tim_nhac/models/app_config.dart';
import 'package:tim_nhac/services/api_client.dart';
import 'package:tim_nhac/services/file_scanner.dart';
import 'package:tim_nhac/services/recognizer.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiClient', () {
    test('recognize sends a multipart sample with device headers', () async {
      late http.Request seen;
      final s = await fakeServices(handler: (r) async {
        seen = r;
        return jsonResponse(recognitionJson());
      });
      final r = await s.api.recognize(
          audio: sample().aac, mode: 'auto', source: 'mic', stage: 'early', sessionId: 'abc');
      expect(r.top!.track.title, 'Nơi Này Có Anh');
      expect(seen.url.path, '/v1/recognitions');
      expect(seen.headers['X-Device-Id'], s.settings.deviceId);
      expect(seen.headers['X-App-Version'], '1.0.0');
      final fields = multipartFields(seen);
      expect(fields, containsPair('stage', 'early'));
      expect(fields, containsPair('session_id', 'abc'));
      expect(latin1.decode(seen.bodyBytes), contains('filename="sample.aac"'));
    });

    test('backend errors keep their Vietnamese message', () async {
      final s = await fakeServices(
          handler: (_) async => jsonResponse({'error': 'quota_exceeded', 'message': 'Hết lượt hôm nay'}, 429));
      expect(
        () => s.api.recognize(audio: sample().aac, mode: 'auto', source: 'mic', stage: 'full'),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'quota_exceeded')
            .having((e) => e.message, 'message', 'Hết lượt hôm nay')
            .having((e) => e.isNetwork, 'isNetwork', false)),
      );
    });

    test('network failures are reported as such', () async {
      final s = await fakeServices(handler: (_) async => throw const SocketException('down'));
      expect(() => s.api.search('abc', country: 'VN'),
          throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', true)));
    });

    test('links are streamed per adapter', () async {
      const body = 'event: track\ndata: {"id":"trk_1"}\n\n'
          'event: links\ndata: {"adapter":"spotify","cached":false,"degraded":false,"links":['
          '{"id":"lnk_1","platform":"spotify","kind":"listen","match":"exact","url":"https://open.spotify.com/track/1"}]}\n\n'
          'event: links\ndata: {"adapter":"zing_mp3","links":[{"id":"lnk_2","platform":"zing_mp3",'
          '"kind":"listen","match":"search","url":"https://zingmp3.vn/tim-kiem/bai-hat?q=x"}]}\n\n'
          'event: done\ndata: {"count":2}\n\n';
      late http.Request seen;
      final s = await fakeServices(handler: (r) async {
        seen = r;
        return http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'text/event-stream'});
      });
      final events = await s.api.streamLinks('trk_1', country: 'VN', variant: 'beat').toList();
      expect(events.map((e) => e.adapter), ['spotify', 'zing_mp3']);
      expect(events.last.links.single.exact, isFalse);
      expect(seen.url.queryParameters, {'country': 'VN', 'variant': 'beat'});
      expect(seen.headers['Accept'], 'text/event-stream');
    });
  });

  group('ListenSession (section 5 cascade, app side)', () {
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

    test('a confident 6 s probe stops listening early', () {
      fakeAsync((async) {
        final stages = <String>[];
        late ListenOutcome outcome;
        fakeServices(native: native, handler: (r) async {
          stages.add(multipartFields(r)['stage']!);
          return jsonResponse(recognitionJson(stage: 'early'));
        }).then((s) => session(s).start().then((o) => outcome = o));
        async.elapse(const Duration(seconds: 7));
        expect(stages, ['early']);
        expect(outcome, isA<Matched>());
        expect(native.calls, containsAllInOrder(['start:13', 'snapshot:6000', 'cancel']));
        expect(native.calls, isNot(contains('stop')));
      });
    });

    test('no match at 6 s → full 12 s sample, same session id', () {
      fakeAsync((async) {
        final fields = <Map<String, String>>[];
        late ListenOutcome outcome;
        fakeServices(native: native, handler: (r) async {
          final f = multipartFields(r);
          fields.add(f);
          return f['stage'] == 'early'
              ? jsonResponse(recognitionJson(status: 'no_match', stage: 'early', isFinal: false))
              : jsonResponse(recognitionJson());
        }).then((s) => session(s).start().then((o) => outcome = o));
        async.elapse(const Duration(seconds: 13));
        expect(fields.map((f) => f['stage']), ['early', 'full']);
        expect(fields[0]['session_id'], fields[1]['session_id']);
        expect(outcome, isA<Matched>());
        expect((outcome as Matched).entry.id, isNotNull); // saved to history
      });
    });

    test('humming skips the probe and records 15 s', () {
      fakeAsync((async) {
        final fields = <Map<String, String>>[];
        late ListenOutcome outcome;
        fakeServices(native: native, handler: (r) async {
          fields.add(multipartFields(r));
          return jsonResponse(recognitionJson(status: 'candidates'));
        }).then((s) => session(s, mode: ListenMode.hum).start().then((o) => outcome = o));
        async.elapse(const Duration(seconds: 16));
        expect(fields.single, containsPair('mode', 'hum'));
        expect(native.calls.first, 'start:16');
        expect(outcome, isA<Candidates>());
      });
    });

    test('near-silent samples are not sent', () {
      fakeAsync((async) {
        native
          ..snapshot = sample(rms: 0.0005)
          ..full = sample(rms: 0.0005);
        var requests = 0;
        late ListenOutcome outcome;
        fakeServices(native: native, handler: (r) async {
          requests++;
          return jsonResponse(recognitionJson());
        }).then((s) => session(s).start().then((o) => outcome = o));
        async.elapse(const Duration(seconds: 13));
        expect(requests, 0);
        expect(outcome, isA<Silent>());
      });
    });

    test('offline: the sample is queued, then sent when the network returns', () {
      fakeAsync((async) {
        native.online = false;
        var requests = 0;
        late ListenOutcome outcome;
        late dynamic services;
        fakeServices(native: native, handler: (r) async {
          requests++;
          if (multipartFields(r)['stage'] == 'early') throw const SocketException('offline');
          return jsonResponse(recognitionJson());
        }).then((s) {
          services = s;
          session(s).start().then((o) => outcome = o);
        });
        async.elapse(const Duration(seconds: 13));
        expect(outcome, isA<SavedOffline>());
        expect(services.history.pendingCount, 1);

        native.online = true;
        services.pending.start();
        async.elapse(const Duration(seconds: 1));
        expect(services.history.pendingCount, 0);
        expect(services.history.entries, hasLength(1));
        expect(native.notifications.single.$1, 'Đã nhận diện bài hát');
        expect(requests, greaterThanOrEqualTo(2));
      });
    });

    test('cancel stops the microphone and ignores late answers', () {
      fakeAsync((async) {
        final completer = Completer<http.Response>();
        late ListenSession s;
        ListenOutcome? outcome;
        fakeServices(native: native, handler: (_) => completer.future).then((services) {
          s = session(services);
          s.start().then((o) => outcome = o);
        });
        async.elapse(const Duration(seconds: 7));
        s.cancel();
        async.flushMicrotasks();
        expect(outcome, isA<Cancelled>());
        completer.complete(jsonResponse(recognitionJson(stage: 'early')));
        async.elapse(const Duration(seconds: 10));
        expect(outcome, isA<Cancelled>());
        expect(native.calls, contains('cancel'));
      });
    });

    test('microphone busy', () {
      fakeAsync((async) {
        native.recordingStarts = false;
        late ListenOutcome outcome;
        fakeServices(native: native, handler: (_) async => jsonResponse(recognitionJson()))
            .then((s) => session(s).start().then((o) => outcome = o));
        async.flushMicrotasks();
        expect(outcome, isA<Failed>());
      });
    });
  });

  test('scanning a file merges consecutive identical results', () async {
    final native = FakeNative();
    var n = 0;
    final s = await fakeServices(native: native, handler: (r) async {
      n++;
      // Segments 1-2 → song A, 3 → no match, 4 → song B.
      if (n <= 2) return jsonResponse(recognitionJson());
      if (n == 3) return jsonResponse(recognitionJson(status: 'no_match'));
      return jsonResponse(recognitionJson(candidates: [
        {'track': trackJson(id: 'trk_2', title: 'Bài B'), 'confidence': 0.9, 'rank': 1, 'flags': <String>[]},
      ]));
    });
    final progress = await scanFile(
      native: native,
      api: s.api,
      uri: 'content://x',
      durationMs: 120000,
      config: const SampleConfig(),
    ).toList();
    final hits = progress.last.hits;
    expect(progress.last.finished, isTrue);
    expect(hits.map((h) => h.track.title), ['Nơi Này Có Anh', 'Bài B']);
    expect([hits.first.startMs, hits.first.endMs], [0, 60000]);
    expect(native.calls.where((c) => c.startsWith('segment')), hasLength(4));
  });
}
