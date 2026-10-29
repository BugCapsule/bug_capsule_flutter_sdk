import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../config.dart' show BugCapsuleBackendConfig;

/// One `GET …/emergency/policies` (§3).
final class EmergencyFetchRequest {
  const EmergencyFetchRequest({
    required this.backend,
    required this.applicationId,
    required this.environment,
    required this.platform,
    required this.appVersion,
    required this.sdkVersion,
    required this.etag,
  });

  final BugCapsuleBackendConfig backend;
  final String applicationId;
  final String environment;
  final String platform;
  final String? appVersion;
  final String sdkVersion;

  /// Sent as `If-None-Match` when there is a cached envelope.
  final String? etag;
}

sealed class EmergencyFetchResult {
  const EmergencyFetchResult();
}

/// `200`: [body] is the decoded JSON, or null when it was not JSON.
final class EmergencyFetched extends EmergencyFetchResult {
  const EmergencyFetched(this.body, this.etag);
  final Object? body;
  final String? etag;
}

/// `304`: the cached envelope is current.
final class EmergencyNotModified extends EmergencyFetchResult {
  const EmergencyNotModified();
}

final class EmergencyFetchFailed extends EmergencyFetchResult {
  const EmergencyFetchFailed(
    this.code,
    this.message, {
    this.status,
    this.retryAfter,
  });

  /// `network_error`, `http_<status>`, `credential_rejected`,
  /// `not_configured`, `response_too_large`.
  final String code;
  final String message;
  final int? status;
  final Duration? retryAfter;

  /// 401 and 403 refuse the credential; 404 means the application id does
  /// not belong to it, which is handled the same way (§3).
  bool get credentialRejected =>
      status == 401 || status == 403 || status == 404;
}

/// The two backend calls of the emergency module.
abstract interface class EmergencyTransport {
  Future<EmergencyFetchResult> fetchPolicies(EmergencyFetchRequest request);

  /// `POST …/emergency/receipts` (§7.3). Throws when the backend does not
  /// answer with a 2xx.
  Future<void> sendReceipt(
    BugCapsuleBackendConfig backend,
    String applicationId,
    Map<String, Object?> receipt,
  );
}

/// dart:io implementation: 5 s to connect, 10 s for the whole request, at
/// most 1 MiB of response body.
final class HttpEmergencyTransport implements EmergencyTransport {
  const HttpEmergencyTransport();

  static const connectTimeout = Duration(seconds: 5);
  static const requestTimeout = Duration(seconds: 10);
  static const maxBodyBytes = 1024 * 1024;

  static Uri _uri(
    BugCapsuleBackendConfig backend,
    String path, [
    Map<String, String>? query,
  ]) {
    final base = Uri.parse(backend.url.replaceAll(RegExp(r'/+$'), ''));
    return base.replace(
      path: '${base.path}$path',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  static Duration? _retryAfter(HttpClientResponse res) {
    final raw = res.headers.value(HttpHeaders.retryAfterHeader);
    final seconds = raw == null ? null : int.tryParse(raw.trim());
    return seconds == null ? null : Duration(seconds: seconds.clamp(0, 86400));
  }

  @override
  Future<EmergencyFetchResult> fetchPolicies(EmergencyFetchRequest r) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      return await _fetch(client, r).timeout(requestTimeout);
    } on TimeoutException {
      return const EmergencyFetchFailed('network_error', 'request timed out');
    } catch (e) {
      return EmergencyFetchFailed('network_error', '$e');
    } finally {
      client.close(force: true);
    }
  }

  Future<EmergencyFetchResult> _fetch(
    HttpClient client,
    EmergencyFetchRequest r,
  ) async {
    final appId = Uri.encodeComponent(r.applicationId);
    final appVersion = r.appVersion;
    final uri = _uri(r.backend, '/v1/apps/$appId/emergency/policies', {
      'environment': r.environment,
      'platform': r.platform,
      if (appVersion != null &&
          appVersion.isNotEmpty &&
          appVersion.length <= 64)
        'app_version': appVersion,
      'sdk_version': r.sdkVersion,
    });
    final req = await client.getUrl(uri);
    req.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${r.backend.ingestKey}')
      ..set(HttpHeaders.acceptHeader, 'application/json');
    final etag = r.etag;
    if (etag != null) req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
    final res = await req.close();
    final status = res.statusCode;
    if (status == 304) {
      await res.drain<void>();
      return const EmergencyNotModified();
    }
    final body = await _readLimited(res);
    if (body == null) {
      return EmergencyFetchFailed(
        'response_too_large',
        'response body is larger than $maxBodyBytes bytes',
        status: status,
      );
    }
    if (status == 200) {
      Object? json;
      try {
        json = jsonDecode(utf8.decode(body));
      } on FormatException {
        json = null; // Verified as malformed.
      }
      return EmergencyFetched(json, res.headers.value(HttpHeaders.etagHeader));
    }
    String? reason;
    try {
      final problem = jsonDecode(utf8.decode(body));
      if (problem is Map && problem['reason'] is String) {
        reason = problem['reason'] as String;
      }
    } on FormatException {
      // No problem body.
    }
    final code = switch (status) {
      401 || 403 || 404 => 'credential_rejected',
      409 when reason == 'emergency_not_configured' => 'not_configured',
      _ => 'http_$status',
    };
    return EmergencyFetchFailed(
      code,
      'HTTP $status${reason == null ? '' : ' ($reason)'}',
      status: status,
      retryAfter: _retryAfter(res),
    );
  }

  /// The body, or null when it is larger than [maxBodyBytes].
  static Future<List<int>?> _readLimited(HttpClientResponse res) async {
    if (res.contentLength > maxBodyBytes) return null;
    final out = BytesBuilder(copy: false);
    await for (final chunk in res) {
      out.add(chunk);
      if (out.length > maxBodyBytes) return null;
    }
    return out.takeBytes();
  }

  @override
  Future<void> sendReceipt(
    BugCapsuleBackendConfig backend,
    String applicationId,
    Map<String, Object?> receipt,
  ) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      await () async {
        final appId = Uri.encodeComponent(applicationId);
        final req = await client.postUrl(
          _uri(backend, '/v1/apps/$appId/emergency/receipts'),
        );
        req.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer ${backend.ingestKey}')
          ..contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(receipt)));
        final res = await req.close();
        await res.drain<void>();
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('receipt answered HTTP ${res.statusCode}');
        }
      }().timeout(requestTimeout);
    } finally {
      client.close(force: true);
    }
  }
}
