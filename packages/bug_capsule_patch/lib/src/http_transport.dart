import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'updater.dart';

/// Refusal from the delivery endpoint, or a response outside its bounds.
final class PatchHttpException implements Exception {
  PatchHttpException(this.reason, [this.status]);
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
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
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
  final Duration timeout;
  final HttpClient _client;

  static bool _isLoopback(String host) => host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '10.0.2.2';

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(path: '$prefix/v1/apps/${Uri.encodeComponent(applicationId)}/patches$path', queryParameters: query);
  }

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    final req = await _client.openUrl(method, uri).timeout(timeout);
    req
      ..followRedirects = false
      ..headers.set(HttpHeaders.authorizationHeader, 'Bearer $deliveryToken');
    return req;
  }

  /// Reads at most [max] bytes, refusing early on a declared larger length.
  Future<Uint8List> _read(HttpClientResponse res, int max) async {
    if (res.contentLength > max) {
      unawaited(res.listen(null).cancel());
      throw PatchHttpException('response_too_large', res.statusCode);
    }
    final out = BytesBuilder(copy: false);
    // Leaving the loop cancels the stream, which closes the connection.
    await for (final chunk in res.timeout(timeout)) {
      if (out.length + chunk.length > max) throw PatchHttpException('response_too_large', res.statusCode);
      out.add(chunk);
    }
    return out.takeBytes();
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
  Future<SignedChannel?> fetchChannel({String? etag}) async {
    final req = await _open('GET', _uri('/channel', {'platform': platform, 'distributionProfile': distributionProfile, 'baseBuildId': baseBuildId}));
    if (etag != null) req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
    final res = await req.close().timeout(timeout);
    if (res.statusCode == 204 || res.statusCode == 304) {
      await res.drain<void>();
      return null;
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      _refused(res.statusCode);
    }
    final body = await _read(res, maxChannelBytes);
    final j = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    final channel = j['channel']! as Map<String, Object?>;
    final keyring = j['keyring'] as Map<String, Object?>?;
    return SignedChannel(
      base64Decode(channel['document']! as String),
      base64Decode(channel['signature']! as String),
      etag: res.headers.value(HttpHeaders.etagHeader),
      keyringDocument: keyring == null ? null : base64Decode(keyring['document']! as String),
      keyringSignature: keyring == null ? null : base64Decode(keyring['signature']! as String),
    );
  }

  @override
  Future<Uint8List> fetchArtifact(String digest) async {
    if (!_digest.hasMatch(digest)) throw PatchHttpException('bad_digest');
    final req = await _open('GET', _uri('/artifacts/$digest'));
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) {
      await res.drain<void>();
      _refused(res.statusCode);
    }
    return _read(res, maxArtifactBytes);
  }

  @override
  Future<void> postReceipts(Map<String, Object?> batch) async {
    final status = batch['status']! as Map<String, Object?>;
    final pending = status['pending'];
    final req = await _open('POST', _uri('/receipts'));
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
    req.headers.contentType = ContentType.json;
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    if (res.statusCode != 202) _refused(res.statusCode);
  }

  void close() => _client.close(force: true);
}
