import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/history_entry.dart';
import '../models/track.dart';
import '../models/track_link.dart';

/// Storage behind [HistoryRepository]: SQLite on the device, in memory in tests.
abstract class HistoryDb {
  Future<int> insert(HistoryEntry entry);
  Future<void> updateLinks(int id, List<TrackLink> links);
  Future<List<HistoryEntry>> list();
  Future<void> delete(int id);
  Future<void> clear();

  Future<int> insertPending(PendingSample sample);
  Future<List<PendingSample>> pending();
  Future<void> deletePending(int id);
  Future<void> bumpAttempts(int id);
  Future<void> clearPending();

  /// False for the in-memory stand-in used when the database cannot be opened: nothing is
  /// synced from it, its ids are not shown outside the app.
  bool get isPersistent;

  /// Google Drive sync bookkeeping (lib/services/drive_sync.dart), kept in the same file as the
  /// history: losing the history then loses it too, and a lost history can never look like
  /// entries the user deleted. [syncedKeys]: the entries present after the last sync;
  /// [syncDeletions]: deletion marks (key → ms) still worth sending.
  Future<Set<String>> syncedKeys();
  Future<Map<String, int>> syncDeletions();
  Future<void> saveSyncState(Set<String> keys, Map<String, int> deletions);
  Future<void> clearSyncState();

  /// Keeps only the [count] newest entries.
  Future<void> keepNewest(int count);
}

/// Two tables, as in section 8: `history` and `pending_sample`.
class SqliteHistoryDb implements HistoryDb {
  SqliteHistoryDb(this._db);

  final Database _db;

