// F7 offline queue: one bad sample must not block the others, and a stored result must not
// be lost to a storage error.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tim_nhac/models/history_entry.dart';
import 'package:tim_nhac/services/app_services.dart';
import 'package:tim_nhac/services/history.dart';

import 'fakes.dart';

/// History storage whose result table is broken (pending samples still work).
class BrokenHistoryDb extends MemoryHistoryDb {
  @override
  Future<int> insert(HistoryEntry entry) async => throw StateError('disk full');
}

Future<void> _queue(AppServices s, List<int> audio) => s.history.db.insertPending(PendingSample(
      audio: Uint8List.fromList(audio),
      mode: 'auto',
      source: 'mic',
      createdAt: DateTime(2026, 11, 16, 9),
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// First queued sample (audio [1]) gets [rejection]; the second (audio [2]) is recognised.
  Future<AppServices> twoSamples(http.Response rejection, {HistoryDb? db}) async {
    late AppServices s;
    s = await fakeServices(
      db: db,
      handler: (r) async {
        final audio = r.bodyBytes;
        // The multipart body carries the raw sample: [1] is the bad one.
        final first = audio.contains(1) && !audio.contains(2);
        return first ? rejection : jsonResponse(recognitionJson());
      },
    );
    await _queue(s, [1, 1, 1]);
    await _queue(s, [2, 2, 2]);
    return s;
  }

  for (final (name, rejection) in [
    ('too large (413)', jsonResponse({'error': 'payload_too_large', 'message': 'Mẫu âm thanh quá lớn.'}, 413)),
    ('refused by validation (422)', jsonResponse({'error': 'invalid_request', 'message': 'x'}, 422)),
    ('invalid sample (422)', jsonResponse({'error': 'invalid_sample', 'message': 'x'}, 422)),
  ]) {
    test('a sample $name is dropped and the next one is still sent', () async {
      final s = await twoSamples(rejection);
      await s.pending.process();
      expect(await s.history.db.pending(), isEmpty, reason: 'nothing left to block the queue');
      expect(s.history.entries, hasLength(1));
    });
  }

  test('a busy server keeps every sample for later', () async {
    final s = await twoSamples(jsonResponse({'error': 'engines_unavailable', 'message': 'x'}, 503));
    await s.pending.process();
    expect(await s.history.db.pending(), hasLength(2));
  });

  test('a result that cannot be saved is still announced and the queue goes on', () async {
    final s = await fakeServices(db: BrokenHistoryDb(), handler: (_) async => jsonResponse(recognitionJson()));
    final native = s.native as FakeNative;
    await _queue(s, [1, 1, 1]);
    await _queue(s, [2, 2, 2]);
    await s.pending.process(); // must not throw: nobody awaits it in the app
    expect(await s.history.db.pending(), isEmpty);
    expect(native.notifications, hasLength(2));
    expect(native.notifications.first.$1, 'Đã nhận diện bài hát');
  });
}
