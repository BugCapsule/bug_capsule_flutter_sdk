import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'backend_client.dart';

String patchSha256(List<int> bytes) =>
    'sha256:${SHA256Digest().process(Uint8List.fromList(bytes)).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
String patchRequestKey() =>
    'patch-${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

class PatchApiException implements Exception {
  PatchApiException(this.status, this.problem, {this.idempotencyKey});
  final int status;
  final Map<String, Object?> problem;
  final String? idempotencyKey;
  @override
  String toString() =>
      'HTTP $status: ${problem['detail'] ?? problem['title'] ?? problem['code']}';
}

class PatchResponse {
  const PatchResponse(this.status, this.data, {this.replayed = false});
  final int status;
  final Map<String, Object?> data;
  final bool replayed;
}

/// Patch management uses the product's existing person/service token, never a
/// second login store or an application's delivery/ingest credential.
class PatchClient {
  PatchClient(
    this.credentials, {
    this.sessionToken,
    this.projectId,
    this.timeout = const Duration(seconds: 30),
    this.retries = 2,
    this.retryDelay = const Duration(milliseconds: 300),
  });
  final Credentials credentials;

  /// Explicit process-local human session; never persisted by the CLI.
  final String? sessionToken;
  final String? projectId;
  final Duration timeout;
  final int retries;
  final Duration retryDelay;

  Future<PatchResponse> request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    List<int>? bytes,
    String? idempotencyKey,
  }) async {
    final token = sessionToken ?? credentials.token;
    if (sessionToken != null) {
      if (!sessionToken!.startsWith('bcw_') ||
          projectId == null ||
          !RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
          ).hasMatch(projectId!)) {
        throw StateError(
          'An ephemeral person session requires BUGCAPSULE_PATCH_SESSION_TOKEN and an explicit project UUID (--project or BUGCAPSULE_PATCH_PROJECT_ID).',
        );
      }
    } else if (token == null || !Credentials.isToken(token)) {
      throw StateError(
        'Patch access requires the existing personal/service token or an explicit ephemeral person session. Legacy project keys and delivery credentials are not management credentials.',
      );
    }
    final base = Uri.parse(credentials.url.replaceAll(RegExp(r'/+$'), ''));
    if (!['http', 'https'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw StateError(
        'The backend URL must be an HTTP(S) origin/path without credentials, query or fragment.',
      );
    }
    if (!path.startsWith('/v1/') ||
        Uri.parse(
          path,
        ).pathSegments.any((segment) => segment == '.' || segment == '..') ||
        path.contains('?') ||
        path.contains('#')) {
      throw ArgumentError('Invalid API path');
    }
    final uri = Uri.parse(
      '${base.toString()}$path',
    ).replace(queryParameters: query);
    if (method != 'GET' &&
        (idempotencyKey == null ||
            !RegExp(r'^[A-Za-z0-9_.:-]{8,200}$').hasMatch(idempotencyKey))) {
      throw ArgumentError(
        'Mutations require an 8–200 character Idempotency-Key.',
      );
    }
    for (var attempt = 0; ; attempt++) {
      final http = HttpClient()..connectionTimeout = timeout;
      Duration delay = retryDelay * (1 << attempt);
      try {
        final result = await (() async {
          final req = await http.openUrl(method, uri);
          req.followRedirects = false;
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          req.headers.set(HttpHeaders.acceptHeader, 'application/json');
          if (sessionToken != null) {
            req.headers.set('X-BugCapsule-Project', projectId!);
          }
          if (idempotencyKey != null) {
            req.headers.set('Idempotency-Key', idempotencyKey);
          }
          if (bytes != null) {
            req.headers.set(
              HttpHeaders.contentTypeHeader,
              'application/vnd.bugcapsule.bcpatch',
            );
            req.contentLength = bytes.length;
            req.add(bytes);
          } else if (body != null) {
            req.headers.contentType = ContentType.json;
            req.write(jsonEncode(body));
          }
          final response = await req.close();
          final chunks = <int>[];
          await for (final chunk in response) {
            chunks.addAll(chunk);
            if (chunks.length > 16 * 1024 * 1024) {
              throw const FormatException('Backend response exceeds 16 MiB');
            }
          }
          final seconds = int.tryParse(
            response.headers.value('retry-after') ?? '',
          );
          if (seconds != null) delay = Duration(seconds: seconds.clamp(0, 30));
          Map<String, Object?> data;
          try {
            data = chunks.isEmpty
                ? {}
                : (jsonDecode(utf8.decode(chunks)) as Map)
                      .cast<String, Object?>();
          } on Object {
            data = {
              'code': 'invalid_response',
              'detail': 'Backend returned a non-object JSON response',
            };
            if (response.statusCode >= 200 && response.statusCode < 300) {
              throw const FormatException('Backend returned invalid JSON');
            }
          }
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw PatchApiException(
              response.statusCode,
              data,
              idempotencyKey: idempotencyKey,
            );
          }
          return PatchResponse(
            response.statusCode,
            data,
            replayed: response.headers.value('idempotent-replayed') == 'true',
          );
        })().timeout(timeout);
        return result;
      } on PatchApiException catch (e) {
        if (attempt >= retries || ![429, 502, 503, 504].contains(e.status)) {
          rethrow;
        }
      } on SocketException {
        if (attempt >= retries) rethrow;
      } on TimeoutException {
        if (attempt >= retries) rethrow;
      } on HttpException {
        if (attempt >= retries) rethrow;
      } finally {
        http.close(force: true);
      }
      await Future<void>.delayed(delay);
    }
  }
}