  static Future<SqliteHistoryDb> open({String? path, DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'timnhac.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 2,
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) await _createSyncTables(db);
        },
        onCreate: (db, _) async {
          await _createSyncTables(db);
          await db.execute('''
            CREATE TABLE history(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              recognition_id TEXT,
              track_id TEXT NOT NULL,
              track_json TEXT NOT NULL,
              flags TEXT NOT NULL DEFAULT '[]',
              confidence REAL,
              source TEXT NOT NULL,
              links_json TEXT,
              created_at INTEGER NOT NULL
            )''');
          await db.execute('CREATE INDEX history_created ON history(created_at DESC)');
          await db.execute('''
            CREATE TABLE pending_sample(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              audio BLOB NOT NULL,
              mode TEXT NOT NULL,
              source TEXT NOT NULL,
              filename_hint TEXT,
              attempts INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL
            )''');
        },
      ),
    );
    return SqliteHistoryDb(db);
  }

  static Future<void> _createSyncTables(Database db) async {
    await db.execute('CREATE TABLE sync_key(key TEXT PRIMARY KEY)');
    await db.execute('CREATE TABLE sync_deleted(key TEXT PRIMARY KEY, at INTEGER NOT NULL)');
  }

  @override
  bool get isPersistent => true;

  @override
  Future<Set<String>> syncedKeys() async => {for (final r in await _db.query('sync_key')) r['key'] as String};

  @override
  Future<Map<String, int>> syncDeletions() async =>
      {for (final r in await _db.query('sync_deleted')) r['key'] as String: r['at'] as int};

  @override
  Future<void> saveSyncState(Set<String> keys, Map<String, int> deletions) => _db.transaction((txn) async {
        await txn.delete('sync_key');
        await txn.delete('sync_deleted');
        final batch = txn.batch();
        for (final key in keys) {
          batch.insert('sync_key', {'key': key});
        }
        deletions.forEach((key, at) => batch.insert('sync_deleted', {'key': key, 'at': at}));
        await batch.commit(noResult: true);
      });

  @override
  Future<void> clearSyncState() => _db.transaction((txn) async {
        await txn.delete('sync_key');
        await txn.delete('sync_deleted');
      });

  @override
  Future<void> keepNewest(int count) => _db.rawDelete(
      'DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY created_at DESC LIMIT ?)', [count]);

  static HistoryEntry _entry(Map<String, Object?> row) => HistoryEntry(
        id: row['id'] as int,
        recognitionId: row['recognition_id'] as String?,
        track: Track.fromJson(jsonDecode(row['track_json'] as String) as Map<String, dynamic>),
        flags: (jsonDecode(row['flags'] as String) as List).cast<String>(),
        confidence: (row['confidence'] as num?)?.toDouble(),
        source: row['source'] as String,
        links: row['links_json'] == null
            ? null
            : (jsonDecode(row['links_json'] as String) as List)
                .map((l) => TrackLink.fromJson(l as Map<String, dynamic>))
                .toList(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      );

  @override
  Future<int> insert(HistoryEntry e) => _db.insert('history', {
        'recognition_id': e.recognitionId,
        'track_id': e.track.id,
        'track_json': jsonEncode(e.track.toJson()),
        'flags': jsonEncode(e.flags),
        'confidence': e.confidence,
        'source': e.source,
        'links_json': e.links == null ? null : jsonEncode(e.links!.map((l) => l.toJson()).toList()),
        'created_at': e.createdAt.millisecondsSinceEpoch,
      });

  @override
  Future<void> updateLinks(int id, List<TrackLink> links) => _db.update(
        'history',
        {'links_json': jsonEncode(links.map((l) => l.toJson()).toList())},
        where: 'id = ?',
        whereArgs: [id],
      );

  @override
  Future<List<HistoryEntry>> list() async =>
      (await _db.query('history', orderBy: 'created_at DESC', limit: 1000)).map(_entry).toList();

  @override
  Future<void> delete(int id) => _db.delete('history', where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> clear() => _db.delete('history');

  @override
  Future<int> insertPending(PendingSample s) => _db.insert('pending_sample', {
        'audio': s.audio,
        'mode': s.mode,
        'source': s.source,
        'filename_hint': s.filenameHint,
        'attempts': s.attempts,
        'created_at': s.createdAt.millisecondsSinceEpoch,
      });

  @override
  Future<List<PendingSample>> pending() async => (await _db.query('pending_sample', orderBy: 'created_at'))
      .map((r) => PendingSample(
            id: r['id'] as int,
            audio: r['audio'] as Uint8List,
            mode: r['mode'] as String,
            source: r['source'] as String,
            filenameHint: r['filename_hint'] as String?,
            attempts: r['attempts'] as int,
            createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
          ))
      .toList();

  @override
  Future<void> deletePending(int id) => _db.delete('pending_sample', where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> bumpAttempts(int id) =>
      _db.rawUpdate('UPDATE pending_sample SET attempts = attempts + 1 WHERE id = ?', [id]);

  @override
  Future<void> clearPending() => _db.delete('pending_sample');
}

/// In-memory implementation for tests and as a fallback if SQLite cannot open.
class MemoryHistoryDb implements HistoryDb {
  /// [isPersistent] is false when this replaces a database that failed to open; tests use it
  /// in place of the real database.
  MemoryHistoryDb({this.isPersistent = true});

  @override
  final bool isPersistent;

  final _entries = <HistoryEntry>[];
  final _pending = <PendingSample>[];
  var _nextId = 1;
  Set<String> _syncedKeys = {};
  Map<String, int> _syncDeletions = {};

  @override
  Future<Set<String>> syncedKeys() async => {..._syncedKeys};

  @override
  Future<Map<String, int>> syncDeletions() async => {..._syncDeletions};

  @override
  Future<void> saveSyncState(Set<String> keys, Map<String, int> deletions) async {
    _syncedKeys = {...keys};
    _syncDeletions = {...deletions};
  }

  @override
  Future<void> clearSyncState() async {
    _syncedKeys = {};
    _syncDeletions = {};
  }

  @override
  Future<void> keepNewest(int count) async {
    _entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (_entries.length > count) _entries.removeRange(count, _entries.length);
  }

  @override
  Future<int> insert(HistoryEntry e) async {
    final id = _nextId++;
    _entries.add(e.copyWith(id: id));
    return id;
  }

  @override
  Future<void> updateLinks(int id, List<TrackLink> links) async {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i >= 0) _entries[i] = _entries[i].copyWith(links: links);
  }

  @override
  Future<List<HistoryEntry>> list() async =>
      [..._entries]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<void> delete(int id) async => _entries.removeWhere((e) => e.id == id);

  @override
  Future<void> clear() async => _entries.clear();

  @override
  Future<int> insertPending(PendingSample s) async {
    final id = _nextId++;
    _pending.add(PendingSample(
        id: id,
        audio: s.audio,
        mode: s.mode,
        source: s.source,
        createdAt: s.createdAt,
        filenameHint: s.filenameHint,
        attempts: s.attempts));
    return id;
  }

  @override
  Future<List<PendingSample>> pending() async => [..._pending];

  @override
  Future<void> deletePending(int id) async => _pending.removeWhere((s) => s.id == id);

  @override
  Future<void> bumpAttempts(int id) async {}

  @override
  Future<void> clearPending() async => _pending.clear();
}

/// History screen and home screen ("3 kết quả gần nhất") listen to this.
class HistoryRepository extends ChangeNotifier {
  HistoryRepository(this.db);

  final HistoryDb db;
  List<HistoryEntry> _entries = const [];
  int _pendingCount = 0;

  List<HistoryEntry> get entries => _entries;
  List<HistoryEntry> get recent => _entries.take(3).toList();
  int get pendingCount => _pendingCount;

  Future<void> load() async {
    _entries = await db.list();
    _pendingCount = (await db.pending()).length;
    notifyListeners();
  }

  Future<HistoryEntry> add(HistoryEntry entry) async {
    final id = await db.insert(entry);
    final saved = entry.copyWith(id: id);
    _entries = [saved, ..._entries];
    notifyListeners();
    return saved;
  }

  Future<void> saveLinks(int id, List<TrackLink> links) async {
    await db.updateLinks(id, links);
    _entries = [for (final e in _entries) e.id == id ? e.copyWith(links: links) : e];
    notifyListeners();
  }

  Future<void> remove(int id) async {
    await db.delete(id);
    _entries = _entries.where((e) => e.id != id).toList();
    notifyListeners();
  }

  /// "Hoàn tác" after a deletion. The entry comes back as a new one (1 ms later): if the deletion
  /// was already synced, its deletion mark must not remove the restored entry on every device.
  Future<void> restore(HistoryEntry entry) async {
    await db.insert(entry.copyWith(createdAt: entry.createdAt.add(const Duration(milliseconds: 1))));
    await load();
  }

  Future<void> clearAll() async {
    await db.clear();
    await db.clearPending();
    await db.clearSyncState();
    await load();
  }

  Future<void> refreshPendingCount() async {
    _pendingCount = (await db.pending()).length;
    notifyListeners();
  }

  /// Filter for the history search box (title, artist, album; accents ignored).
  List<HistoryEntry> search(String query) {
    final q = foldVietnamese(query.trim());
    if (q.isEmpty) return _entries;
    return _entries
        .where((e) => foldVietnamese('${e.track.title} ${e.track.artistLine} ${e.track.album ?? ''}').contains(q))
        .toList();
  }
}

const _vnFrom = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
const _vnTo = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';

/// Combining marks (U+0300–U+036F): what decomposed (NFD) text puts after the base letter.
bool _isCombiningMark(int rune) => rune >= 0x0300 && rune <= 0x036F;

/// Lower-case and strip Vietnamese diacritics: "Nơi Này Có Anh" → "noi nay co anh".
///
/// Works on precomposed (NFC) and decomposed (NFD) text alike: titles from file names on
/// iOS/macOS and some keyboards arrive as base letter + combining marks.
String foldVietnamese(String input) {
  final lower = input.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    if (_isCombiningMark(rune)) continue;
    final ch = String.fromCharCode(rune);
    final i = _vnFrom.indexOf(ch);
    buffer.write(i >= 0 ? _vnTo[i] : ch);
  }
  return buffer.toString();
}
