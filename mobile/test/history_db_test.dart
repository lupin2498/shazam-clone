import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tim_nhac/models/history_entry.dart';
import 'package:tim_nhac/models/track.dart';
import 'package:tim_nhac/models/track_link.dart';
import 'package:tim_nhac/services/history.dart';

import 'fakes.dart';

void main() {
  sqfliteFfiInit();

  test('SQLite history and pending_sample tables', () async {
    final db = await SqliteHistoryDb.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final repo = HistoryRepository(db);
    await repo.load();

    final older = await repo.add(HistoryEntry(
      track: Track.fromJson(trackJson(id: 'trk_a', title: 'Lạc Trôi')),
      source: 'file',
      createdAt: DateTime(2026, 11, 15, 20),
      flags: const ['maybe_beat'],
      confidence: 0.8,
    ));
    await repo.add(HistoryEntry(
      track: Track.fromJson(trackJson()),
      source: 'mic',
      createdAt: DateTime(2026, 11, 16, 9),
      recognitionId: 'rec_9',
    ));
    await repo.saveLinks(older.id!, const [
      TrackLink(id: 'l1', platform: 'nct', kind: LinkKind.listen, exact: false, url: 'https://nct/x'),
    ]);

    final fresh = HistoryRepository(db);
    await fresh.load();
    expect(fresh.entries.map((e) => e.track.title), ['Nơi Này Có Anh', 'Lạc Trôi']);
    expect(fresh.entries.last.flags, ['maybe_beat']);
    expect(fresh.entries.last.links!.single.platform, 'nct');
    expect(fresh.search('lac troi').single.track.id, 'trk_a');

    await db.insertPending(PendingSample(
      audio: Uint8List.fromList([1, 2, 3]),
      mode: 'auto',
      source: 'mic',
      createdAt: DateTime.now(),
    ));
    await fresh.refreshPendingCount();
    expect(fresh.pendingCount, 1);
    final pending = (await db.pending()).single;
    expect(pending.audio, [1, 2, 3]);
    await db.bumpAttempts(pending.id!);
    expect((await db.pending()).single.attempts, 1);

    await fresh.clearAll();
    expect(fresh.entries, isEmpty);
    expect(fresh.pendingCount, 0);
  });
}
