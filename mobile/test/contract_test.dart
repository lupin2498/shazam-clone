// Values shared with the backend: a change on one side must break a test on that side.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tim_nhac/services/api_client.dart';
import 'package:tim_nhac/services/integrity.dart';

import 'fakes.dart';

/// Computed with backend/app/security/integrity.py:request_hash (same constants in
/// backend/tests/test_integrity_vectors.py).
const _audioSha = '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';
const _fullWithSession = 'e07a9bf6e96698cf41b03031452709106929df467e2b57d4f83645e364736f7a';
const _earlyNoSession = '4af569da140870f657caa47fdd30ccc8e215d1983d88cd4f02acb1f1798a9445';
const _searchVietnamese = 'b31fda262bb7fa913b2529db5a202a6b8cbcd9614d1eaf78dcffa99c2a8381ef';
const _report = '21eabc87dadb5e8a5974d4c2d616cc514d9d4b871d7e29466923a6c41e69e2c1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the integrity hash the app sends is the one the backend recomputes', () async {
    // FakeNative returns "token-for-<requestHash>", so the header shows the hash used.
    final native = FakeNative()..integrityReadyFromCall = 1;
    final integrity = IntegrityService(native);
    await integrity.prepare('123456');
    final tokens = <String>[];
    final api = ApiClient(
      baseUrl: 'http://test',
      deviceId: () => 'dev-123',
      integrity: integrity,
      client: MockClient((http.Request r) async {
        tokens.add(r.headers['X-Integrity-Token'] ?? 'none');
        if (r.url.path == '/v1/search') return jsonResponse({'results': []});
        if (r.url.path.endsWith('/report')) return jsonResponse({'hidden': false}, 202);
        return jsonResponse(recognitionJson());
      }),
    );
    final audio = Uint8List.fromList([1, 2, 3]);
    expect(sha256Hex(audio), _audioSha);

    await api.recognize(audio: audio, mode: 'auto', source: 'mic', stage: 'full', sessionId: 'sess-1');
    await api.recognize(audio: audio, mode: 'auto', source: 'mic', stage: 'early');
    await api.search('Nơi này có anh', country: 'VN');
    await api.reportLink('lnk_1', 'violation');

    expect(tokens, [
      'token-for-$_fullWithSession',
      'token-for-$_earlyNoSession',
      'token-for-$_searchVietnamese',
      'token-for-$_report',
    ]);
  });

  test('a late /v1/config from the previous server does not replace the new server\'s', () async {
    Map<String, dynamic> config(String project) => {
          'platforms': [
            {'id': 'spotify', 'name': 'Spotify', 'color': '#1DB954', 'android_package': 'com.spotify.music'},
          ],
          'integrity': {'cloud_project_number': project},
        };
    final slowOld = Completer<http.Response>();
    final s = await fakeServices(
      native: FakeNative()..integrityReadyFromCall = 1,
      handler: (r) => r.url.host == 'old.example' ? slowOld.future : Future.value(jsonResponse(config('222'))),
    );
    // "Cài đặt → Máy chủ" twice in a row: the first server answers after the second one.
    await s.settings.setServerOverride('https://old.example');
    final first = s.reconnect();
    await s.settings.setServerOverride('https://new.example');
    expect(await s.reconnect(), isTrue);
    slowOld.complete(jsonResponse(config('111')));
    expect(await first, isFalse, reason: 'that answer is for a server the app no longer uses');

    expect(s.config.value.cloudProjectNumber, '222');
    expect(s.settings.cachedConfig?['integrity'], {'cloud_project_number': '222'});
    expect((s.native as FakeNative).integrityPrepareCalls, 1, reason: 'no prepare for the old project');
  });

  group('Play Integrity recovers without restarting the app', () {
    late DateTime now;
    late FakeNative native;
    late IntegrityService integrity;

    setUp(() {
      now = DateTime(2026, 11, 16, 9);
      native = FakeNative();
      integrity = IntegrityService(native, clock: () => now);
    });

    test('a prepare that failed at start (offline, Play services busy) is retried later', () async {
      native.integrityReadyFromCall = 2; // the first attempt fails
      await integrity.prepare('123456');
      expect(native.integrityPrepareCalls, 1);

      now = now.add(const Duration(seconds: 10));
      expect(await integrity.token('dev', ['x']), isNull, reason: 'too soon to try again');
      expect(native.integrityPrepareCalls, 1, reason: 'no prepare on every request');

      now = now.add(const Duration(minutes: 1));
      expect(await integrity.token('dev', ['x']), 'token-for-${requestHash('dev', ['x'])}');
      expect(native.integrityPrepareCalls, 2);
    });

    test('preparing again for the same project after a failure really retries', () async {
      // AppServices.reconnect() (server address changed) calls prepare with the same number.
      native.integrityReadyFromCall = 2;
      await integrity.prepare('123456');
      await integrity.prepare('123456');
      expect(native.integrityPrepareCalls, 2);
      expect(await integrity.token('dev', ['x']), isNotNull);

      await integrity.prepare('123456'); // ready: nothing to do
      expect(native.integrityPrepareCalls, 2);
    });

    test('an expired token provider is prepared again once, then the token is retried', () async {
      native.integrityReadyFromCall = 1;
      await integrity.prepare('123456');
      native.integrityTokenFailures = 1;
      expect(await integrity.token('dev', ['x']), isNotNull);
      expect(native.integrityPrepareCalls, 2);
      expect(native.integrityTokenCalls, 2);

      native.integrityTokenFailures = 5; // still failing: bounded work per request
      expect(await integrity.token('dev', ['y']), isNull);
      expect(native.integrityTokenCalls, 4);
    });

    test('no project number configured: no native call at all', () async {
      expect(await integrity.token('dev', ['x']), isNull);
      await integrity.prepare(null);
      await integrity.prepare('');
      expect(await integrity.token('dev', ['x']), isNull);
      expect(native.integrityPrepareCalls + native.integrityTokenCalls, 0);
    });
  });
}
