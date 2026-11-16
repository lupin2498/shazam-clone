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
  }) : _http = client ?? http.Client();

  /// Address the app was built with; may be empty.
  final String baseUrl;

  /// Address chosen at run time ("Cài đặt → Máy chủ"); wins over [baseUrl] when not null.
  final String? Function()? baseUrlOverride;
  final String Function() deviceId;
  final IntegrityService integrity;
  final String appVersion;
  final Duration timeout;
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
    } on HandshakeException {
      throw const ApiException('network', S.networkError);
    }
  }

  dynamic _decode(http.Response resp) {
    final body = resp.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(resp.bodyBytes));
    if (resp.statusCode >= 200 && resp.statusCode < 300) return body;
    if (body is Map<String, dynamic>) {
      throw ApiException((body['error'] as String?) ?? 'http_${resp.statusCode}',
          (body['message'] as String?) ?? S.genericError,
          statusCode: resp.statusCode);
    }
    throw ApiException('http_${resp.statusCode}', S.genericError, statusCode: resp.statusCode);
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
      _decode(await http.Response.fromStream(resp));
      return;
    }
    try {
      await for (final e in utf8.decoder.bind(resp.stream).transform(const SseParser())) {
        if (e.event != 'links') continue;
        final data = jsonDecode(e.data) as Map<String, dynamic>;
        yield LinksEvent(
          data['adapter'] as String,
          ((data['links'] as List?) ?? const []).map((l) => TrackLink.fromJson(l as Map<String, dynamic>)).toList(),
          cached: (data['cached'] as bool?) ?? false,
          degraded: (data['degraded'] as bool?) ?? false,
        );
      }
    } on SocketException {
      throw const ApiException('network', S.networkError);
    } on http.ClientException {
      throw const ApiException('network', S.networkError);
    }
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
