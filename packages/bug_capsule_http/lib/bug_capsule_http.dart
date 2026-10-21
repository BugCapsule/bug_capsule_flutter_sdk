/// `package:http` integration for BugCapsule.
///
/// Works at the transport level: [BugCapsuleHttp.client] wraps an
/// [http.Client], so everything built on top of it (Chopper, `graphql`,
/// generated API clients, your own wrappers) still runs during replay —
/// only the bytes on the wire come from the capsule.
///
/// ```dart
/// final bugCapsuleHttp = BugCapsuleHttp(rules: [
///   EndpointRule('POST', '/payments', ignoreBodyFields: {'timestamp', 'nonce'}),
/// ]);
/// final client = bugCapsuleHttp.client();             // or .client(myClient)
/// final chopper = ChopperClient(client: bugCapsuleHttp.client(), ...);
/// ```
///
/// The wrapped client can be created before or after `BugCapsule.init`;
/// requests sent before setup pass through untouched.
///
/// Capture follows the same rules as `bug_capsule_dio`: bodies stream through
/// to the app, only a bounded prefix is kept, and omitted or truncated bodies
/// make the capsule `partial`. Recorded exchanges use the capsule's `http`
/// event, so the request keys, endpoint rules and redaction are the same as
/// for Dio.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:bug_capsule_flutter/bug_capsule_flutter.dart';

class BugCapsuleHttp extends BugCapsuleIntegration {
  BugCapsuleHttp({
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
  /// `truncated` so long-lived streams appear in the capsule.
  final Duration maxBodyWait;

  /// Requests for which only method, redacted URL, status and timing are
  /// recorded: no headers, no bodies (e.g. login or payment endpoints).
  final bool Function(http.BaseRequest request)? exclude;

  BugCapsuleSession? _session;
  int _nextId = 0;

  @override
  String get name => 'http';

  @override
  Future<void> setUp(BugCapsuleSession session) async => _session = session;

  /// A client that records (or replays) every request it sends through
  /// [inner], a new [http.Client] by default. Closing it closes [inner].
  http.Client client([http.Client? inner]) => _BugCapsuleClient(this, inner ?? http.Client());

  @override
  void describeEligibility(EligibilityBuilder eligibility, RecordedWindow window) =>
      HttpBodies.describeEligibility(eligibility, window);

  (Object?, String) _decode(List<int> bytes, String? contentType) =>
      HttpBodies.decode(bytes, contentType, _session!.redactor, maxBinaryBytes: maxBinaryBytes);

  /// The request key. Capture and replay both call this before the request
  /// is sent, with the same prefetched body prefix, whatever the capture
  /// settings.
  String _keyFor(http.BaseRequest request, PrefetchedBody<List<int>>? body) {
    final uri = _session!.redactor.redactUri(request.url);
    Object? keyBody;
    final contentType = _contentType(request);
    if (body != null && body.complete && body.length <= maxKeyBodyBytes && !HttpBodies.isMultipart(contentType)) {
      keyBody = _decode(body.bytes, contentType).$1;
    }
    return keys.keyFor(request.method, uri, keyBody);
  }

  static String? _contentType(http.BaseRequest request) => request.headers['content-type'];
}

class _BugCapsuleClient extends http.BaseClient {
  _BugCapsuleClient(this._bugCapsule, this._inner);

  final BugCapsuleHttp _bugCapsule;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final session = _bugCapsule._session;
    if (session == null) return _inner.send(request);
    final replay = session.replay;
    if (replay != null) return _replay(session, replay, request);
    if (!session.isRecording) return _inner.send(request);
    return _capture(session, request);
  }

  Future<http.StreamedResponse> _capture(BugCapsuleSession session, http.BaseRequest original) async {
    final started = Stopwatch()..start();
    final excluded = _bugCapsule.exclude?.call(original) ?? false;
    final captureBodies = session.captureNetworkBodies && !excluded;
    final requestType = BugCapsuleHttp._contentType(original);
    final requestLimit = captureBodies && !HttpBodies.isMultipart(requestType)
        ? (session.maxBodyBytes > _bugCapsule.maxKeyBodyBytes ? session.maxBodyBytes : _bugCapsule.maxKeyBodyBytes)
        : _bugCapsule.maxKeyBodyBytes;
    final prefetched = await PrefetchedBody.read<List<int>>(original.finalize(), _bugCapsule.maxKeyBodyBytes);
    // Key and occurrence are fixed when the request starts, in request order,
    // exactly as replay looks them up.
    String? key;
    int? occurrence;
    try {
      key = _bugCapsule._keyFor(original, prefetched);
      occurrence = HttpBodies.nextOccurrence(session, key);
    } catch (_) {
      // Keying failed: the exchange is not recorded, the request still runs.
    }
    final request = BodyTap<List<int>>(prefetched.stream(), requestLimit);

    Map<String, Object?> base() {
      Object? requestBody;
      var requestEncoding = 'json';
      if (prefetched.length > 0) {
        if (!captureBodies || HttpBodies.isMultipart(requestType)) {
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
      request.release();
      return {
        'id': _bugCapsule._nextId++,
        'key': key!,
        'occurrence': occurrence!,
        'method': original.method.toUpperCase(),
        'url': session.redactor.redactUri(original.url).toString(),
        if (!excluded) 'requestHeaders': session.redactor.redactHeaders(original.headers),
        'requestBody': requestBody,
        'requestEncoding': requestEncoding,
        if (excluded) 'excluded': true,
      };
    }

    final http.StreamedResponse response;
    try {
      response = await _inner.send(_ForwardedRequest(original, request.stream));
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
          'statusMessage': response.reasonPhrase,
          if (!excluded) 'responseHeaders': session.redactor.redactHeaders(response.headers),
        };

    final contentType = response.headers['content-type'];
    final sse = contentType?.toLowerCase().contains('event-stream') ?? false;
    if (sse || !captureBodies) {
      // Nothing to keep: record now and hand the stream over untouched.
      _record(session, () => {...head(), 'durationMs': started.elapsedMilliseconds, 'bodyEncoding': 'omitted'});
      return response;
    }

    final type = (contentType ?? '').toLowerCase();
    final limit = HttpBodies.isText(type) ? session.maxBodyBytes : _bugCapsule.maxBinaryBytes;
    var recorded = false;
    Timer? wait;
    late final BodyTap<List<int>> tap;
    void finish(Map<String, Object?> extra) {
      if (recorded) return;
      recorded = true;
      wait?.cancel();
      _record(session, () => {...head(), 'durationMs': started.elapsedMilliseconds, ...extra});
      tap.release();
    }

    tap = BodyTap<List<int>>(
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
        'error': {'type': 'cancel', 'message': 'response stream cancelled'},
      }),
      onOverflow: () => finish({'bodyEncoding': 'truncated'}),
    );
    wait = Timer(_bugCapsule.maxBodyWait, () => finish({'bodyEncoding': 'truncated'}));
    return _withStream(response, tap.stream);
  }

  static http.StreamedResponse _withStream(http.StreamedResponse r, Stream<List<int>> stream) =>
      r is http.BaseResponseWithUrl
          ? _StreamedResponseWithUrl(stream, r.statusCode,
              url: (r as http.BaseResponseWithUrl).url,
              contentLength: r.contentLength,
              request: r.request,
              headers: r.headers,
              isRedirect: r.isRedirect,
              persistentConnection: r.persistentConnection,
              reasonPhrase: r.reasonPhrase)
          : http.StreamedResponse(stream, r.statusCode,
              contentLength: r.contentLength,
              request: r.request,
              headers: r.headers,
              isRedirect: r.isRedirect,
              persistentConnection: r.persistentConnection,
              reasonPhrase: r.reasonPhrase);

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
        'type': e is http.RequestAbortedException ? 'cancel' : 'connectionError',
        'message': session.redactor.scrubText(e is http.ClientException ? e.message : '$e'),
      };

