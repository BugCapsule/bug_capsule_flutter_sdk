import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'config.dart';

/// Capture config the backend can change at runtime (kill switch, sampling).
class RemoteCaptureConfig {
  const RemoteCaptureConfig({
    required this.enabled,
    required this.sampleRate,
    required this.maxCapsuleBytes,
    required this.captureNetworkBodies,
    required this.redactKeys,
    required this.configTtlSeconds,
    required this.fetchedAtMs,
  });

  factory RemoteCaptureConfig.fromJson(Map<String, Object?> j, {int? fetchedAtMs}) =>
      RemoteCaptureConfig(
        enabled: j['enabled'] as bool? ?? true,
        sampleRate: (j['sampleRate'] as num?)?.toDouble() ?? 1,
        maxCapsuleBytes: j['maxCapsuleBytes'] as int? ?? 5 * 1024 * 1024,
        captureNetworkBodies: j['captureNetworkBodies'] as bool? ?? true,
        redactKeys: [for (final k in (j['redactKeys'] as List?) ?? const []) '$k'],
        configTtlSeconds: j['configTtlSeconds'] as int? ?? 300,
        fetchedAtMs: fetchedAtMs ?? j['fetchedAtMs'] as int? ?? 0,
      );

  final bool enabled;
  final double sampleRate;
  final int maxCapsuleBytes;
  final bool captureNetworkBodies;
  final List<String> redactKeys;
  final int configTtlSeconds;
  final int fetchedAtMs;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'sampleRate': sampleRate,
        'maxCapsuleBytes': maxCapsuleBytes,
        'captureNetworkBodies': captureNetworkBodies,
        'redactKeys': redactKeys,
        'configTtlSeconds': configTtlSeconds,
        'fetchedAtMs': fetchedAtMs,
      };
}

enum UploadStatus { uploaded, rejected, retryLater }

class UploadResult {
  const UploadResult(this.status, {this.serverId, this.message});
  final UploadStatus status;
  final String? serverId;
  final String? message;
}

class ReproBackendClient {
  ReproBackendClient(this.config);

  final ReproBackendConfig config;
  static const _timeout = Duration(seconds: 20);

  Uri _uri(String path) => Uri.parse('${config.url.replaceAll(RegExp(r'/+$'), '')}$path');

  Future<RemoteCaptureConfig?> fetchConfig() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(_uri('/v1/sdk/config'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.ingestKey}');
      final res = await req.close().timeout(_timeout);
      final body = await utf8.decodeStream(res).timeout(_timeout);
      if (res.statusCode != 200) {
        debugPrint('[repro] config fetch failed: HTTP ${res.statusCode}');
        return null;
      }
      return RemoteCaptureConfig.fromJson((jsonDecode(body) as Map).cast<String, Object?>(),
          fetchedAtMs: DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('[repro] config fetch failed: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<UploadResult> upload(List<int> bytes) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(_uri('/v1/capsules'));
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.ingestKey}')
        ..contentType = ContentType.binary
        ..contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(_timeout);
      final body = await utf8.decodeStream(res).timeout(_timeout);
      final json = _tryJson(body);
      if (res.statusCode == 200 || res.statusCode == 201) {
        return UploadResult(UploadStatus.uploaded, serverId: json?['id'] as String?);
      }
      final code = json?['code'] as String? ?? 'HTTP ${res.statusCode}';
      // 4xx other than 408/429 will never succeed: drop instead of retrying.
      final retry = res.statusCode >= 500 || res.statusCode == 408 || res.statusCode == 429;
      return UploadResult(retry ? UploadStatus.retryLater : UploadStatus.rejected, message: code);
    } catch (e) {
      return UploadResult(UploadStatus.retryLater, message: '$e');
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, Object?>? _tryJson(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map ? v.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }
}

/// On-device files: saved capsules, the upload outbox and cached config.
class CapsuleStore {
  CapsuleStore._(this.root);

  static Future<CapsuleStore> open() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/repro');
    await Directory('${root.path}/captures').create(recursive: true);
    await Directory('${root.path}/outbox').create(recursive: true);
    return CapsuleStore._(root);
  }

  final Directory root;
  static const maxSavedCaptures = 20;

  /// Written by `repro run` to start the next launch in replay mode.
  static Future<File> replayRequestFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/repro/replay_request.json');
  }

  Directory get _captures => Directory('${root.path}/captures');
  Directory get _outbox => Directory('${root.path}/outbox');
  File get _configFile => File('${root.path}/remote_config.json');

  Future<File> save(String capsuleId, List<int> bytes) async {
    final file = File('${_captures.path}/$capsuleId.repro');
    await file.writeAsBytes(bytes, flush: true);
    await _prune();
    return file;
  }

  Future<void> enqueue(String capsuleId, List<int> bytes) async {
    final tmp = File('${_outbox.path}/$capsuleId.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename('${_outbox.path}/$capsuleId.repro');
  }

  Future<List<File>> pendingUploads() async => [
        await for (final e in _outbox.list())
          if (e is File && e.path.endsWith('.repro')) e,
      ];

  Future<List<File>> savedCaptures() async {
    final files = [
      await for (final e in _captures.list())
        if (e is File && e.path.endsWith('.repro')) e,
    ];
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  Future<RemoteCaptureConfig?> readConfig() async {
    try {
      if (!await _configFile.exists()) return null;
      final json = jsonDecode(await _configFile.readAsString()) as Map;
      return RemoteCaptureConfig.fromJson(json.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  Future<void> writeConfig(RemoteCaptureConfig config) =>
      _configFile.writeAsString(jsonEncode(config.toJson()), flush: true);

  Future<void> _prune() async {
    final files = await savedCaptures();
    for (final f in files.skip(maxSavedCaptures)) {
      await f.delete();
    }
  }
}
