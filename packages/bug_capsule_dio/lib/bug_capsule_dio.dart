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
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:bug_capsule_flutter/bug_capsule_flutter.dart';

class BugCapsuleDio extends BugCapsuleIntegration {
  BugCapsuleDio({
    List<EndpointRule> rules = const [],
    Set<String> ignoreQuery = const {'_', 'ts', 'timestamp', 'nonce', 'cachebust'},
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
  final Map<String, int> _occurrences = {};
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
  void describeEligibility(EligibilityBuilder eligibility, RecordedWindow window) {
    final missing = window.events.where((e) =>
        e.type == EventTypes.http &&
        e.data['error'] == null &&
        (e.data['bodyEncoding'] == 'omitted' || e.data['bodyEncoding'] == 'truncated'));
    if (missing.isNotEmpty) {
      eligibility.missing('network.bodies',
          '${missing.length} recorded responses have no body (capture disabled, excluded or too large)');
    }
  }

  // ------------------------------------------------------------------ bodies

  static bool _isMultipart(String? contentType) =>
      (contentType ?? '').toLowerCase().startsWith('multipart/');

  static bool _isText(String type) =>
      type.contains('json') ||
      type.startsWith('text/') ||
      type.contains('xml') ||
      type.contains('x-www-form-urlencoded') ||
      type.isEmpty;

  /// Decodes a complete body for keying and storage: redacted JSON, form
  /// fields, scrubbed text, or small binary as base64.
  (Object?, String) _decode(List<int> bytes, String? contentType) {
    if (bytes.isEmpty) return (null, 'json');
    final redactor = _session!.redactor;
    final type = (contentType ?? '').toLowerCase();
    if (_isText(type)) {
      final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        return _binary(bytes);
      }
      if (type.contains('json') || type.isEmpty) {
        try {
          return (redactor.redactJson(jsonDecode(text)), 'json');
        } on FormatException {
          return (redactor.scrubText(text), 'text');
        }
      }
      if (type.contains('x-www-form-urlencoded')) {
        try {
          return (redactor.redactJson(Uri.splitQueryString(text)), 'form');
        } on Object {
          return (redactor.scrubText(text), 'text'); // malformed escapes
        }
      }
      return (redactor.scrubText(text), 'text');
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

  /// The request key. Capture and replay both call this before the request
  /// is sent, with the same prefetched body prefix (a body is hashed when it
  /// is complete within [maxKeyBodyBytes]), whatever the capture settings.
  String _keyFor(RequestOptions options, _Prefetched? body) {
    final uri = _session!.redactor.redactUri(options.uri);
    Object? keyBody;
    final contentType = _contentType(options);
    if (body != null && body.complete && body.length <= maxKeyBodyBytes && !_isMultipart(contentType)) {
      keyBody = _decode(body.bytes, contentType).$1;
    }
    return keys.keyFor(options.method, uri, keyBody);
  }

  static String? _contentType(RequestOptions options) =>
      options.contentType ?? options.headers['content-type'] as String?;
}

/// Passes a byte stream through unchanged while keeping its first [limit]
/// bytes. Pause, resume and cancel reach the source; errors reach the
/// listener. [complete] turns true when the source is done.
class _Tap {
  _Tap(Stream<Uint8List> source, this.limit, {this.onDone, this.onError, this.onCancel, this.onOverflow}) {
    late final StreamSubscription<Uint8List> sub;
    _controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        sub = source.listen(
          (chunk) {
            _seen += chunk.length;
            if (_retained != null) {
              if (_retained!.length + chunk.length <= limit) {
                _retained!.add(chunk);
              } else {
                _retained = null;
                _guard(onOverflow);
              }
            }
            _controller.add(chunk);
          },
          onError: (Object e, StackTrace st) {
            _guard(() => onError?.call(e));
            _controller.addError(e, st);
          },
          onDone: () {
            complete = true;
            _guard(onDone);
            unawaited(_controller.close());
          },
        );
      },
      onPause: () => sub.pause(),
      onResume: () => sub.resume(),
      onCancel: () {
        if (!complete) _guard(onCancel);
        return sub.cancel();
      },
    );
  }

  /// Recording bugs must never stop the app's bytes from flowing.
  static void _guard(void Function()? callback) {
    try {
      callback?.call();
    } catch (_) {}
  }

  final int limit;
  final void Function()? onDone;
  final void Function(Object error)? onError;
  final void Function()? onCancel;
  final void Function()? onOverflow;
  late final StreamController<Uint8List> _controller;
  BytesBuilder? _retained = BytesBuilder(copy: true);
  int _seen = 0;
  bool complete = false;

  Stream<Uint8List> get stream => _controller.stream;

  /// Bytes that went through so far.
  int get length => _seen;

  /// The retained prefix; the whole body when it fit in [limit].
  Uint8List get bytes => _retained?.toBytes() ?? Uint8List(0);

  bool overflowed(int max) => _retained == null || _seen > max;

  /// Stops retaining (the recording no longer needs the bytes).
  void release() => _retained = null;
}

/// The first `limit + 1` bytes of a request body, read before the request is
/// sent so its key does not depend on whether (or how far) the transport
/// reads the body. [stream] replays them followed by the rest, with pause,
/// resume, cancel and errors forwarded.
class _Prefetched {
  _Prefetched._();

