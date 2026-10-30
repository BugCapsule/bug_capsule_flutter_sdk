import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'updater.dart';

/// Refusal from the delivery endpoint, or a response outside its bounds.
final class PatchHttpException implements Exception {
  PatchHttpException(this.reason, [this.status]);
  const PatchHttpException.timedOut() : reason = 'timed_out', status = null;
  final String reason;
  final int? status;

  @override
  String toString() => 'PatchHttpException($reason${status == null ? '' : ', HTTP $status'})';
}

/// Engine receipt events the delivery API records, by engine name. An event
/// absent here stays local: one unknown name would refuse the whole batch.
const _receiptEvents = {
  'staged': 'staged',
  'activated': 'activated',
  'healthy': 'healthy',
  'fault': 'fault',
  'quarantined': 'quarantined',
  'rolled_back': 'rolled_back',
  'rollback_requested': 'rollback_requested',
  'invalidated': 'invalidated',
};

/// [PatchTransport] over the BugCapsule delivery API (`/v1/apps/:id/patches`).
///
/// Sizes are bounded while reading, so an oversized response never reaches
/// the runtime as bytes. Redirects are refused: the bearer token must not
/// follow one. TLS is required except for loopback development servers.
final class HttpPatchTransport implements PatchTransport {
  HttpPatchTransport({
    required this.baseUrl,
    required this.deliveryToken,
    required this.applicationId,
    required this.platform,
    required this.distributionProfile,
    required this.baseBuildId,
    required this.installationId,
    this.timeout = const Duration(seconds: 30),
    this.artifactTimeout = const Duration(minutes: 2),
  }) {
    final u = Uri.parse(baseUrl);
    if (u.scheme != 'https' && !_isLoopback(u.host)) {
      throw ArgumentError('patch delivery needs https');
    }
  }

  static const maxArtifactBytes = 10 << 20;

  /// Two 16 KiB documents with signatures, in base64, inside JSON.
  static const maxChannelBytes = 64 << 10;
  static const maxReceipts = 100;
  static final _digest = RegExp(r'^sha256:[0-9a-f]{64}$');

  final String baseUrl;

  /// `bcpd_…`: identifies one application in one environment.
  final String deliveryToken;
  final String applicationId;
  final String platform;
  final String distributionProfile;
  final String baseBuildId;
  final String installationId;

  /// Absolute limit of a channel or receipt request, reading included.
  final Duration timeout;

  /// Absolute limit of an artifact download, reading included.
  final Duration artifactTimeout;