  Future<http.StreamedResponse> _replay(
    BugCapsuleSession session,
    ReplayContext replay,
    http.BaseRequest original,
  ) async {
    final request = await PrefetchedBody.read<List<int>>(original.finalize(), _bugCapsule.maxKeyBodyBytes);
    final key = _bugCapsule._keyFor(original, request);
    final lookup = replay.fixtures.take(key);
    if (lookup == null) {
      replay.diverge('network.unrecorded', key);
      if (!replay.settings.strictNetwork) {
        final done = replay.beginWork();
        try {
          return await _inner.send(_ForwardedRequest(original, request.stream()));
        } finally {
          done();
        }
      }
      await request.stream().drain<void>();
      throw http.ClientException('BugCapsule replay: no recorded response for $key', original.url);
    }
    // Consume the upload as a server would.
    await request.stream().drain<void>();
    if (lookup.reused) replay.diverge('network.reused', key);
    final fixture = lookup.fixture;
    replay.fixtureServed();

    // Keep the recorded latency so response ordering (and races) replay.
    // While it runs, idle compression leaves the replay clock alone.
    final abortTrigger = original is http.Abortable ? original.abortTrigger : null;
    var aborted = false;
    final done = replay.beginWork();
    try {
      final delay = Future<void>.delayed(Duration(milliseconds: fixture.durationMs));
      if (abortTrigger != null) {
        await Future.any([delay, abortTrigger.then((_) => aborted = true)]);
      } else {
        await delay;
      }
    } finally {
      done();
    }
    if (aborted) throw http.RequestAbortedException(original.url);

    final error = fixture.error;
    if (error != null && fixture.status == 0) {
      if (error['type'] == 'cancel') throw http.RequestAbortedException(original.url);
      throw http.ClientException(error['message'] as String? ?? 'connection error', original.url);
    }
    if (!fixture.hasBody && fixture.status != 204) {
      replay.diverge('network.noBody', key);
    }
    final body = HttpBodies.encode(fixture.responseBody, fixture.bodyEncoding);
    return http.StreamedResponse(
      Stream.value(body),
      fixture.status,
      contentLength: body.length,
      request: original,
      headers: HttpBodies.replayHeaders(fixture.responseHeaders),
      reasonPhrase: fixture.data['statusMessage'] as String?,
    );
  }

  @override
  void close() => _inner.close();
}

class _StreamedResponseWithUrl extends http.StreamedResponse implements http.BaseResponseWithUrl {
  _StreamedResponseWithUrl(
    super.stream,
    super.statusCode, {
    required this.url,
    super.contentLength,
    super.request,
    super.headers,
    super.isRedirect,
    super.persistentConnection,
    super.reasonPhrase,
  });

  @override
  final Uri url;
}

/// [original] with its body replaced by [_body] (the stream that already
/// went through capture). [original] is finalized and cannot be sent itself.
class _ForwardedRequest extends http.BaseRequest with http.Abortable {
  _ForwardedRequest(http.BaseRequest original, this._body)
      : abortTrigger = original is http.Abortable ? original.abortTrigger : null,
        super(original.method, original.url) {
    headers.addAll(original.headers);
    followRedirects = original.followRedirects;
    maxRedirects = original.maxRedirects;
    persistentConnection = original.persistentConnection;
    contentLength = original.contentLength;
  }

  final Stream<List<int>> _body;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}
