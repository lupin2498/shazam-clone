import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tim_nhac/models/history_entry.dart';
import 'package:tim_nhac/models/track.dart';
import 'package:tim_nhac/screens/settings_screen.dart';
import 'package:tim_nhac/services/app_services.dart';
import 'package:tim_nhac/services/drive_sync.dart';
import 'package:tim_nhac/services/google_account.dart';
import 'package:tim_nhac/services/native_bridge.dart';
import 'package:tim_nhac/services/settings_store.dart';

import 'fakes.dart';

/// Google Drive's appDataFolder, in memory: the few REST calls DriveClient makes.
class FakeDrive {
  final files = <String, ({String content, int modified})>{};
  final requests = <http.Request>[];
  Set<String> validTokens = {'token-1'};
  bool offline = false;
  int? failStatus;
  String? failReason;
  var _nextId = 1;
  var _clock = 0;

  /// The single sync file, decoded.
  SyncSnapshot get snapshot => SyncSnapshot.tryParse(files.values.single.content)!;

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    if (offline) throw http.ClientException('offline');
    if (r.url.host == 'openidconnect.googleapis.com') return jsonResponse({'email': 'an@example.com'});
    if (r.url.host != 'www.googleapis.com') return jsonResponse({'error': 'not_found', 'message': 'x'}, 404);
    final token = (r.headers['Authorization'] ?? '').replaceFirst('Bearer ', '');
    if (!validTokens.contains(token)) return _error(401, 'authError');
    if (failStatus != null) return _error(failStatus!, failReason);
    final path = r.url.path;
    final id = r.url.pathSegments.last;
    if (r.method == 'GET' && path == '/drive/v3/files') {
      expect(r.url.queryParameters['spaces'], 'appDataFolder');
      final list = files.entries.toList()..sort((a, b) => b.value.modified.compareTo(a.value.modified));
      return jsonResponse({
        'files': [
          for (final e in list)
            {'id': e.key, 'modifiedTime': DateTime.fromMillisecondsSinceEpoch(e.value.modified, isUtc: true).toIso8601String()},
        ],
      });
    }
    if (r.method == 'GET' && path.startsWith('/drive/v3/files/')) {
      expect(r.url.queryParameters['alt'], 'media');
      final file = files[id];
      return file == null ? _error(404, 'notFound') : http.Response.bytes(utf8.encode(file.content), 200);
    }
    if (r.method == 'POST' && path == '/upload/drive/v3/files') {
      expect(r.url.queryParameters['uploadType'], 'multipart');
      final boundary = r.headers['Content-Type']!.split('boundary=').last;
      final parts = [
        for (final part in r.body.split('--$boundary'))
          if (part.contains('\r\n\r\n')) part.substring(part.indexOf('\r\n\r\n') + 4).replaceFirst(RegExp(r'\r\n$'), ''),
      ];
      final metadata = jsonDecode(parts[0]) as Map<String, dynamic>;
      expect(metadata['parents'], ['appDataFolder']);
      expect(metadata['name'], DriveClient.fileName);
      final newId = 'f${_nextId++}';
      files[newId] = (content: parts[1], modified: ++_clock);
      return jsonResponse({'id': newId});
    }
    if (r.method == 'PATCH' && path.startsWith('/upload/drive/v3/files/')) {
      expect(r.url.queryParameters['uploadType'], 'media');
      files[id] = (content: r.body, modified: ++_clock);
      return jsonResponse({'id': id});
    }
    if (r.method == 'DELETE' && path.startsWith('/drive/v3/files/')) {
      return files.remove(id) == null ? _error(404, 'notFound') : http.Response('', 204);
    }
    return _error(400, 'badRequest');
  }

  http.Response _error(int status, String? reason) => jsonResponse({
        'error': {
          'code': status,
          'errors': [
            {'reason': ?reason},
          ],
        },
      }, status);
}

