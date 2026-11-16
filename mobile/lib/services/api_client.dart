import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../l10n/strings.dart';
import '../models/recognition.dart';
import '../models/track.dart';
import '../models/track_link.dart';
import 'integrity.dart';
import 'server_address.dart';
import 'sse.dart';

class ApiException implements Exception {
  const ApiException(this.code, this.message, {this.statusCode});

  /// Backend error code (`quota_exceeded`, `invalid_sample`...) or `network`.
  final String code;

  /// Vietnamese message that can be shown as-is.
  final String message;
  final int? statusCode;

  bool get isNetwork => code == 'network';

  @override
  String toString() => 'ApiException($code, $statusCode): $message';
}

/// Links found by one adapter, pushed by the backend as soon as the adapter is done.
class LinksEvent {
  const LinksEvent(this.adapter, this.links, {this.cached = false, this.degraded = false});

  final String adapter;
  final List<TrackLink> links;
  final bool cached;
  final bool degraded;
}

/// [source] with a [TimeoutException] (then the end of the stream) when no chunk arrives for
/// [limit]; the source subscription is cancelled at that point, which releases the connection.
///
/// Not [Stream.timeout]: under `fake_async` (widget tests) its pause/resume handling left the
/// wrapped stream open after the body had ended, so the result screen kept loading.
Stream<T> stallGuard<T>(Stream<T> source, Duration limit) {
  late final StreamController<T> out;
  StreamSubscription<T>? sub;
  Timer? timer;
  void arm() {
    timer?.cancel();
    timer = Timer(limit, () {
      final s = sub;
      sub = null;
      out.addError(TimeoutException('no data for $limit', limit));
      unawaited(out.close());
      unawaited(s?.cancel());
    });
  }

  out = StreamController<T>(
    onListen: () {
      arm();
      sub = source.listen(
        (chunk) {
          arm();
          out.add(chunk);
        },
        onError: (Object e, StackTrace st) {
          arm();
          out.addError(e, st);
        },
        onDone: () {
          timer?.cancel();
          sub = null;
          unawaited(out.close());
        },
      );
    },
    // Paused by a slow reader: the server is not silent, the clock stops.
    onPause: () {
      timer?.cancel();
      sub?.pause();
    },
    onResume: () {
      sub?.resume();
      if (sub != null) arm();
    },
    onCancel: () {
      timer?.cancel();
      final s = sub;
      sub = null;
      return s?.cancel();
    },
  );
  return out.stream;
}

/// The app talks only to its own backend (design doc, section 4).
class ApiClient {
  ApiClient({
    required this.baseUrl,
    this.baseUrlOverride,
    required this.deviceId,
    required this.integrity,
    http.Client? client,
    this.appVersion = kAppVersion,
    this.timeout = const Duration(seconds: 25),
    this.streamStallTimeout = const Duration(seconds: 20),
  }) : _http = client ?? http.Client();

  /// Address the app was built with; may be empty.
  final String baseUrl;

  /// Address chosen at run time ("Cài đặt → Máy chủ"); wins over [baseUrl] when not null.
  final String? Function()? baseUrlOverride;
  final String Function() deviceId;
  final IntegrityService integrity;
  final String appVersion;
  final Duration timeout;

  /// Longest silence accepted on the link stream. The backend bounds every adapter to a few
  /// seconds, so a longer gap means the connection is dead, not that links are still coming.
  final Duration streamStallTimeout;
  final http.Client _http;

  String get currentBaseUrl => baseUrlOverride?.call() ?? baseUrl;

  /// Throws [ApiException] `server_address` when no usable backend address is configured
  /// (none at all, or plain HTTP to a public host in a release build).
  Uri _uri(String path, [Map<String, String>? query]) {
    final base = currentBaseUrl;
    if (!ServerAddress.isAllowed(base)) throw const ApiException('server_address', S.serverNotAllowed);
    return Uri.parse('$base$path').replace(queryParameters: query?.isEmpty ?? true ? null : query);
  }

