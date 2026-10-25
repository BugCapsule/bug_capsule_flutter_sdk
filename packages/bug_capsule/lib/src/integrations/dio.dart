/// Dio integration for BugCapsule.
///
/// Works at the transport level: [attach] wraps the Dio's
/// [HttpClientAdapter], so every interceptor and transformer of the app still
/// runs during replay — only the bytes on the wire come from the capsule.
///
/// ```dart
/// final bugCapsuleDio = BugCapsuleDio(rules: [
///   EndpointRule('POST', '/payments', ignoreBodyFields: {'timestamp', 'nonce'}),
/// ]);
/// final dio = Dio(...);
/// bugCapsuleDio.attach(dio); // after setting any custom adapter
/// ```
///
/// Capture never buffers a whole request or response: bytes stream through
/// to the app as they arrive (same chunks, same backpressure, cancellation
/// and errors), and only a bounded prefix is kept for the recording:
/// * request bodies: up to [maxKeyBodyBytes] for the request key, and up to
///   the session's `maxBodyBytes` for the recording when body capture is on;
/// * response bodies: nothing when body capture is off (the exchange is
///   recorded when headers arrive, as `omitted`), otherwise up to
///   `maxBodyBytes` (text/JSON) or [maxBinaryBytes] (binary). A larger body,
///   or one still streaming after [maxBodyWait], is recorded as `truncated`
///   and keeps streaming untouched.
/// Omitted and truncated bodies make the capsule `partial`, and replay
/// reports `network.noBody` when it serves one.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import '../runtime/monitoring/hub.dart';
import '../runtime/runtime.dart';

class BugCapsuleDio extends BugCapsuleIntegration {
  BugCapsuleDio({
    List<EndpointRule> rules = const [],
    Set<String> ignoreQuery = const {
      '_',
      'ts',
      'timestamp',
      'nonce',
      'cachebust',
    },
    Set<String> ignoreBodyFields = const {},
    this.maxBinaryBytes = 64 * 1024,
    this.maxKeyBodyBytes = 64 * 1024,
    this.maxBodyWait = const Duration(seconds: 30),
    this.exclude,
  }) : keys = RequestKeyBuilder(
         rules: rules,
         globalIgnoreQuery: ignoreQuery,
         globalIgnoreBodyFields: ignoreBodyFields,
       );

  final RequestKeyBuilder keys;
  final int maxBinaryBytes;

  /// Request bodies up to this size take part in the request key. Fixed
  /// (not tied to remote config) so capture and replay always agree; larger
  /// bodies are keyed without a body hash.
  final int maxKeyBodyBytes;

  /// A response body still streaming after this long is recorded as
  /// `truncated` so long-lived (non-SSE) streams appear in the capsule.
  final Duration maxBodyWait;

  /// Requests for which only method, redacted URL, status and timing are
  /// recorded: no headers, no bodies (e.g. login or payment endpoints).
  final bool Function(RequestOptions options)? exclude;

  BugCapsuleSession? _session;
  final List<Dio> _pending = [];
  int _nextId = 0;

  @override
  String get name => 'dio';

  @override
  Future<void> setUp(BugCapsuleSession session) async {
    _session = session;
    for (final dio in _pending) {
      _install(dio);
    }
    _pending.clear();
  }

  /// Installs capture (or replay) on [dio]. Safe to call before or after
  /// `BugCapsule.init`.
  void attach(Dio dio) {
    if (_session == null) {
      _pending.add(dio);
    } else {
      _install(dio);
    }
  }

  void _install(Dio dio) {
    final inner = dio.httpClientAdapter;
    if (inner is _BugCapsuleAdapter) return;
    dio.httpClientAdapter = _BugCapsuleAdapter(this, inner);
  }

  @override
  void describeEligibility(
    EligibilityBuilder eligibility,
    RecordedWindow window,
  ) => HttpBodies.describeEligibility(eligibility, window);

  // ------------------------------------------------------------------ bodies

  (Object?, String) _decode(List<int> bytes, String? contentType) =>
      HttpBodies.decode(
        bytes,
        contentType,
        _session!.redactor,
        maxBinaryBytes: maxBinaryBytes,
      );

  /// The request key. Capture and replay both call this before the request
  /// is sent, with the same prefetched body prefix (a body is hashed when it
  /// is complete within [maxKeyBodyBytes]), whatever the capture settings.
  String _keyFor(RequestOptions options, PrefetchedBody<Uint8List>? body) {
    final uri = _session!.redactor.redactUri(options.uri);
    Object? keyBody;
    final contentType = _contentType(options);
    if (body != null &&
        body.complete &&
        body.length <= maxKeyBodyBytes &&
        !HttpBodies.isMultipart(contentType)) {
      keyBody = _decode(body.bytes, contentType).$1;
    }
    return keys.keyFor(options.method, uri, keyBody);
  }

