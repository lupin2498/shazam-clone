import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/history_entry.dart';
import '../models/track.dart';
import 'google_account.dart';
import 'history.dart';
import 'settings_store.dart';

/// "Đồng bộ Google Drive": the history and the synced settings (country, preferred platforms,
/// backend address) live in one JSON file in the app's hidden folder on the user's Drive
/// (`appDataFolder`, invisible in Drive and to other apps). Every device merges its own state
/// with that file, so reinstalling or adding a device restores everything. Audio samples, the
/// offline queue and the anonymous device id are never synced.

/// Stable identity of a history entry across devices.
String historyKey(HistoryEntry e) => '${e.track.id}@${e.createdAt.millisecondsSinceEpoch}';

/// Error from the Drive REST API. [status] 0 means the network failed.
class DriveException implements Exception {
  const DriveException(this.status, [this.reason]);

  final int status;
  final String? reason;

  bool get isNetwork => status == 0;
  bool get unauthorized => status == 401;
  bool get storageFull => reason == 'storageQuotaExceeded';

  /// The user did not grant the Drive permission on Google's consent screen.
  bool get noDriveAccess =>
      status == 403 &&
      (reason == 'insufficientPermissions' || reason == 'insufficientScopes' || reason == 'ACCESS_TOKEN_SCOPE_INSUFFICIENT');

  static DriveException fromResponse(http.Response resp) {
    String? reason;
    try {
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      final error = body is Map ? body['error'] : null;
      if (error is Map) {
        final errors = error['errors'];
        if (errors is List && errors.isNotEmpty && errors.first is Map) reason = errors.first['reason'] as String?;
        final details = error['details'];
        if (details is List) {
          for (final d in details) {
            if (d is Map && d['reason'] is String) reason ??= d['reason'] as String;
          }
        }
        reason ??= error['status'] as String?;
      }
    } catch (_) {}
    return DriveException(resp.statusCode, reason);
  }

  @override
  String toString() => 'DriveException($status, $reason)';
}

class DriveFile {
  const DriveFile(this.id, this.modified);

  final String id;
  final DateTime? modified;
}

/// The few Drive v3 calls the sync needs, on the app's hidden folder only.
class DriveClient {
  DriveClient(this._http, {this.timeout = const Duration(seconds: 20)});

  static const fileName = 'tim-nhac-sync.json';
  static const _files = 'https://www.googleapis.com/drive/v3/files';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';

  final http.Client _http;
  final Duration timeout;

  /// The sync files, newest first (normally one; two devices creating it at once make two).
  Future<List<DriveFile>> list(String token) async {
    final uri = Uri.parse(_files).replace(queryParameters: {
      'spaces': 'appDataFolder',
      'q': "name = '$fileName' and trashed = false",
      'fields': 'files(id,modifiedTime)',
      'orderBy': 'modifiedTime desc',
      'pageSize': '10',
    });
    final body = _json(await _send('GET', uri, token));
    final files = body['files'];
    if (files is! List) return const [];
    return [
      for (final f in files)
        if (f is Map && f['id'] is String) DriveFile(f['id'] as String, DateTime.tryParse('${f['modifiedTime']}')),
    ];
  }

  Future<String> read(String token, String id) async {
    final resp = await _send('GET', Uri.parse('$_files/$id').replace(queryParameters: {'alt': 'media'}), token);
    return utf8.decode(resp.bodyBytes, allowMalformed: true);
  }

  /// Creates the sync file in the hidden folder; returns its id.
  Future<String> create(String token, String content) async {
    final boundary = 'timnhac-${Random.secure().nextInt(1 << 32).toRadixString(16)}-${content.length}';
    final metadata = jsonEncode({
      'name': fileName,
      'parents': ['appDataFolder'],
      'mimeType': 'application/json',
    });
    final body = '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$metadata\r\n'
        '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$content\r\n'
        '--$boundary--\r\n';
    final resp = await _send(
      'POST',
      Uri.parse(_upload).replace(queryParameters: {'uploadType': 'multipart', 'fields': 'id'}),
      token,
      body: utf8.encode(body),
      contentType: 'multipart/related; boundary=$boundary',
    );
    final id = _json(resp)['id'];
    if (id is! String) throw const DriveException(500, 'no id');
    return id;
  }

  Future<void> update(String token, String id, String content) => _send(
        'PATCH',
        Uri.parse('$_upload/$id').replace(queryParameters: {'uploadType': 'media', 'fields': 'id'}),
        token,
        body: utf8.encode(content),
        contentType: 'application/json; charset=UTF-8',
      );

