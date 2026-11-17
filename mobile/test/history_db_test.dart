import 'dart:io';
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
  test('a version 1 database gets the sync tables; sync bookkeeping and pruning', () async {
    final dir = await Directory.systemTemp.createTemp('timnhac_db');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/timnhac.db';
    // The schema shipped before Drive sync.
    final v1 = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, recognition_id TEXT, '
                'track_id TEXT NOT NULL, track_json TEXT NOT NULL, flags TEXT NOT NULL DEFAULT \'[]\', '
                'confidence REAL, source TEXT NOT NULL, links_json TEXT, created_at INTEGER NOT NULL)');
            await db.execute('CREATE TABLE pending_sample(id INTEGER PRIMARY KEY AUTOINCREMENT, audio BLOB NOT NULL, '
                'mode TEXT NOT NULL, source TEXT NOT NULL, filename_hint TEXT, attempts INTEGER NOT NULL DEFAULT 0, '
                'created_at INTEGER NOT NULL)');
          },
        ));
    await v1.close();

    final db = await SqliteHistoryDb.open(path: path, factory: databaseFactoryFfi);
    expect(db.isPersistent, isTrue);
    expect(await db.syncedKeys(), isEmpty);
    await db.saveSyncState({'a@1', 'b@2'}, {'c@3': 300});
    expect(await db.syncedKeys(), {'a@1', 'b@2'});
    expect(await db.syncDeletions(), {'c@3': 300});
    await db.saveSyncState({'b@2'}, const {});
    expect(await db.syncedKeys(), {'b@2'});
    expect(await db.syncDeletions(), isEmpty);

    for (var i = 0; i < 5; i++) {
      await db.insert(HistoryEntry(
        track: Track.fromJson(trackJson(id: 'k$i')),
        source: 'mic',
        createdAt: DateTime(2026, 11, 17, 9, i),
      ));
    }
    await db.keepNewest(3);
    expect((await db.list()).map((e) => e.track.id), ['k4', 'k3', 'k2']);

    // "Xóa dữ liệu" forgets the sync bookkeeping with the history.
    final repo = HistoryRepository(db);
    await repo.clearAll();
    expect(await db.syncedKeys(), isEmpty);
    expect(repo.entries, isEmpty);
  });

  test('"Hoàn tác" brings a deleted entry back as a new one', () async {
    final repo = HistoryRepository(MemoryHistoryDb());
    final saved = await repo.add(HistoryEntry(
      track: Track.fromJson(trackJson()),
      source: 'mic',
      createdAt: DateTime(2026, 11, 17, 9),
    ));
    await repo.remove(saved.id!);
    await repo.restore(saved);
    expect(repo.entries.single.createdAt, DateTime(2026, 11, 17, 9).add(const Duration(milliseconds: 1)));
  });
}