  static String? _contentType(RequestOptions options) =>
      options.contentType ?? options.headers['content-type'] as String?;
}

class _BugCapsuleAdapter implements HttpClientAdapter {
  _BugCapsuleAdapter(this._bugCapsule, this._inner);

  final BugCapsuleDio _bugCapsule;
  final HttpClientAdapter _inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final session = _bugCapsule._session;
    if (session == null) {
      return _inner.fetch(options, requestStream, cancelFuture);
    }
    final replay = session.replay;
    if (replay != null) {
      return _replay(session, replay, options, requestStream, cancelFuture);
    }
    // Monitoring: an http.client span, and trace headers for propagation
    // targets. They are added for the transport only: the capsule records
    // the app's headers, and request keys never include headers.
    final span = MonitoringHub.current?.startHttpSpan(
      options.method,
      options.uri,
      options.headers,
    );
    final appHeaders = span == null || span.headers.isEmpty
        ? null
        : Map<String, dynamic>.of(options.headers);
    if (appHeaders != null) options.headers.addAll(span!.headers);
    try {
      if (!session.isRecording) {
        try {
          final response = await _inner.fetch(
            options,
            requestStream,
            cancelFuture,
          );
          span?.finish(statusCode: response.statusCode, breadcrumb: true);
          return response;
        } catch (e) {
          span?.finish(
            error: e,
            cancelled: e is DioException && e.type == DioExceptionType.cancel,
            breadcrumb: true,
          );
          rethrow;
        }
      }
      return await _capture(
        session,
        options,
        requestStream,
        cancelFuture,
        span,
        appHeaders,
      );
    } finally {
      if (appHeaders != null) {
        options.headers
          ..clear()
          ..addAll(appHeaders);
      }
    }
  }

  Future<ResponseBody> _capture(
    BugCapsuleSession session,
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
    HttpSpan? span,
    Map<String, dynamic>? appHeaders,
  ) async {
    final started = Stopwatch()..start();
    final excluded = _bugCapsule.exclude?.call(options) ?? false;
    final captureBodies = session.captureNetworkBodies && !excluded;
    final requestType = BugCapsuleDio._contentType(options);
    final requestLimit = captureBodies && !HttpBodies.isMultipart(requestType)
        ? (session.maxBodyBytes > _bugCapsule.maxKeyBodyBytes
              ? session.maxBodyBytes
              : _bugCapsule.maxKeyBodyBytes)
        : _bugCapsule.maxKeyBodyBytes;
    final prefetched = requestStream == null
        ? null
        : await PrefetchedBody.read(requestStream, _bugCapsule.maxKeyBodyBytes);
    // Key and occurrence are fixed when the request starts, in request order,
    // exactly as replay looks them up.
    String? key;
    int? occurrence;
    try {
      key = _bugCapsule._keyFor(options, prefetched);
      occurrence = HttpBodies.nextOccurrence(session, key);
    } catch (_) {
      // Keying failed: the exchange is not recorded, the request still runs.
    }
    final request = prefetched == null
        ? null
        : BodyTap(prefetched.stream(), requestLimit);

    Map<String, Object?> base() {
      Object? requestBody;
      var requestEncoding = 'json';
      if (request != null && prefetched!.length > 0) {
        if (!captureBodies || HttpBodies.isMultipart(requestType)) {
          requestEncoding = 'omitted';
        } else if (request.complete &&
            !request.overflowed(session.maxBodyBytes)) {
          (requestBody, requestEncoding) = _bugCapsule._decode(
            request.bytes,
            requestType,
          );
        } else if (prefetched.complete &&
            prefetched.length <= session.maxBodyBytes) {
          // The transport never read the body (e.g. connection refused).
          (requestBody, requestEncoding) = _bugCapsule._decode(
            prefetched.bytes,
            requestType,
          );
        } else {
          requestEncoding = 'truncated';
        }
      }
      request?.release();
      return {
        'id': _bugCapsule._nextId++,
        'key': key!,
        'occurrence': occurrence!,
        'method': options.method.toUpperCase(),
        'url': session.redactor.redactUri(options.uri).toString(),
        if (!excluded)
          'requestHeaders': session.redactor.redactHeaders(
            appHeaders ?? options.headers,
          ),
        'requestBody': requestBody,
        'requestEncoding': requestEncoding,
        if (excluded) 'excluded': true,
      };
    }

    final ResponseBody response;
    try {
      response = await _inner.fetch(options, request?.stream, cancelFuture);
      span?.finish(statusCode: response.statusCode);
    } catch (e) {
      span?.finish(
        error: e,
        cancelled: e is DioException && e.type == DioExceptionType.cancel,
      );
      if (key != null) {
        _record(
          session,
          () => {
            ...base(),
            'status': 0,
            'durationMs': started.elapsedMilliseconds,
            'bodyEncoding': 'omitted',
            'error': _errorJson(session, e),
          },
        );
      }
      rethrow;
    }
    if (key == null) return response;

    Map<String, Object?> head() => {
      ...base(),
      'status': response.statusCode,
      'statusMessage': response.statusMessage,
      if (!excluded)
        'responseHeaders': session.redactor.redactHeaders(response.headers),
    };

    final contentType = response.headers['content-type']?.join(';');
    final sse = contentType?.toLowerCase().contains('event-stream') ?? false;
    if (sse || !captureBodies) {
      // Nothing to keep: record now and hand the stream over untouched.
      _record(
        session,
        () => {
          ...head(),
          'durationMs': started.elapsedMilliseconds,
          'bodyEncoding': 'omitted',
        },
      );
      return response;
    }

    final type = (contentType ?? '').toLowerCase();
    final limit = HttpBodies.isText(type)
        ? session.maxBodyBytes
        : _bugCapsule.maxBinaryBytes;
    var recorded = false;
    Timer? wait;
    late final BodyTap<Uint8List> tap;
    void finish(Map<String, Object?> extra) {
      if (recorded) return;
      recorded = true;
      wait?.cancel();
      _record(
        session,
        () => {...head(), 'durationMs': started.elapsedMilliseconds, ...extra},
      );
      tap.release();
    }

    tap = BodyTap(
      response.stream,
      limit,
      onDone: () {
        if (recorded) return;
        try {
          final (body, encoding) = _bugCapsule._decode(tap.bytes, contentType);
          finish({'responseBody': body, 'bodyEncoding': encoding});
        } catch (_) {
          finish({'bodyEncoding': 'truncated'});
        }
      },
      onError: (e) => finish({
        'bodyEncoding': 'truncated',
        'error': _errorJson(session, e),
      }),
      onCancel: () => finish({
        'bodyEncoding': 'truncated',
        'error': {
          'type': DioExceptionType.cancel.name,
          'message': 'response stream cancelled',
        },
      }),
      onOverflow: () => finish({'bodyEncoding': 'truncated'}),
    );
    wait = Timer(
      _bugCapsule.maxBodyWait,
      () => finish({'bodyEncoding': 'truncated'}),
    );
    response.stream = tap.stream;
    return response;
  }

  /// Recorded when the exchange completes (or when the recording stops
  /// following it), so the event's `t` is that time; the request was sent at
  /// `t - durationMs`.
  void _record(
    BugCapsuleSession session,
    Map<String, Object?> Function() data,
  ) {
    try {
      session.record(EventTypes.http, data());
    } catch (_) {
      // Recording must never break the app's request.
    }
  }

  Map<String, Object?> _errorJson(BugCapsuleSession session, Object e) => {
    'type': e is DioException ? e.type.name : 'connectionError',
    'message': session.redactor.scrubText(
      e is DioException ? (e.message ?? '${e.error}') : '$e',
    ),
  };

  Future<ResponseBody> _replay(
    BugCapsuleSession session,
    ReplayContext replay,
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = requestStream == null
        ? null
        : await PrefetchedBody.read(requestStream, _bugCapsule.maxKeyBodyBytes);
    final key = _bugCapsule._keyFor(options, request);
    final lookup = replay.fixtures.take(key);
    if (lookup == null) {
      replay.diverge('network.unrecorded', key);
      if (!replay.settings.strictNetwork) {
        final done = replay.beginWork();
        try {
          return await _inner.fetch(options, request?.stream(), cancelFuture);
        } finally {
          done();
        }
      }
      await request?.stream().drain<void>();
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'BugCapsule replay: no recorded response for $key',
      );
    }
    // Consume the upload as a server would (the app may await its progress).
    await request?.stream().drain<void>();
    if (lookup.reused) replay.diverge('network.reused', key);
    final fixture = lookup.fixture;
    replay.fixtureServed();

    // Keep the recorded latency so response ordering (and races) replay.
    // While it runs, idle compression leaves the replay clock alone.
    final done = replay.beginWork();
    try {
      final delay = Future<void>.delayed(
        Duration(milliseconds: fixture.durationMs),
      );
      if (cancelFuture != null) {
        await Future.any([delay, cancelFuture]);
      } else {
        await delay;
      }
    } finally {
      done();
    }

    final error = fixture.error;
    if (error != null && fixture.status == 0) {
      final type =
          DioExceptionType.values.asNameMap()[error['type']] ??
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
      for (final e in HttpBodies.replayHeaders(fixture.responseHeaders).entries)
        e.key: [e.value],
    };
    return ResponseBody.fromBytes(
      HttpBodies.encode(fixture.responseBody, fixture.bodyEncoding),
      fixture.status,
      statusMessage: fixture.data['statusMessage'] as String?,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}