  Future<void> delete(String token, String id) async {
    try {
      await _send('DELETE', Uri.parse('$_files/$id'), token);
    } on DriveException catch (e) {
      if (e.status != 404) rethrow; // already gone
    }
  }

  Map<String, dynamic> _json(http.Response resp) {
    try {
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      if (body is Map<String, dynamic>) return body;
    } catch (_) {}
    throw DriveException(resp.statusCode, 'bad_response');
  }

  Future<http.Response> _send(String method, Uri uri, String token, {List<int>? body, String? contentType}) async {
    final request = http.Request(method, uri)..headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.bodyBytes = body;
      request.headers['Content-Type'] = contentType ?? 'application/octet-stream';
    }
    final http.Response resp;
    try {
      resp = await Future(() async => http.Response.fromStream(await _http.send(request))).timeout(timeout);
    } on TimeoutException {
      throw const DriveException(0, 'timeout');
    } on IOException {
      throw const DriveException(0, 'io');
    } on http.ClientException {
      throw const DriveException(0, 'client');
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) return resp;
    throw DriveException.fromResponse(resp);
  }
}

/// One history entry as stored in the sync file (links are not synced: they are fetched again).
class SyncEntry {
  const SyncEntry({
    required this.key,
    required this.createdAt,
    required this.source,
    required this.track,
    this.recognitionId,
    this.flags = const [],
    this.confidence,
  });

  final String key;
  final int createdAt;
  final String source;
  final Map<String, dynamic> track;
  final String? recognitionId;
  final List<String> flags;
  final double? confidence;

  factory SyncEntry.fromHistory(HistoryEntry e) => SyncEntry(
        key: historyKey(e),
        createdAt: e.createdAt.millisecondsSinceEpoch,
        source: e.source,
        track: e.track.toJson(),
        recognitionId: e.recognitionId,
        flags: e.flags,
        confidence: e.confidence,
      );

  HistoryEntry toHistoryEntry() => HistoryEntry(
        track: Track.fromJson(track),
        source: source,
        createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
        recognitionId: recognitionId,
        flags: flags,
        confidence: confidence,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'createdAt': createdAt,
        'source': source,
        'recognitionId': ?recognitionId,
        'flags': flags,
        'confidence': ?confidence,
        'track': track,
      };

  static SyncEntry? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final key = j['key'], createdAt = j['createdAt'], source = j['source'], track = j['track'];
    if (key is! String || createdAt is! num || source is! String || track is! Map<String, dynamic>) return null;
    try {
      Track.fromJson(track); // only entries this app can show
    } catch (_) {
      return null;
    }
    final flags = j['flags'];
    return SyncEntry(
      key: key,
      createdAt: createdAt.toInt(),
      source: source,
      track: track,
      recognitionId: j['recognitionId'] as String?,
      flags: flags is List ? flags.whereType<String>().toList() : const [],
      confidence: (j['confidence'] as num?)?.toDouble(),
    );
  }
}

/// The synced settings; the side changed last wins as a whole.
class SyncSettings {
  const SyncSettings({
    required this.updatedAt,
    this.country,
    this.preferredPlatforms = const [],
    this.serverUrl,
  });

  final int updatedAt;

  /// Null: the default country.
  final String? country;
  final List<String> preferredPlatforms;

  /// Null: the address the app was built with.
  final String? serverUrl;

  Map<String, dynamic> toJson() => {
        'updatedAt': updatedAt,
        'country': country,
        'preferredPlatforms': preferredPlatforms,
        'serverUrl': serverUrl,
      };

  static SyncSettings? tryFromJson(Object? j) {
    if (j is! Map || j['updatedAt'] is! num) return null;
    final preferred = j['preferredPlatforms'];
    return SyncSettings(
      updatedAt: (j['updatedAt'] as num).toInt(),
      country: j['country'] as String?,
      preferredPlatforms: preferred is List ? preferred.whereType<String>().toList() : const [],
      serverUrl: j['serverUrl'] as String?,
    );
  }
}

/// A sync file written by a newer version of the app.
class SyncFormatException implements Exception {
  const SyncFormatException(this.format);

  final int format;
}

/// Content of the sync file.
class SyncSnapshot {
  const SyncSnapshot({
    this.historyClearedAt = 0,
    this.deleted = const {},
    this.entries = const [],
    this.settings,
  });

  static const format = 1;
  static const maxEntries = 1000;

  /// Entries recorded up to this time (ms) were cleared on every device.
  final int historyClearedAt;