HistoryEntry entry(String trackId, int minute, {String source = 'mic'}) => HistoryEntry(
      track: Track.fromJson(trackJson(id: trackId, title: 'Bài $trackId')),
      source: source,
      createdAt: DateTime(2026, 11, 16, 10, minute),
      recognitionId: 'rec_$trackId',
    );

/// One "device": its own preferences, history and Google account, sharing [drive].
Future<(AppServices, FakeNative)> device(FakeDrive drive) async {
  final native = FakeNative();
  final services = await fakeServices(native: native, handler: drive.handle);
  return (services, native);
}

Set<String> titles(AppServices s) => {for (final e in s.history.entries) e.track.title};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncSnapshot', () {
    SyncEntry e(String key, int at) => SyncEntry(key: key, createdAt: at, source: 'mic', track: trackJson(id: key));

    test('deletion marks and clearing win over entries; newer settings win', () {
      final a = SyncSnapshot(
        entries: [e('a', 10), e('b', 20)],
        deleted: const {'c': 5},
        settings: const SyncSettings(updatedAt: 100, country: 'US'),
      );
      final b = SyncSnapshot(
        historyClearedAt: 15,
        entries: [e('c', 30), e('d', 40)],
        deleted: const {'b': 50},
        settings: const SyncSettings(updatedAt: 200, country: 'JP'),
      );
      final merged = SyncSnapshot.combine(a, b);
      // a (10) is older than the clearing at 15; b and c are marked deleted.
      expect(merged.entries.map((x) => x.key), ['d']);
      expect(merged.historyClearedAt, 15);
      expect(merged.deleted, {'c': 5, 'b': 50});
      expect(merged.settings!.country, 'JP');
      // Old deletion marks are dropped after a while.
      expect(SyncSnapshot.combine(a, b, pruneDeletedBefore: 10).deleted, {'b': 50});
    });

    test('encodes canonically and parses back; unknown content is ignored', () {
      final x = SyncSnapshot(entries: [e('a', 10), e('b', 20)], deleted: const {'z': 1, 'y': 2});
      final y = SyncSnapshot(entries: [e('b', 20), e('a', 10)], deleted: const {'y': 2, 'z': 1});
      expect(x.encode(), y.encode());
      final back = SyncSnapshot.tryParse(x.encode())!;
      expect(back.encode(), x.encode());
      expect(SyncSnapshot.tryParse('not json'), isNull);
      expect(SyncSnapshot.tryParse('{"history": []}'), isNull);
      expect(() => SyncSnapshot.tryParse('{"format": 2}'), throwsA(isA<SyncFormatException>()));
    });

    test('keeps the newest 1000 entries', () {
      final many = SyncSnapshot(entries: [for (var i = 0; i < 1005; i++) e('k$i', i)]);
      final merged = SyncSnapshot.combine(many, const SyncSnapshot());
      expect(merged.entries.length, 1000);
      expect(merged.entries.first.key, 'k1004');
      expect(merged.entries.last.key, 'k5');
    });
  });

  group('two devices', () {
    test('the first sign-in uploads this device; a new device restores everything', () async {
      final drive = FakeDrive();
      final (a, nativeA) = await device(drive);
      await a.history.add(entry('t1', 1));
      await a.history.add(entry('t2', 2, source: 'playback'));
      await a.settings.setCountry('US');
      await a.settings.setServerOverride('https://api.example.com');

      expect(await a.sync.signIn(), isTrue);
      expect(a.account.email, 'an@example.com');
      expect(a.sync.state, SyncState.ok);
      expect(nativeA.googleCalls.first.interactive, isTrue);
      final remote = drive.snapshot;
      expect(remote.entries.length, 2);
      expect(remote.settings!.country, 'US');
      expect(remote.settings!.serverUrl, 'https://api.example.com');
      // Only the hidden app folder, and no audio, no device id.
      expect(drive.files.values.single.content, isNot(contains(a.settings.deviceId)));

      final (b, _) = await device(drive);
      expect(b.history.entries, isEmpty);
      expect(await b.sync.signIn(), isTrue);
      expect(b.sync.lastRestored, isTrue);
      expect(titles(b), {'Bài t1', 'Bài t2'});
      expect(b.history.entries.firstWhere((x) => x.track.id == 't2').source, 'playback');
      expect(b.settings.serverOverride, 'https://api.example.com');
      expect(b.settings.country, 'US');
      expect(b.api.currentBaseUrl, 'https://api.example.com');
      expect(drive.files.length, 1);
    });

    test('additions, deletions and clearing reach the other device', () async {
      final drive = FakeDrive();
      final (a, _) = await device(drive);
      await a.history.add(entry('t1', 1));
      await a.history.add(entry('t2', 2));
      await a.sync.signIn();
      final (b, _) = await device(drive);
      await b.sync.signIn();

      // B deletes t1 and recognises t3.
      await b.history.remove(b.history.entries.firstWhere((x) => x.track.id == 't1').id!);
      await b.history.add(entry('t3', 3));
      await b.sync.sync();
      await a.sync.sync();
      expect(titles(a), {'Bài t2', 'Bài t3'});
      expect(drive.snapshot.deleted.keys.single, startsWith('t1@'));

      // A deleting does not bring the entry back on B either.
      await a.history.remove(a.history.entries.firstWhere((x) => x.track.id == 't3').id!);
      await a.sync.sync();
      await b.sync.sync();
      expect(titles(b), {'Bài t2'});

      // "Xóa dữ liệu" with "mọi máy".
      await a.sync.clearEverywhere();
      await b.sync.sync();
      expect(b.history.entries, isEmpty);
      expect(a.history.entries, isEmpty);
    });

    test('the settings changed last win', () async {
      final drive = FakeDrive();
      final (a, _) = await device(drive);
      await a.settings.setCountry('US');
      await a.sync.signIn();
      final (b, _) = await device(drive);
      await b.sync.signIn();
      expect(b.settings.country, 'US');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await b.settings.setCountry('JP');
      await b.settings.setPreferredPlatforms(['spotify', 'youtube']);
      await b.sync.sync();
      await a.sync.sync();
      expect(a.settings.country, 'JP');
      expect(a.settings.preferredPlatforms, ['spotify', 'youtube']);
      // Nothing changed since: a second sync does not write to Drive.
      final writes = drive.requests.where((r) => r.method != 'GET').length;
      await a.sync.sync();
      expect(drive.requests.where((r) => r.method != 'GET').length, writes);
    });

    test('two sync files (created at the same time) are merged into one', () async {
      final drive = FakeDrive();
      drive.files['old'] = (
        content: SyncSnapshot(entries: [SyncEntry.fromHistory(entry('t9', 9))]).encode(),
        modified: 0,
      );
      final (a, _) = await device(drive);
      await a.history.add(entry('t1', 1));
      drive.files['new'] = (content: const SyncSnapshot().encode(), modified: 1);
      await a.sync.signIn();
      expect(drive.files.keys, ['new']);
      expect(titles(a), {'Bài t1', 'Bài t9'});
      expect(drive.snapshot.entries.length, 2);
    });
  });

  group('errors', () {
    test('a rejected token is renewed once and the call retried', () async {
      final drive = FakeDrive();
      final (a, native) = await device(drive);
      await a.sync.signIn();
      drive.validTokens = {'token-2'};
      native.googleAnswer = ({required bool interactive, String? invalidToken}) =>
          GoogleAuthorization(accessToken: invalidToken == null ? 'token-1' : 'token-2', email: 'an@example.com');
      await a.history.add(entry('t1', 1));
      await a.sync.sync();
      expect(a.sync.state, SyncState.ok);
      expect(native.googleCalls.last.invalidToken, 'token-1');
      expect(native.googleCalls.last.email, 'an@example.com');
      expect(native.googleCalls.last.interactive, isFalse);
    });

    test('Google wanting the user again shows "đăng nhập lại"', () async {
      final drive = FakeDrive();
      final (a, native) = await device(drive);
      await a.sync.signIn();
      drive.validTokens = {};
      native.googleAnswer = ({required bool interactive, String? invalidToken}) => null;
      await a.sync.sync();
      expect(a.sync.state, SyncState.needsSignIn);
      expect(a.account.signedIn, isTrue); // the account stays, the user just signs in again
    });

    test('offline, Drive full, Drive not allowed, newer app version', () async {
      final drive = FakeDrive();
      final (a, _) = await device(drive);
      await a.sync.signIn();

      drive.offline = true;
      await a.sync.sync();
      expect(a.sync.state, SyncState.offline);
      drive.offline = false;

      drive
        ..failStatus = 403
        ..failReason = 'storageQuotaExceeded';
      await a.sync.sync();
      expect(a.sync.state, SyncState.driveFull);
      drive.failReason = 'insufficientPermissions';
      await a.sync.sync();
      expect(a.sync.state, SyncState.noDriveAccess);
      drive.failStatus = null;

      final id = drive.files.keys.single;
      drive.files[id] = (content: '{"format": 2, "history": []}', modified: 99);
      await a.sync.sync();
      expect(a.sync.state, SyncState.newerFormat);
      expect(drive.files[id]!.content, '{"format": 2, "history": []}'); // not overwritten
    });

    test('signing out can delete the Drive copy; the local history stays', () async {
      final drive = FakeDrive();
      final (a, native) = await device(drive);
      await a.history.add(entry('t1', 1));
      await a.sync.signIn();
      expect(await a.sync.signOut(deleteRemote: true), isTrue);
      expect(drive.files, isEmpty);
      expect(a.account.signedIn, isFalse);
      expect(a.settings.syncKnownKeys, isEmpty);
      expect(native.googleSignOuts, 1);
      expect(titles(a), {'Bài t1'});
    });
  });

  test('local changes are synced after a pause, reloading alone is not', () {
    fakeAsync((async) {
      final drive = FakeDrive();
      late AppServices a;
      device(drive).then((d) async {
        a = d.$1;
        await a.sync.signIn();
        a.sync.start();
      });
      async.elapse(const Duration(seconds: 1));
      expect(a.account.signedIn, isTrue);
      final baseline = drive.requests.length;

      a.history.load();
      async.elapse(const Duration(seconds: 20));
      expect(drive.requests.length, baseline, reason: 'same entries: nothing to sync');

      a.history.add(entry('t1', 1));
      async.elapse(const Duration(seconds: 7));
      expect(drive.requests.length, baseline, reason: 'waits for the undo snack bar');
      async.elapse(const Duration(seconds: 2));
      expect(drive.snapshot.entries.single.key, startsWith('t1@'));

      final afterHistory = drive.requests.length;
      a.settings.setCountry('KR');
      async.elapse(const Duration(seconds: 4));
      expect(drive.requests.length, greaterThan(afterHistory));
      expect(drive.snapshot.settings!.country, 'KR');
    });
  });

  group('GoogleAccount', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    Future<SettingsStore> prefs() async {
      SharedPreferences.setMockInitialValues({});
      return SettingsStore.load();
    }

    test('an iOS build without a client id cannot sign in', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final account = GoogleAccount(native: FakeNative(), settings: await prefs(), client: MockClient((_) async => http.Response('', 500)));
      expect(account.configured, isFalse);
      expect(account.signIn, throwsA(isA<GoogleAuthException>().having((e) => e.code, 'code', 'not_configured')));
    });

    test('iOS: the client id is passed and the e-mail comes from Google', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final native = FakeNative()..googleAuth = const GoogleAuthorization(accessToken: 'token-1', expiresIn: 3600);
      final drive = FakeDrive();
      final account = GoogleAccount(
        native: native,
        settings: await prefs(),
        client: MockClient(drive.handle),
        iosClientId: '1234-abcd.apps.googleusercontent.com',
      );
      expect(await account.signIn(), isTrue);
      expect(account.email, 'an@example.com');
      expect(native.googleCalls.single.iosClientId, '1234-abcd.apps.googleusercontent.com');
    });

    test('tokens are reused until they expire', () async {
      var now = DateTime(2026, 11, 17, 9);
      final native = FakeNative()..googleAuth = const GoogleAuthorization(accessToken: 'token-1', email: 'an@example.com', expiresIn: 3600);
      final account = GoogleAccount(
        native: native,
        settings: await prefs(),
        client: MockClient((_) async => http.Response('', 500)),
        clock: () => now,
      );
      await account.signIn();
      expect(await account.accessToken(), 'token-1');
      expect(await account.accessToken(), 'token-1');
      expect(native.googleCalls.length, 1);
      now = now.add(const Duration(minutes: 59, seconds: 30));
      await account.accessToken();
      expect(native.googleCalls.length, 2);
      expect(native.googleCalls.last.interactive, isFalse);
    });

    test('Google refusing the app is reported as not configured; cancel is not an error', () async {
      final native = FakeNative()..googleError = PlatformException(code: 'not_configured');
      final account = GoogleAccount(native: native, settings: await prefs(), client: MockClient((_) async => http.Response('', 500)));
      expect(account.signIn, throwsA(isA<GoogleAuthException>().having((e) => e.code, 'code', 'not_configured')));
      native.googleError = PlatformException(code: 'cancelled');
      expect(await account.signIn(), isFalse);
      native
        ..googleError = null
        ..googleAuth = null;
      expect(await account.signIn(), isFalse);
      expect(account.signedIn, isFalse);
    });
  });

  group('settings screen', () {
    Future<AppServices> open(WidgetTester tester, FakeDrive drive) async {
      final (s, _) = await device(drive);
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppScope(services: s, child: const MaterialApp(home: SettingsScreen())));
      return s;
    }

    testWidgets('sign in, see the last sync, sign out', (tester) async {
      final drive = FakeDrive();
      final s = await open(tester, drive);
      expect(find.text('Đồng bộ Google Drive'), findsOneWidget);
      await tester.tap(find.text('Đăng nhập Google'));
      await tester.pumpAndSettle();
      expect(find.text('an@example.com'), findsOneWidget);
      expect(find.textContaining('Đã đồng bộ lúc'), findsOneWidget);
      expect(find.textContaining('đồng bộ qua Google Drive'), findsOneWidget);

      await tester.tap(find.text('Đăng xuất'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa cả bản sao trên Google Drive'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Đăng xuất'));
      await tester.pumpAndSettle();
      expect(find.text('Đăng nhập Google'), findsOneWidget);
      expect(s.account.signedIn, isFalse);
      expect(drive.files, isEmpty);
    });

    testWidgets('"Xóa dữ liệu" while signed in also signs this device out', (tester) async {
      final drive = FakeDrive();
      final s = await open(tester, drive);
      await s.history.add(entry('t1', 1));
      await tester.tap(find.text('Đăng nhập Google'));
      await tester.pumpAndSettle();
      expect(s.account.signedIn, isTrue);
      await tester.tap(find.text('Xóa dữ liệu'));
      await tester.pumpAndSettle();
      expect(find.text('Xóa cả lịch sử đã đồng bộ trên mọi máy'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Xóa'));
      await tester.pumpAndSettle();
      expect(s.account.signedIn, isFalse);
      expect(s.history.entries, isEmpty);
      // Not "everywhere": the copy on Drive keeps the history for the other devices.
      expect(drive.snapshot.entries.length, 1);
    });

    test('the status line', () {
      final now = DateTime(2026, 11, 17, 15, 30);
      expect(formatSyncTime(DateTime(2026, 11, 17, 9, 5), now), 'lúc 09:05');
      expect(formatSyncTime(DateTime(2026, 11, 16, 23, 59), now), 'lúc 23:59 ngày 16/11');
    });
  });
}