  static Future<_Prefetched> read(Stream<Uint8List> source, int limit) {
    final p = _Prefetched._();
    final ready = Completer<_Prefetched>();
    void settle() {
      if (!ready.isCompleted) ready.complete(p);
    }

    p._sub = source.listen(
      (chunk) {
        p._chunks.add(chunk);
        p.length += chunk.length;
        if (p.length > limit) {
          p._sub.pause();
          settle();
        }
      },
      onError: (Object e, StackTrace st) {
        p._error = (e, st);
        p._done = true;
        settle();
      },
      onDone: () {
        p._done = true;
        settle();
      },
      cancelOnError: true,
    );
    return ready.future;
  }

  late StreamSubscription<Uint8List> _sub;
  final List<Uint8List> _chunks = [];
  (Object, StackTrace)? _error;
  bool _done = false;
  int length = 0;

  /// The whole body arrived (no error) while prefetching.
  bool get complete => _done && _error == null;

  Uint8List get bytes {
    final b = BytesBuilder(copy: false);
    for (final c in _chunks) {
      b.add(c);
    }
    return b.takeBytes();
  }

  Stream<Uint8List> stream() {
    late final StreamController<Uint8List> out;
    out = StreamController<Uint8List>(
      onListen: () {
        for (final c in _chunks) {
          out.add(c);
        }
        if (_done) {
          final error = _error;
          if (error != null) out.addError(error.$1, error.$2);
          unawaited(out.close());
          return;
        }
        _sub
          ..onData(out.add)
          ..onError(out.addError)
          ..onDone(() => unawaited(out.close()))
          ..resume();
      },
      onPause: () => _sub.pause(),
      onResume: () => _sub.resume(),
      onCancel: () => _done ? null : _sub.cancel(),
    );
    return out.stream;
  }
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
    if (session == null) return _inner.fetch(options, requestStream, cancelFuture);
    final replay = session.replay;
    if (replay != null) return _replay(session, replay, options, requestStream, cancelFuture);
    if (!session.isRecording) return _inner.fetch(options, requestStream, cancelFuture);
    return _capture(session, options, requestStream, cancelFuture);
  }