  /// Deleted entries: key → when (ms), so another device does not bring them back.
  final Map<String, int> deleted;

  /// Newest first.
  final List<SyncEntry> entries;
  final SyncSettings? settings;

  /// Union of two states: deletions and clearing win over entries, newer settings win, at most
  /// [maxEntries] entries (the newest). Deletion marks older than [pruneDeletedBefore] are dropped.
  static SyncSnapshot combine(SyncSnapshot a, SyncSnapshot b, {int pruneDeletedBefore = 0}) {
    final cleared = max(a.historyClearedAt, b.historyClearedAt);
    final deleted = <String, int>{};
    for (final marks in [a.deleted, b.deleted]) {
      marks.forEach((key, at) {
        if (at >= pruneDeletedBefore) deleted[key] = max(deleted[key] ?? 0, at);
      });
    }
    final byKey = <String, SyncEntry>{};
    for (final e in [...a.entries, ...b.entries]) {
      byKey.putIfAbsent(e.key, () => e);
    }
    final entries = byKey.values.where((e) => !deleted.containsKey(e.key) && e.createdAt > cleared).toList()
      ..sort(_newestFirst);
    final sa = a.settings, sb = b.settings;
    final settings = sa == null ? sb : (sb == null || sa.updatedAt >= sb.updatedAt ? sa : sb);
    return SyncSnapshot(
      historyClearedAt: cleared,
      deleted: deleted,
      entries: entries.length > maxEntries ? entries.sublist(0, maxEntries) : entries,
      settings: settings,
    );
  }

  static int _newestFirst(SyncEntry x, SyncEntry y) {
    final byTime = y.createdAt.compareTo(x.createdAt);
    return byTime != 0 ? byTime : x.key.compareTo(y.key);
  }

  /// Canonical JSON: the same state always encodes to the same text.
  String encode() {
    final marks = deleted.keys.toList()..sort();
    return jsonEncode({
      'format': format,
      'app': 'tim-nhac',
      'historyClearedAt': historyClearedAt,
      'settings': settings?.toJson(),
      'history': [for (final e in [...entries]..sort(_newestFirst)) e.toJson()],
      'deleted': {for (final k in marks) k: deleted[k]},
    });
  }

  /// Null when the text is not a sync file. Throws [SyncFormatException] for a newer format,
  /// which must not be overwritten.
  static SyncSnapshot? tryParse(String text) {
    Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (json is! Map || json['format'] is! num) return null;
    final version = (json['format'] as num).toInt();
    if (version > format) throw SyncFormatException(version);
    final deleted = <String, int>{};
    final marks = json['deleted'];
    if (marks is Map) {
      marks.forEach((k, v) {
        if (k is String && v is num) deleted[k] = v.toInt();
      });
    }
    final history = json['history'];
    return SyncSnapshot(
      historyClearedAt: (json['historyClearedAt'] as num?)?.toInt() ?? 0,
      deleted: deleted,
      entries: [
        if (history is List)
          for (final e in history.map(SyncEntry.tryFromJson)) ?e,
      ]..sort(_newestFirst),
      settings: SyncSettings.tryFromJson(json['settings']),
    );
  }
}

/// What one sync does on this device and on Drive.
class SyncPlan {
  const SyncPlan({
    required this.merged,
    required this.insertLocally,
    required this.deleteLocalIds,
    required this.applySettings,
    required this.uploadNeeded,
  });

  final SyncSnapshot merged;
  final List<SyncEntry> insertLocally;
  final List<int> deleteLocalIds;
  final SyncSettings? applySettings;
  final bool uploadNeeded;
}

/// Merges this device's state with the sync file ([remote], null when there is none yet).
/// [knownKeys] are the entries present after the last sync: those missing locally now were
/// deleted here, and become deletion marks.
SyncPlan planSync({
  required List<HistoryEntry> localHistory,
  required SyncSettings localSettings,
  required int localClearedAt,
  required Set<String> knownKeys,
  required SyncSnapshot? remote,
  required int now,
}) {
  final localEntries = localHistory.map(SyncEntry.fromHistory).toList();
  final localKeys = {for (final e in localEntries) e.key};
  final local = SyncSnapshot(
    historyClearedAt: localClearedAt,
    deleted: {for (final key in knownKeys.difference(localKeys)) key: now},
    entries: localEntries,
    settings: localSettings,
  );
  final merged = SyncSnapshot.combine(
    local,
    remote ?? const SyncSnapshot(),
    pruneDeletedBefore: now - const Duration(days: 180).inMilliseconds,
  );
  final mergedKeys = {for (final e in merged.entries) e.key};
  final mergedSettings = merged.settings;
  return SyncPlan(
    merged: merged,
    insertLocally: [
      for (final e in merged.entries)
        if (!localKeys.contains(e.key)) e,
    ],
    deleteLocalIds: [
      for (final h in localHistory)
        if (h.id != null && !mergedKeys.contains(historyKey(h))) h.id!,
    ],
    applySettings:
        mergedSettings != null && mergedSettings.updatedAt > localSettings.updatedAt ? mergedSettings : null,
    uploadNeeded: remote == null || merged.encode() != remote.encode(),
  );
}

