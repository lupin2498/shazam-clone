import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tim_nhac/config.dart';
import 'package:tim_nhac/screens/settings_screen.dart';
import 'package:tim_nhac/services/api_client.dart';
import 'package:tim_nhac/services/app_services.dart';
import 'package:tim_nhac/services/integrity.dart';
import 'package:tim_nhac/services/server_address.dart';
import 'package:tim_nhac/services/settings_store.dart';

import 'fakes.dart';

Map<String, dynamic> _configJson() => {
      'platforms': [
        {'id': 'spotify', 'name': 'Spotify', 'color': '#1DB954', 'android_package': 'com.spotify.music'},
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ServerAddress.parse', () {
    test('normalises what the user typed', () {
      expect(ServerAddress.parse('  https://api.example.com/  '), 'https://api.example.com');
      expect(ServerAddress.parse('api.example.com'), 'https://api.example.com');
      expect(ServerAddress.parse('https://example.com:8443/tim-nhac/'), 'https://example.com:8443/tim-nhac');
      expect(ServerAddress.parse('https://example.com:443'), 'https://example.com');
    });

    test('a bare local address gets http, a bare public one https', () {
      expect(ServerAddress.parse('192.168.1.10:8000'), 'http://192.168.1.10:8000');
      expect(ServerAddress.parse('localhost:8000'), 'http://localhost:8000');
      expect(ServerAddress.parse('may-tinh.local:8000'), 'http://may-tinh.local:8000');
      expect(ServerAddress.parse('[::1]:8000'), 'http://[::1]:8000');
      expect(ServerAddress.parse('timnhac.example.vn'), 'https://timnhac.example.vn');
    });

    test('release builds refuse plain HTTP outside the local network', () {
      for (final url in ['http://api.example.com', 'http://8.8.8.8:8000', 'http://172.32.0.1', 'http://192.169.1.1']) {
        expect(() => ServerAddress.parse(url, release: true),
            throwsA(isA<ServerAddressException>().having((e) => e.message, 'message', ServerAddress.httpsOnlyMessage)),
            reason: url);
        expect(ServerAddress.isAllowed(url, release: true), isFalse, reason: url);
      }
      for (final url in [
        'http://192.168.1.10:8000',
        'http://10.0.2.2:8000',
        'http://172.16.0.5',
        'http://172.31.255.1',
        'http://127.0.0.1:8000',
        'http://localhost:8000',
        'http://169.254.10.1',
        'https://api.example.com',
      ]) {
        expect(ServerAddress.parse(url, release: true), url, reason: url);
        expect(ServerAddress.isAllowed(url, release: true), isTrue, reason: url);
      }
    });

    test('debug and profile builds accept any HTTP backend', () {
      expect(ServerAddress.parse('http://api.example.com', release: false), 'http://api.example.com');
      expect(ServerAddress.isAllowed('http://api.example.com', release: false), isTrue);
    });

    test('malformed addresses are rejected with a message', () {
      expect(() => ServerAddress.parse('   '),
          throwsA(isA<ServerAddressException>().having((e) => e.message, 'message', ServerAddress.emptyMessage)));
      for (final bad in [
        'ftp://example.com',
        'https://',
        'https://user:pass@example.com',
        'https://example.com/?a=1',
        'https://example.com/#x',
        'máy chủ của tôi',
        'https://exa mple.com',
      ]) {
        expect(() => ServerAddress.parse(bad),
            throwsA(isA<ServerAddressException>().having((e) => e.message, 'message', ServerAddress.invalidMessage)),
            reason: bad);
      }
    });

    test('no address is never allowed', () {
      expect(ServerAddress.isAllowed('', release: false), isFalse);
      expect(ServerAddress.isAllowed('', release: true), isFalse);
      expect(ServerAddress.isAllowed('not a url', release: false), isFalse);
      expect(ServerAddress.isAllowed('ftp://example.com', release: false), isFalse);
    });

    test('local hosts', () {
      for (final host in ['localhost', 'LOCALHOST', 'nas.local', '10.1.2.3', '192.168.0.1', '172.20.1.1', '::1', 'fd12::1', 'fe80::1']) {
        expect(ServerAddress.isLocalHost(host), isTrue, reason: host);
      }
      for (final host in ['example.com', 'local.example.com', '11.0.0.1', '172.15.0.1', '999.1.1.1', '2001:db8::1', '']) {
        expect(ServerAddress.isLocalHost(host), isFalse, reason: host);
      }
    });
  });

  group('backend address at run time', () {
    test('debug builds default to the development machine', () {
      expect(kApiBaseUrl, isEmpty, reason: 'tests are built without --dart-define=API_BASE_URL');
      expect(defaultApiBaseUrl(), 'http://10.0.2.2:8000');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(defaultApiBaseUrl(), 'http://127.0.0.1:8000');
    });

    test('the address chosen in settings replaces the built-in one and drops the cached config', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await SettingsStore.load();
      await settings.saveConfig(_configJson());
      expect(settings.serverOverride, isNull);

      var notified = 0;
      settings.addListener(() => notified++);
      await settings.setServerOverride('https://api.example.com');
      expect(settings.serverOverride, 'https://api.example.com');
      expect(settings.cachedConfig, isNull);
      expect(notified, 1);

      // "Xóa dữ liệu" forgets personal data, not where the backend is.
      await settings.reset();
      expect(settings.serverOverride, 'https://api.example.com');

      await settings.setServerOverride(null);
      expect(settings.serverOverride, isNull);
    });

    test('requests go to the address chosen at run time', () async {
      String? override;
      final seen = <Uri>[];
      final api = ApiClient(
        baseUrl: 'http://10.0.2.2:8000',
        baseUrlOverride: () => override,
        deviceId: () => 'device',
        integrity: IntegrityService(FakeNative()),
        client: MockClient((r) async {
          seen.add(r.url);
          return jsonResponse(_configJson());
        }),
      );
      await api.fetchConfigJson();
      override = 'https://api.example.com/tim-nhac';
      await api.fetchConfigJson();
      await api.search('nơi này', country: 'VN');
      expect(seen.map((u) => '${u.scheme}://${u.host}${u.path}'), [
        'http://10.0.2.2/v1/config',
        'https://api.example.com/tim-nhac/v1/config',
        'https://api.example.com/tim-nhac/v1/search',
      ]);
      expect(seen.last.queryParameters, {'q': 'nơi này', 'country': 'VN'});
    });

    test('without a usable address nothing is sent and the error says where to set it', () async {
      var sent = 0;
      final api = ApiClient(
        baseUrl: '',
        deviceId: () => 'device',
        integrity: IntegrityService(FakeNative()),
        client: MockClient((r) async {
          sent++;
          return http.Response('', 200);
        }),
      );
      final isServerError = isA<ApiException>()
          .having((e) => e.code, 'code', 'server_address')
          .having((e) => e.isNetwork, 'isNetwork', isFalse)
          .having((e) => e.message, 'message', contains('Cài đặt'));
      await expectLater(api.fetchConfigJson(), throwsA(isServerError));
      await expectLater(api.streamLinks('trk_1', country: 'VN').toList(), throwsA(isServerError));
      expect(sent, 0);
    });
  });

  group('"Máy chủ" in settings', () {
    Future<AppServices> open(WidgetTester tester, List<String> hosts, {bool configOk = true}) async {
      final s = await fakeServices(handler: (r) async {
        hosts.add(r.url.host);
        if (configOk && r.url.path == '/v1/config') return jsonResponse(_configJson());
        return jsonResponse({'error': 'not_found', 'message': 'x'}, 404);
      });
      await tester.pumpWidget(AppScope(services: s, child: const MaterialApp(home: SettingsScreen())));
      await tester.scrollUntilVisible(find.text('Máy chủ'), 200, scrollable: find.byType(Scrollable).first);
      return s;
    }

    testWidgets('an invalid address is explained and not saved', (tester) async {
      final hosts = <String>[];
      final s = await open(tester, hosts);
      expect(find.text('http://test (mặc định)'), findsOneWidget);

      await tester.tap(find.text('Máy chủ'));
      await tester.pumpAndSettle();
      expect(find.text('Mặc định'), findsNothing, reason: 'nothing to reset yet');
      await tester.enterText(find.byType(TextField), 'ftp://example.com');
      await tester.tap(find.text('Lưu'));
      await tester.pump();
      expect(find.text(ServerAddress.invalidMessage), findsOneWidget);
      expect(s.settings.serverOverride, isNull);

      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(s.settings.serverOverride, isNull);
      expect(hosts, isEmpty);
    });

    testWidgets('a new address is saved, used at once and can be reset', (tester) async {
      final hosts = <String>[];
      final s = await open(tester, hosts);

      await tester.tap(find.text('Máy chủ'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ' api.example.com/ ');
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();
      expect(s.settings.serverOverride, 'https://api.example.com');
      expect(hosts, ['api.example.com'], reason: '/v1/config is reloaded from the new server');
      expect(find.text('Đã kết nối máy chủ'), findsOneWidget);
      expect(find.text('https://api.example.com'), findsOneWidget);

      await tester.tap(find.text('Máy chủ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mặc định'));
      await tester.pumpAndSettle();
      expect(s.settings.serverOverride, isNull);
      expect(hosts, ['api.example.com', 'test']);
      expect(find.text('http://test (mặc định)'), findsOneWidget);
    });

    testWidgets('an address that does not answer is still saved, with a warning', (tester) async {
      final hosts = <String>[];
      final s = await open(tester, hosts, configOk: false);
      await tester.tap(find.text('Máy chủ'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '192.168.1.10:8000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(s.settings.serverOverride, 'http://192.168.1.10:8000');
      expect(find.text('Đã lưu địa chỉ, nhưng chưa kết nối được máy chủ'), findsOneWidget);
    });
  });
}