  Future<ResponseBody> _capture(
    BugCapsuleSession session,
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final started = Stopwatch()..start();
    final excluded = _bugCapsule.exclude?.call(options) ?? false;
    final captureBodies = session.captureNetworkBodies && !excluded;
    final requestType = BugCapsuleDio._contentType(options);
    final requestLimit = captureBodies && !BugCapsuleDio._isMultipart(requestType)
        ? (session.maxBodyBytes > _bugCapsule.maxKeyBodyBytes ? session.maxBodyBytes : _bugCapsule.maxKeyBodyBytes)
        : _bugCapsule.maxKeyBodyBytes;
    final prefetched =
        requestStream == null ? null : await _Prefetched.read(requestStream, _bugCapsule.maxKeyBodyBytes);
    // Key and occurrence are fixed when the request starts, in request order,
    // exactly as replay looks them up.
    String? key;
    int? occurrence;
    try {
      key = _bugCapsule._keyFor(options, prefetched);
      occurrence = _bugCapsule._occurrences.update(key, (n) => n + 1, ifAbsent: () => 0);
    } catch (_) {
      // Keying failed: the exchange is not recorded, the request still runs.
    }
    final request = prefetched == null ? null : _Tap(prefetched.stream(), requestLimit);

    Map<String, Object?> base() {
      Object? requestBody;
      var requestEncoding = 'json';
      if (request != null && prefetched!.length > 0) {
        if (!captureBodies || BugCapsuleDio._isMultipart(requestType)) {
          requestEncoding = 'omitted';
        } else if (request.complete && !request.overflowed(session.maxBodyBytes)) {
          (requestBody, requestEncoding) = _bugCapsule._decode(request.bytes, requestType);
        } else if (prefetched.complete && prefetched.length <= session.maxBodyBytes) {
          // The transport never read the body (e.g. connection refused).
          (requestBody, requestEncoding) = _bugCapsule._decode(prefetched.bytes, requestType);
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
        if (!excluded) 'requestHeaders': session.redactor.redactHeaders(options.headers),
        'requestBody': requestBody,
        'requestEncoding': requestEncoding,
        if (excluded) 'excluded': true,
      };
    }

    final ResponseBody response;
    try {
      response = await _inner.fetch(options, request?.stream, cancelFuture);
    } catch (e) {
      if (key != null) {
        _record(session, () => {
              ...base(),
              'status': 0,
              'durationMs': started.elapsedMilliseconds,
              'bodyEncoding': 'omitted',
              'error': _errorJson(session, e),
            });
      }
      rethrow;
    }
    if (key == null) return response;

    Map<String, Object?> head() => {
          ...base(),
          'status': response.statusCode,
          'statusMessage': response.statusMessage,
          if (!excluded) 'responseHeaders': session.redactor.redactHeaders(response.headers),
        };

    final contentType = response.headers['content-type']?.join(';');
    final sse = contentType?.toLowerCase().contains('event-stream') ?? false;
    if (sse || !captureBodies) {
      // Nothing to keep: record now and hand the stream over untouched.
      _record(session, () => {...head(), 'durationMs': started.elapsedMilliseconds, 'bodyEncoding': 'omitted'});
      return response;
    }

    final type = (contentType ?? '').toLowerCase();
    final limit = BugCapsuleDio._isText(type) ? session.maxBodyBytes : _bugCapsule.maxBinaryBytes;
    var recorded = false;
    Timer? wait;
    late final _Tap tap;
    void finish(Map<String, Object?> extra) {
      if (recorded) return;
      recorded = true;
      wait?.cancel();
      _record(session, () => {...head(), 'durationMs': started.elapsedMilliseconds, ...extra});
      tap.release();
    }

    tap = _Tap(
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
      onError: (e) => finish({'bodyEncoding': 'truncated', 'error': _errorJson(session, e)}),
      onCancel: () => finish({
        'bodyEncoding': 'truncated',
        'error': {'type': DioExceptionType.cancel.name, 'message': 'response stream cancelled'},
      }),
      onOverflow: () => finish({'bodyEncoding': 'truncated'}),
    );
    wait = Timer(_bugCapsule.maxBodyWait, () => finish({'bodyEncoding': 'truncated'}));
    response.stream = tap.stream;
    return response;
  }

  /// Recorded when the exchange completes (or when the recording stops
  /// following it), so the event's `t` is that time; the request was sent at
  /// `t - durationMs`.
  void _record(BugCapsuleSession session, Map<String, Object?> Function() data) {
    try {
      session.record(EventTypes.http, data());
    } catch (_) {
      // Recording must never break the app's request.
    }
  }

  Map<String, Object?> _errorJson(BugCapsuleSession session, Object e) => {
        'type': e is DioException ? e.type.name : 'connectionError',
        'message': session.redactor.scrubText(e is DioException ? (e.message ?? '${e.error}') : '$e'),
      };

  Future<ResponseBody> _replay(
    BugCapsuleSession session,
    ReplayContext replay,
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request =
        requestStream == null ? null : await _Prefetched.read(requestStream, _bugCapsule.maxKeyBodyBytes);
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
    if (error != null && fixture.status == 0) {
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
      _bugCapsule._encodeBody(fixture.responseBody, fixture.bodyEncoding),
      fixture.status,
      statusMessage: fixture.data['statusMessage'] as String?,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}