enum SyncState { idle, syncing, ok, offline, needsSignIn, noDriveAccess, driveFull, newerFormat, failed }

/// Runs the sync: after signing in, when the history or a synced setting changes (debounced),
/// when the app comes back to the foreground after a while, and on request.
class SyncService extends ChangeNotifier {
  SyncService({
    required this.account,
    required this.drive,
    required this.settings,
    required this.history,
    this.onServerChanged,
    DateTime Function()? clock,
    this.historyDelay = const Duration(seconds: 8),
    this.settingsDelay = const Duration(seconds: 3),
    this.staleAfter = const Duration(minutes: 10),
  }) : _clock = clock ?? DateTime.now;

  final GoogleAccount account;
  final DriveClient drive;
  final SettingsStore settings;
  final HistoryRepository history;

  /// The backend address came from another device: reload what depends on it.
  final Future<void> Function()? onServerChanged;

  /// Longer than the "Hoàn tác" snack bar, so an undone deletion is never synced.
  final Duration historyDelay;
  final Duration settingsDelay;
  final Duration staleAfter;
  final DateTime Function() _clock;

  SyncState _state = SyncState.idle;
  SyncState get state => _state;

  /// The last sync brought entries or settings from Drive.
  bool get lastRestored => _lastRestored;
  bool _lastRestored = false;

  bool _started = false;
  bool _running = false;
  bool _again = false;
  bool _applying = false;
  Timer? _timer;

  DateTime? get lastSyncedAt =>
      settings.syncLastAt == 0 ? null : DateTime.fromMillisecondsSinceEpoch(settings.syncLastAt);

  void start() {
    if (_started) return;
    _started = true;
    history.addListener(_onHistoryChanged);
    settings.addListener(_onSettingsChanged);
    account.addListener(notifyListeners);
    if (account.signedIn) unawaited(sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_started) {
      history.removeListener(_onHistoryChanged);
      settings.removeListener(_onSettingsChanged);
      account.removeListener(notifyListeners);
    }
    super.dispose();
  }

  void _setState(SyncState s) {
    _state = s;
    notifyListeners();
  }

  void _onHistoryChanged() {
    if (_applying || !account.signedIn) return;
    final keys = {for (final e in history.entries) historyKey(e)};
    if (setEquals(keys, settings.syncKnownKeys)) return; // reloaded, nothing new
    _schedule(historyDelay);
  }

  void _onSettingsChanged() {
    if (_applying || !account.signedIn) return;
    if (settings.settingsUpdatedAt <= settings.syncSettingsAt) return;
    _schedule(settingsDelay);
  }

  void _schedule(Duration delay) {
    if (_timer?.isActive ?? false) return; // the pending sync will include this change too
    _timer = Timer(delay, () => unawaited(sync()));
  }

  /// The app came back to the foreground: pick up what other devices changed meanwhile.
  void onResume() {
    if (!account.signedIn) return;
    final last = settings.syncLastAt;
    if (_clock().millisecondsSinceEpoch - last >= staleAfter.inMilliseconds) unawaited(sync());
  }

  /// Interactive sign-in followed by a first sync. False when the user cancelled.
  /// Throws [GoogleAuthException] when Google refused.
  Future<bool> signIn() async {
    if (!await account.signIn()) return false;
    await sync();
    return true;
  }

  /// Signs out on this device. With [deleteRemote], also deletes the sync file; returns false
  /// when that failed (offline): the device is signed out anyway.
  Future<bool> signOut({bool deleteRemote = false}) async {
    _timer?.cancel();
    var deleted = true;
    if (deleteRemote && account.signedIn) {
      try {
        final files = await _withToken(drive.list);
        for (final f in files) {
          await _withToken((t) => drive.delete(t, f.id));
        }
      } catch (e) {
        debugPrint('Deleting the Drive copy failed: $e');
        deleted = false;
      }
    }
    await account.signOut();
    _setState(SyncState.idle);
    return deleted;
  }