  static bool _isLoopback(String host) => host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '10.0.2.2';

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(path: '$prefix/v1/apps/${Uri.encodeComponent(applicationId)}/patches$path', queryParameters: query);
  }

  /// Runs one operation on its own client under an absolute deadline covering
  /// the connection, the headers and the body. Closing the client by force is
  /// the only thing that ends a response in progress: `abort` has no effect
  /// after the response arrives, and cancelling its stream keeps the socket.
  Future<T> _bounded<T>(String method, Uri uri, Duration limit, Future<T> Function(HttpClientRequest req, Stopwatch elapsed, Duration limit) run) async {
    final elapsed = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = limit;
    try {
      final req = await client.openUrl(method, uri).timeout(limit);
      req
        ..followRedirects = false
        ..headers.set(HttpHeaders.authorizationHeader, 'Bearer $deliveryToken');
      return await run(req, elapsed, limit);
    } on TimeoutException {
      throw const PatchHttpException.timedOut();
    } finally {
      client.close(force: true);
    }
  }

  Duration _left(Stopwatch elapsed, Duration limit) {
    final left = limit - elapsed.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  Future<HttpClientResponse> _send(HttpClientRequest req, Stopwatch elapsed, Duration limit) => req.close().timeout(_left(elapsed, limit));

  /// Reads at most [max] bytes before the deadline.
  Future<Uint8List> _read(HttpClientResponse res, int max, Stopwatch elapsed, Duration limit) {
    if (res.contentLength > max) throw PatchHttpException('response_too_large', res.statusCode);
    final out = BytesBuilder(copy: false);
    final done = Completer<Uint8List>();
    late final StreamSubscription<List<int>> sub;
    void fail(Object e) {
      if (done.isCompleted) return;
      unawaited(sub.cancel());
      done.completeError(e);
    }

    final timer = Timer(_left(elapsed, limit), () => fail(const PatchHttpException.timedOut()));
    sub = res.listen(
      (chunk) {
        if (out.length + chunk.length > max) {
          fail(PatchHttpException('response_too_large', res.statusCode));
        } else {
          out.add(chunk);
        }
      },
      onError: fail,
      onDone: () {
        if (!done.isCompleted) done.complete(out.takeBytes());
      },
      cancelOnError: true,
    );
    return done.future.whenComplete(timer.cancel);
  }

  Never _refused(int status) => throw PatchHttpException(switch (status) {
    301 || 302 || 303 || 307 || 308 => 'redirect_refused',
    401 || 403 => 'unauthorized',
    404 => 'not_found',
    410 => 'gone',
    429 => 'rate_limited',
    _ => 'http_error',
  }, status);

  @override
  Future<SignedChannel?> fetchChannel({String? etag}) {
    final uri = _uri('/channel', {'platform': platform, 'distributionProfile': distributionProfile, 'baseBuildId': baseBuildId});
    return _bounded('GET', uri, timeout, (req, elapsed, limit) async {
      if (etag != null) req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      final res = await _send(req, elapsed, limit);
      if (res.statusCode == 204 || res.statusCode == 304) return null;
      if (res.statusCode != 200) _refused(res.statusCode);
      final j = jsonDecode(utf8.decode(await _read(res, maxChannelBytes, elapsed, limit))) as Map<String, Object?>;
      final channel = j['channel']! as Map<String, Object?>;
      final keyring = j['keyring'] as Map<String, Object?>?;
      return SignedChannel(
        base64Decode(channel['document']! as String),
        base64Decode(channel['signature']! as String),
        etag: res.headers.value(HttpHeaders.etagHeader),
        keyringDocument: keyring == null ? null : base64Decode(keyring['document']! as String),
        keyringSignature: keyring == null ? null : base64Decode(keyring['signature']! as String),
      );
    });
  }

  @override
  Future<Uint8List> fetchArtifact(String digest) async {
    if (!_digest.hasMatch(digest)) throw PatchHttpException('bad_digest');
    return _bounded('GET', _uri('/artifacts/$digest'), artifactTimeout, (req, elapsed, limit) async {
      final res = await _send(req, elapsed, limit);
      if (res.statusCode != 200) _refused(res.statusCode);
      return await _read(res, maxArtifactBytes, elapsed, limit);
    });
  }

  @override
  Future<void> postReceipts(Map<String, Object?> batch) {
    final status = batch['status']! as Map<String, Object?>;
    final pending = status['pending'];
    final body = utf8.encode(jsonEncode({
      'platform': platform,
      'baseBuildId': baseBuildId,
      'installationId': installationId,
      'activeDigest': status['activeDigest'],
      'stagedDigest': pending is String && pending != 'base' ? pending : null,
      'channelRevision': status['channelRevision'],
      'receipts': [
        for (final r in (batch['receipts']! as List<Object?>).cast<Map<String, Object?>>().take(maxReceipts))
          if (_receiptEvents.containsKey(r['event'])) {'seq': r['seq'], 'event': _receiptEvents[r['event']], 'digest': r['digest'], 'reason': r['reason'], 'at': r['at']},
      ],
    }));
    return _bounded('POST', _uri('/receipts'), timeout, (req, elapsed, limit) async {
      req.headers.contentType = ContentType.json;
      req.contentLength = body.length;
      req.add(body);
      final res = await _send(req, elapsed, limit);
      if (res.statusCode != 202) _refused(res.statusCode);
    });
  }

}