  Future<Map<String, String>> _headers([List<String>? integrityParts]) async {
    final id = deviceId();
    final token = integrityParts == null ? null : await integrity.token(id, integrityParts);
    return {
      'X-Device-Id': id,
      'X-App-Version': appVersion,
      'Accept': 'application/json',
      'X-Integrity-Token': ?token,
    };
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body().timeout(timeout);
    } on ApiException {
      rethrow;
    } on SocketException {
      throw const ApiException('network', S.networkError);
    } on http.ClientException {
      throw const ApiException('network', S.networkError);
    } on TimeoutException {
      throw const ApiException('network', S.networkError);
    } on IOException {
      // TLS handshake, connection closed half-way...
      throw const ApiException('network', S.networkError);
    } on FormatException {
      throw const ApiException('bad_response', S.genericError);
    } on TypeError {
      // A 2xx answer that is JSON but not the object the app expects.
      throw const ApiException('bad_response', S.genericError);
    }
  }

  /// Decoded JSON body of a 2xx answer; every other answer becomes an [ApiException].
  ///
  /// Callers only ever see [ApiException]: an HTML error page from a proxy in front of the
  /// backend (502/503/504) must not surface as a [FormatException] nobody handles.
  dynamic _decode(http.Response resp) {
    final ok = resp.statusCode >= 200 && resp.statusCode < 300;
    dynamic body;
    try {
      body = resp.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(resp.bodyBytes));
    } on FormatException {
      if (ok) throw ApiException('bad_response', S.genericError, statusCode: resp.statusCode);
    }
    if (ok) return body;
    final code = body is Map ? body['error'] : null;
    final message = body is Map ? body['message'] : null;
    throw ApiException(
      code is String ? code : 'http_${resp.statusCode}',
      message is String ? message : (resp.statusCode >= 500 ? S.serverBusy : S.genericError),
      statusCode: resp.statusCode,
    );
  }

  /// `POST /v1/recognitions`. [stage] is `early` (6 s probe) or `full`.
  Future<RecognitionResult> recognize({
    required Uint8List audio,
    required String mode,
    required String source,
    required String stage,
    String? sessionId,
    String? filenameHint,
  }) =>
      _guard(() async {
        final request = http.MultipartRequest('POST', _uri('/v1/recognitions'))
          ..headers.addAll(await _headers([sessionId ?? '', stage, sha256Hex(audio)]))
          ..fields['mode'] = mode
          ..fields['source'] = source
          ..fields['stage'] = stage
          ..files.add(http.MultipartFile.fromBytes('audio', audio, filename: 'sample.aac'));
        if (sessionId != null) request.fields['session_id'] = sessionId;
        if (filenameHint != null) {
          request.fields['filename_hint'] = filenameHint.length > 200 ? filenameHint.substring(0, 200) : filenameHint;
        }
        final resp = await http.Response.fromStream(await _http.send(request));
        return RecognitionResult.fromJson(_decode(resp) as Map<String, dynamic>);
      });

  /// `GET /v1/tracks/{id}/links` as Server-Sent Events: one event per platform adapter.
  Stream<LinksEvent> streamLinks(String trackId, {required String country, String? variant}) async* {
    final request = http.Request(
      'GET',
      _uri('/v1/tracks/$trackId/links', {'country': country, 'variant': ?variant}),
    )..headers.addAll({...await _headers(), 'Accept': 'text/event-stream'});
    late http.StreamedResponse resp;
    try {
      resp = await _http.send(request).timeout(timeout);
    } on Exception {
      throw const ApiException('network', S.networkError);
    }
    if (resp.statusCode != 200) {
      try {
        _decode(await http.Response.fromStream(resp).timeout(timeout));
      } on ApiException {
        rethrow;
      } on Exception {
        throw const ApiException('network', S.networkError);
      }
      throw ApiException('http_${resp.statusCode}', S.genericError, statusCode: resp.statusCode);
    }
    var finished = false;
    try {
      // Malformed UTF-8 is replaced, not thrown: one bad byte must not end the stream.
      final lines = const Utf8Decoder(allowMalformed: true).bind(stallGuard(resp.stream, streamStallTimeout));
      await for (final e in lines.transform(const SseParser())) {
        if (e.event == 'done') finished = true;
        if (e.event != 'links') continue;
        final LinksEvent event;
        try {
          final data = jsonDecode(e.data) as Map<String, dynamic>;
          event = LinksEvent(
            data['adapter'] as String,
            ((data['links'] as List?) ?? const [])
                .map((l) => TrackLink.fromJson(l as Map<String, dynamic>))
                .toList(),
            cached: (data['cached'] as bool?) ?? false,
            degraded: (data['degraded'] as bool?) ?? false,
          );
        } on FormatException {
          continue; // one unreadable event: keep the links of the other platforms
        } on TypeError {
          continue;
        }
        yield event;
      }
    } on TimeoutException {
      throw const ApiException('network', S.networkError);
    } on IOException {
      throw const ApiException('network', S.networkError);
    } on http.ClientException {
      throw const ApiException('network', S.networkError);
    }
    // The backend always ends with a "done" event: without it the list is incomplete.
    if (!finished) throw const ApiException('network', S.networkError);
  }

  /// Same links in one JSON response (fallback when streaming is not possible).
  Future<List<TrackLink>> fetchLinks(String trackId, {required String country, String? variant}) => _guard(() async {
        final resp = await _http.get(
          _uri('/v1/tracks/$trackId/links',
              {'country': country, 'stream': 'false', 'variant': ?variant}),
          headers: await _headers(),
        );
        final body = _decode(resp) as Map<String, dynamic>;
        return ((body['links'] as List?) ?? const [])
            .map((l) => TrackLink.fromJson(l as Map<String, dynamic>))
            .toList();
      });

  Future<List<Track>> search(String query, {required String country}) => _guard(() async {
        final resp = await _http.get(
          _uri('/v1/search', {'q': query, 'country': country}),
          headers: await _headers(['search', query]),
        );
        final body = _decode(resp) as Map<String, dynamic>;
        return ((body['results'] as List?) ?? const []).map((t) => Track.fromJson(t as Map<String, dynamic>)).toList();
      });

  /// Returns whether the backend hid the link.
  Future<bool> reportLink(String linkId, String reason, {String? note}) => _guard(() async {
        final resp = await _http.post(
          _uri('/v1/links/$linkId/report'),
          headers: {...await _headers(['report', linkId, reason]), 'Content-Type': 'application/json'},
          body: jsonEncode({'reason': reason, 'note': ?note}),
        );
        return ((_decode(resp) as Map<String, dynamic>)['hidden'] as bool?) ?? false;
      });

  Future<void> reportRecognition(String recognitionId, {String reason = 'wrong_song'}) => _guard(() async {
        final resp = await _http.post(
          _uri('/v1/recognitions/$recognitionId/report'),
          headers: {...await _headers(), 'Content-Type': 'application/json'},
          body: jsonEncode({'reason': reason}),
        );
        _decode(resp);
      });

  /// Raw `/v1/config` JSON (cached on the device and parsed with [AppConfig.fromJson]).
  Future<Map<String, dynamic>> fetchConfigJson() => _guard(() async {
        final resp = await _http.get(_uri('/v1/config'), headers: await _headers());
        return _decode(resp) as Map<String, dynamic>;
      });
}