  /// "Xóa dữ liệu" on every device: entries recorded until now go away everywhere.
  Future<void> clearEverywhere() async {
    await settings.setHistoryClearedAt(_clock().millisecondsSinceEpoch);
    await sync();
  }

  Future<void> sync() async {
    if (!account.signedIn) return;
    if (_running) {
      _again = true;
      return;
    }
    _timer?.cancel();
    _running = true;
    _setState(SyncState.syncing);
    try {
      await _syncOnce();
      _setState(SyncState.ok);
    } on GoogleAuthException catch (e) {
      _setState(e.isNetwork ? SyncState.offline : SyncState.needsSignIn);
    } on DriveException catch (e) {
      _setState(e.isNetwork
          ? SyncState.offline
          : e.unauthorized
              ? SyncState.needsSignIn
              : e.noDriveAccess
                  ? SyncState.noDriveAccess
                  : e.storageFull
                      ? SyncState.driveFull
                      : SyncState.failed);
    } on SyncFormatException {
      _setState(SyncState.newerFormat);
    } catch (e) {
      debugPrint('Sync failed: $e');
      _setState(SyncState.failed);
    } finally {
      _running = false;
      if (_again && account.signedIn) {
        _again = false;
        unawaited(sync());
      }
    }
  }

  Future<void> _syncOnce() async {
    _lastRestored = false;
    final files = await _withToken(drive.list);
    SyncSnapshot? remote;
    for (final f in files) {
      final snapshot = SyncSnapshot.tryParse(await _withToken((t) => drive.read(t, f.id)));
      if (snapshot == null) continue; // unreadable: replaced below
      remote = remote == null ? snapshot : SyncSnapshot.combine(remote, snapshot);
    }
    // The background capture engine may have added entries since the list was loaded.
    await _whileApplying(history.load);
    final now = _clock().millisecondsSinceEpoch;
    final plan = planSync(
      localHistory: history.entries,
      localSettings: SyncSettings(
        updatedAt: settings.settingsUpdatedAt,
        country: settings.countryChoice,
        preferredPlatforms: settings.preferredPlatforms,
        serverUrl: settings.serverOverride,
      ),
      localClearedAt: settings.historyClearedAt,
      knownKeys: settings.syncKnownKeys,
      remote: remote,
      now: now,
    );
    _lastRestored = await _apply(plan);
    if (plan.uploadNeeded || files.length > 1 || (remote == null && files.isNotEmpty)) {
      final body = plan.merged.encode();
      if (files.isEmpty) {
        await _withToken((t) => drive.create(t, body));
      } else {
        await _withToken((t) => drive.update(t, files.first.id, body));
        for (final extra in files.skip(1)) {
          await _withToken((t) => drive.delete(t, extra.id)); // merged into the first one
        }
      }
    }
    await settings.saveSyncState(
      knownKeys: {for (final e in plan.merged.entries) e.key},
      lastAt: now,
      settingsAt: max(settings.settingsUpdatedAt, plan.merged.settings?.updatedAt ?? 0),
      historyClearedAt: plan.merged.historyClearedAt,
    );
  }

  Future<void> _whileApplying(Future<void> Function() body) async {
    _applying = true;
    try {
      await body();
    } finally {
      _applying = false;
    }
  }

  Future<bool> _apply(SyncPlan plan) async {
    if (plan.deleteLocalIds.isEmpty && plan.insertLocally.isEmpty && plan.applySettings == null) return false;
    var serverChanged = false;
    await _whileApplying(() async {
      for (final id in plan.deleteLocalIds) {
        await history.db.delete(id);
      }
      for (final e in plan.insertLocally) {
        await history.db.insert(e.toHistoryEntry());
      }
      await history.load();
      final s = plan.applySettings;
      if (s != null) {
        serverChanged = await settings.applySyncedSettings(
          country: s.country,
          preferredPlatforms: s.preferredPlatforms,
          serverUrl: s.serverUrl,
          updatedAt: s.updatedAt,
        );
      }
    });
    if (serverChanged) await onServerChanged?.call();
    return plan.insertLocally.isNotEmpty || plan.applySettings != null;
  }

  /// Runs a Drive call with a token, once more with a fresh token if Drive rejects it.
  Future<T> _withToken<T>(Future<T> Function(String token) call) async {
    final token = await account.accessToken();
    try {
      return await call(token);
    } on DriveException catch (e) {
      if (!e.unauthorized) rethrow;
      return call(await account.accessToken(rejected: token));
    }
  }
}
