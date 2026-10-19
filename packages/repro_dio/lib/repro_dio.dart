/// Dio integration for Repro.
///
/// Works at the transport level: [attach] wraps the Dio's
/// [HttpClientAdapter], so every interceptor and transformer of the app still
/// runs during replay — only the bytes on the wire come from the capsule.
///
/// ```dart
/// final reproDio = ReproDio(rules: [
///   EndpointRule('POST', '/payments', ignoreBodyFields: {'timestamp', 'nonce'}),
/// ]);
/// final dio = Dio(...);
/// reproDio.attach(dio); // after setting any custom adapter
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:repro_flutter/repro_flutter.dart';

class ReproDio extends ReproIntegration {
  ReproDio({
    List<EndpointRule> rules = const [],
    Set<String> ignoreQuery = const {'_', 'ts', 'timestamp', 'nonce', 'cachebust'},
    Set<String> ignoreBodyFields = const {},
    this.maxBinaryBytes = 64 * 1024,
  }) : keys = RequestKeyBuilder(
          rules: rules,
          globalIgnoreQuery: ignoreQuery,
          globalIgnoreBodyFields: ignoreBodyFields,
        );

  final RequestKeyBuilder keys;
  final int maxBinaryBytes;

  ReproSession? _session;
  final List<Dio> _pending = [];
  final Map<String, int> _occurrences = {};
  int _nextId = 0;
  int _bodiesMissing = 0;

  @override
  String get name => 'dio';

  @override
  Future<void> setUp(ReproSession session) async {
    _session = session;
    for (final dio in _pending) {
      _install(dio);
    }
    _pending.clear();
  }

  /// Installs capture (or replay) on [dio]. Safe to call before or after
  /// `Repro.init`.
  void attach(Dio dio) {
    if (_session == null) {
      _pending.add(dio);
    } else {
      _install(dio);
    }
  }

  void _install(Dio dio) {
    final inner = dio.httpClientAdapter;
    if (inner is _ReproAdapter) return;
    dio.httpClientAdapter = _ReproAdapter(this, inner);
  }

  @override
  void describeEligibility(EligibilityBuilder eligibility, RecordedWindow window) {
    final missing = window.events.where((e) =>
        e.type == EventTypes.http &&
        e.data['error'] == null &&
        (e.data['bodyEncoding'] == 'omitted' || e.data['bodyEncoding'] == 'truncated'));
    if (missing.isNotEmpty) {
      eligibility.missing('network.bodies',
          '${missing.length} recorded responses have no body (capture disabled or too large)');
    }
    if (_bodiesMissing > 0 && missing.isEmpty) _bodiesMissing = 0;
  }

  // ------------------------------------------------------------------ keys

  /// Parses a body for keying and storage: JSON when it is JSON, text when
  /// it is text, base64 when small binary, otherwise omitted.
  (Object?, String) _decodeBody(List<int>? bytes, String? contentType, {required bool capture}) {
    if (bytes == null || bytes.isEmpty) return (null, 'json');
    final session = _session!;
    if (capture && !session.captureNetworkBodies) return (null, 'omitted');
    if (bytes.length > session.maxBodyBytes) return (null, 'truncated');
    final type = (contentType ?? '').toLowerCase();
    final isText = type.contains('json') ||
        type.startsWith('text/') ||
        type.contains('xml') ||
        type.contains('x-www-form-urlencoded') ||
        type.isEmpty;
    if (isText) {
      final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        return _binary(bytes);
      }
      if (type.contains('json') || type.isEmpty) {
        try {
          return (session.redactor.redactJson(jsonDecode(text)), 'json');
        } on FormatException {
          return (text, 'text');
        }
      }
      if (type.contains('x-www-form-urlencoded')) {
        final fields = Uri.splitQueryString(text);
        return (session.redactor.redactJson(fields), 'form');
      }
      return (text, 'text');
    }
    return _binary(bytes);
  }

  (Object?, String) _binary(List<int> bytes) =>
      bytes.length > maxBinaryBytes ? (null, 'truncated') : (base64Encode(bytes), 'base64');

  List<int> _encodeBody(Object? body, String encoding) => switch (encoding) {
        'json' => body == null ? const [] : utf8.encode(jsonEncode(body)),
        'text' => utf8.encode(body as String? ?? ''),
        'form' => utf8.encode(Uri(queryParameters: (body as Map).cast<String, String>()).query),
        'base64' => base64Decode(body as String),
        _ => const [],
      };

  String _keyFor(RequestOptions options, Object? redactedBody) {
    final uri = _session!.redactor.redactUri(options.uri);
    return keys.keyFor(options.method, uri, redactedBody);
  }
}

class _ReproAdapter implements HttpClientAdapter {
  _ReproAdapter(this._repro, this._inner);

  final ReproDio _repro;
  final HttpClientAdapter _inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final session = _repro._session;
    if (session == null) return _inner.fetch(options, requestStream, cancelFuture);
    final replay = session.replay;
    if (replay != null) return _replay(session, replay, options, requestStream, cancelFuture);
    if (!session.isRecording) return _inner.fetch(options, requestStream, cancelFuture);
    return _capture(session, options, requestStream, cancelFuture);
  }

  Future<Uint8List?> _readAll(Stream<Uint8List>? stream) async {
    if (stream == null) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<ResponseBody> _capture(
    ReproSession session,
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final t = session.now();
    final started = Stopwatch()..start();
    final requestBytes = await _readAll(requestStream);
    final (requestBody, requestEncoding) = _repro._decodeBody(
        requestBytes, options.contentType ?? options.headers['content-type'] as String?,
        capture: true);
    final key = _repro._keyFor(options, requestBody);
    final occurrence = _repro._occurrences.update(key, (n) => n + 1, ifAbsent: () => 0);
    final base = <String, Object?>{
      'id': _repro._nextId++,
      'key': key,
      'occurrence': occurrence,
      'method': options.method.toUpperCase(),
      'url': session.redactor.redactUri(options.uri).toString(),
      'requestHeaders': session.redactor.redactHeaders(options.headers),
      'requestBody': requestBody,
      'requestEncoding': requestEncoding,
    };

    final ResponseBody response;
    try {
      response = await _inner.fetch(
        options,
        requestBytes == null ? null : Stream.value(requestBytes),
        cancelFuture,
      );
    } catch (e) {
      _record(session, t, {
        ...base,
        'status': 0,
        'durationMs': started.elapsedMilliseconds,
        'bodyEncoding': 'omitted',
        'error': _errorJson(e),
      });
      rethrow;
    }

    final contentType = response.headers['content-type']?.join(';');
    final streaming = contentType?.contains('event-stream') ?? false;
    if (streaming) {
      _record(session, t, {
        ...base,
        'status': response.statusCode,
        'responseHeaders': session.redactor.redactHeaders(response.headers),
        'durationMs': started.elapsedMilliseconds,
        'bodyEncoding': 'omitted',
      });
      return response;
    }

    final Uint8List bytes;
    try {
      bytes = await _readAll(response.stream) ?? Uint8List(0);
    } catch (e) {
      _record(session, t, {
        ...base,
        'status': response.statusCode,
        'durationMs': started.elapsedMilliseconds,
        'bodyEncoding': 'omitted',
        'error': _errorJson(e),
      });
      rethrow;
    }
    final (body, encoding) = _repro._decodeBody(bytes, contentType, capture: true);
    _record(session, t, {
      ...base,
      'status': response.statusCode,
      'statusMessage': response.statusMessage,
      'responseHeaders': session.redactor.redactHeaders(response.headers),
      'responseBody': body,
      'bodyEncoding': encoding,
      'durationMs': started.elapsedMilliseconds,
    });
    return ResponseBody.fromBytes(
      bytes,
      response.statusCode,
      statusMessage: response.statusMessage,
      isRedirect: response.isRedirect,
      headers: response.headers,
    )..redirects = response.redirects;
  }

  /// Recorded when the exchange completes, so the event's `t` is the
  /// response time; the request was sent at `t - durationMs`.
  void _record(ReproSession session, int t, Map<String, Object?> data) =>
      session.record(EventTypes.http, data);

  Map<String, Object?> _errorJson(Object e) => {
        'type': e is DioException ? e.type.name : 'connectionError',
        'message': e is DioException ? (e.message ?? '${e.error}') : '$e',
      };

  Future<ResponseBody> _replay(
    ReproSession session,
    ReplayContext replay,
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final requestBytes = await _readAll(requestStream);
    final (requestBody, _) = _repro._decodeBody(
        requestBytes, options.contentType ?? options.headers['content-type'] as String?,
        capture: false);
    final key = _repro._keyFor(options, requestBody);
    final lookup = replay.fixtures.take(key);
    if (lookup == null) {
      replay.diverge('network.unrecorded', key);
      if (!replay.settings.strictNetwork) {
        final done = replay.beginWork();
        try {
          return await _inner.fetch(
              options, requestBytes == null ? null : Stream.value(requestBytes), cancelFuture);
        } finally {
          done();
        }
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Repro replay: no recorded response for $key',
      );
    }
    if (lookup.reused) replay.diverge('network.reused', key);
    final fixture = lookup.fixture;
    replay.fixtureServed();

    // Keep the recorded latency so response ordering (and races) replay.
    // While it runs, idle compression leaves the replay clock alone.
    final done = replay.beginWork();
    try {
      final delay = Future<void>.delayed(Duration(milliseconds: fixture.durationMs));
      if (cancelFuture != null) {
        await Future.any([delay, cancelFuture]);
      } else {
        await delay;
      }
    } finally {
      done();
    }

    final error = fixture.error;
    if (error != null) {
      final type = DioExceptionType.values.asNameMap()[error['type']] ??
          DioExceptionType.connectionError;
      throw DioException(
        requestOptions: options,
        type: type,
        message: error['message'] as String?,
      );
    }
    if (!fixture.hasBody && fixture.status != 204) {
      replay.diverge('network.noBody', key);
    }
    final headers = <String, List<String>>{
      for (final e in fixture.responseHeaders.entries)
        if (e.key != 'content-length' && e.key != 'content-encoding' &&
            e.key != 'transfer-encoding')
          e.key: [e.value],
    };
    return ResponseBody.fromBytes(
      _repro._encodeBody(fixture.responseBody, fixture.bodyEncoding),
      fixture.status,
      statusMessage: fixture.data['statusMessage'] as String?,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}
