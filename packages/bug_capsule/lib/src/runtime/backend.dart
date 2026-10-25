import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/core.dart' show EnvelopeResponse;
import 'config.dart';
import 'remote_config.dart';

enum UploadStatus { uploaded, rejected, retryLater }

class UploadResult {
  const UploadResult(
    this.status, {
    this.serverId,
    this.message,
    this.retryAfter,
    this.httpStatus,
  });
  final UploadStatus status;
  final String? serverId;
  final String? message;

  /// From a `Retry-After` header on 429/503.
  final Duration? retryAfter;

  /// The backend's HTTP status; null when it was not reached.
  final int? httpStatus;

  /// The backend refused the credential: the runtime re-fetches the config
  /// to learn why and stops when it is revoked.
  bool get unauthorized => httpStatus == 401 || httpStatus == 403;
}

/// How the SDK talks to the backend. [BugCapsuleBackendClient] is the real one;
/// tests substitute a fake.
abstract interface class BugCapsuleTransport {
  Future<ConfigFetchResult> fetchConfig();
  Future<UploadResult> upload(List<int> bytes);
  void close();
}

/// Sends monitoring envelopes (`POST /v1/envelope`). [BugCapsuleBackendClient]
/// implements it next to [BugCapsuleTransport]; tests substitute a fake.
abstract interface class EnvelopeTransport {
  /// [gzippedBody] is the envelope JSON, gzip-compressed.
  Future<UploadResult> sendEnvelope(List<int> gzippedBody);
}

class BugCapsuleBackendClient
    implements BugCapsuleTransport, EnvelopeTransport {
  BugCapsuleBackendClient(this.config);

  final BugCapsuleBackendConfig config;
  static const _timeout = Duration(seconds: 20);

  Uri _uri(String path) =>
      Uri.parse('${config.url.replaceAll(RegExp(r'/+$'), '')}$path');

  static Duration? _retryAfter(HttpClientResponse res) {
    final raw = res.headers.value(HttpHeaders.retryAfterHeader);
    final seconds = raw == null ? null : int.tryParse(raw.trim());
    return seconds == null ? null : Duration(seconds: seconds.clamp(0, 86400));
  }

  @override
  Future<ConfigFetchResult> fetchConfig() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(_uri('/v1/sdk/config')).timeout(_timeout);
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${config.ingestKey}',
      );
      final res = await req.close().timeout(_timeout);
      final body = await utf8.decodeStream(res).timeout(_timeout);
      if (res.statusCode != 200) {
        // A refused credential comes with a problem body: `reason` (e.g.
        // `token_revoked`) and an actionable `detail`.
        final problem = _tryJson(body);
        final reason = problem?['reason'];
        final detail = problem?['detail'];
        return ConfigFetchFailed(
          'HTTP ${res.statusCode}',
          status: res.statusCode,
          retryAfter: _retryAfter(res),
          reason: reason is String && reason.isNotEmpty
              ? _cut(reason, 100)
              : null,
          detail: detail is String && detail.isNotEmpty
              ? _cut(detail, 500)
              : null,
        );
      }
      final json = jsonDecode(body);
      if (json is! Map) {
        return const ConfigFetchFailed('config is not a JSON object');
      }
      return ConfigFetched(
        RemoteCaptureConfig.fromJson(
          json.cast<String, Object?>(),
          fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      return ConfigFetchFailed('$e');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<UploadResult> upload(List<int> bytes) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    // Room for a slow uplink: 20 s plus 1 s per 16 KB (5 MB ≈ 6 minutes).
    final timeout = _timeout + Duration(seconds: bytes.length ~/ (16 * 1024));
    try {
      final req = await client.postUrl(_uri('/v1/capsules')).timeout(_timeout);
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.ingestKey}')
        ..contentType = ContentType.binary
        ..contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(timeout);
      final body = await utf8.decodeStream(res).timeout(_timeout);
      final json = _tryJson(body);
      if (res.statusCode == 200 || res.statusCode == 201) {
        return UploadResult(
          UploadStatus.uploaded,
          serverId: json?['id'] as String?,
        );
      }
      final code = json?['code'] as String? ?? 'HTTP ${res.statusCode}';
      // 4xx other than 401/408/429 will never succeed: drop instead of
      // retrying. 401 (rotated key) keeps the queue: the config fetch stops
      // capture, and a kill switch purges it.
      final retry =
          res.statusCode >= 500 ||
          res.statusCode == 401 ||
          res.statusCode == 408 ||
          res.statusCode == 429;
      return UploadResult(
        retry ? UploadStatus.retryLater : UploadStatus.rejected,
        message: code,
        retryAfter: _retryAfter(res),
        httpStatus: res.statusCode,
      );
    } catch (e) {
      return UploadResult(UploadStatus.retryLater, message: '$e');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<UploadResult> sendEnvelope(List<int> gzippedBody) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(_uri('/v1/envelope')).timeout(_timeout);
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.ingestKey}')
        ..contentType = ContentType.json
        ..set(HttpHeaders.contentEncodingHeader, 'gzip')
        ..contentLength = gzippedBody.length;
      req.add(gzippedBody);
      final res = await req.close().timeout(_timeout);
      final body = await utf8.decodeStream(res).timeout(_timeout);
      final json = _tryJson(body);
      if (res.statusCode == 200) {
        // Rejected items are invalid and must not be retried.
        final rejected = json == null
            ? const <String>[]
            : EnvelopeResponse.fromJson(json).rejected;
        if (rejected.isNotEmpty) {
          debugPrint(
            '[bugcapsule] envelope items rejected: ${rejected.join('; ')}',
          );
        }
        return const UploadResult(UploadStatus.uploaded);
      }
      final code = json?['code'] as String? ?? 'HTTP ${res.statusCode}';
      final retry =
          res.statusCode >= 500 ||
          res.statusCode == 401 ||
          res.statusCode == 408 ||
          res.statusCode == 429;
      return UploadResult(
        retry ? UploadStatus.retryLater : UploadStatus.rejected,
        message: code,
        retryAfter: _retryAfter(res),
        httpStatus: res.statusCode,
      );
    } catch (e) {
      return UploadResult(UploadStatus.retryLater, message: '$e');
    } finally {
      client.close(force: true);
    }
  }

  @override
  void close() {}

  static String _cut(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);

  static Map<String, Object?>? _tryJson(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map ? v.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }
}

/// Serializes async critical sections (one isolate).
class _Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final result = _tail.then((_) => fn());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}

/// On-device files: saved capsules (the QA overlay's history) and the
/// cached remote config. Uploads go through [UploadOutbox].
class CapsuleStore {
  CapsuleStore._(this.root);

  /// Opens `<application support>/bugcapsule`, or [root] when given (tests).
  /// Leftover temporary files from an interrupted write are removed.
  static Future<CapsuleStore> open({Directory? root}) async {
    final dir =
        root ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/bugcapsule',
        );
    final store = CapsuleStore._(dir);
    await store._captures.create(recursive: true);
    await _removeTemporaryFiles(store._captures);
    return store;
  }

  final Directory root;
  static const maxSavedCaptures = 20;

  /// Written by `bugcapsule run` to start the next launch in replay mode.
  static Future<File> replayRequestFile({Directory? root}) async {
    final dir =
        root ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/bugcapsule',
        );
    return File('${dir.path}/replay_request.json');
  }

  Directory get _captures => Directory('${root.path}/captures');
  Directory get outboxDirectory => Directory('${root.path}/outbox');
  File get _configFile => File('${root.path}/remote_config.json');

  /// Saves atomically (temp file + rename) and keeps the newest
  /// [maxSavedCaptures].
  Future<File> save(String capsuleId, List<int> bytes) async {
    final file = File('${_captures.path}/$capsuleId.bugcapsule');
    await _writeAtomically(file, bytes);
    await _prune();
    return file;
  }

  Future<List<File>> savedCaptures() async {
    final files = [
      await for (final e in _captures.list())
        if (e is File && e.path.endsWith('.bugcapsule')) e,
    ];
    files.sort((a, b) => _modified(b).compareTo(_modified(a)));
    return files;
  }

  Future<void> _prune() async {
    final files = await savedCaptures();
    for (final f in files.skip(maxSavedCaptures)) {
      await _deleteQuietly(f);
    }
  }

  /// Removes saved captures (kill switch: nothing captured before the
  /// decision may leave the device later through `savedCaptures`).
  Future<void> clearSavedCaptures() async {
    for (final f in await savedCaptures()) {
      await _deleteQuietly(f);
    }
  }

  late final RemoteConfigCache configCache = _FileConfigCache(_configFile);
}

class _FileConfigCache implements RemoteConfigCache {
  _FileConfigCache(this.file);

  final File file;

  @override
  Future<RemoteCaptureConfig?> read(String scope) async {
    try {
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['scope'] != scope) return null;
      final config = json['config'];
      if (config is! Map) return null;
      return RemoteCaptureConfig.fromJson(config.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String scope, RemoteCaptureConfig config) =>
      _writeAtomically(
        file,
        utf8.encode(jsonEncode({'scope': scope, 'config': config.toJson()})),
      );
}

/// Bounds on the upload outbox. Defaults: 10 capsules, 10 MiB in total, and
/// 7 days of age; whichever is hit first evicts the oldest capsules.
class OutboxLimits {
  const OutboxLimits({
    this.maxCount = 10,
    this.maxBytes = 10 * 1024 * 1024,
    this.maxAge = const Duration(days: 7),
  });

  final int maxCount;
  final int maxBytes;
  final Duration maxAge;
}

class OutboxEntry {
  OutboxEntry(this.file, this.capsuleId, this.enqueuedAt, this.size);

  final File file;
  final String capsuleId;
  final DateTime enqueuedAt;
  final int size;
}

/// Capsules waiting for upload, as `<enqueuedAtMs>_<capsuleId>.bugcapsule` files.
///
/// * **Bounds**: [OutboxLimits]. A capsule larger than `maxBytes` is never
///   queued; otherwise the oldest capsules are evicted first (the newest
///   failure is the most useful one to the developer).
/// * **Writes** are atomic (temp file + rename); temp files left by a crash
///   are removed on [open]. Disk-full and other I/O errors drop the capsule
///   and never reach the app.
/// * **Upload**: oldest first, one at a time ([flush] calls are serialized).
///   A retryable failure stops the pass and backs off exponentially from
///   30 s to 1 h (or `Retry-After`); permanent rejections and unreadable or
///   corrupt files are deleted.
/// * **Concurrency**: enqueue, eviction and deletion share one lock; an
///   upload runs outside it, so enqueueing never waits for the network. A
///   file evicted while it uploads is simply gone afterwards.
/// * **Shutdown**: [close] stops after the current upload; files left behind
///   are retried next launch (the backend deduplicates by capsule id).
class UploadOutbox {
  UploadOutbox._(this.dir, this.limits, this._now, this.extension)
    : _name = RegExp(
        '^(?:(\\d+)_)?([A-Za-z0-9-]{1,100})${RegExp.escape(extension)}\$',
      );

  /// [extension] names the queued files: `.bugcapsule` for capsules,
  /// `.envelope` for monitoring envelopes (the same rules, a separate queue).
  /// Entries must be gzip data.
  static Future<UploadOutbox> open(
    Directory dir, {
    OutboxLimits limits = const OutboxLimits(),
    DateTime Function()? now,
    String extension = '.bugcapsule',
  }) async {
    final outbox = UploadOutbox._(dir, limits, now ?? DateTime.now, extension);
    await dir.create(recursive: true);
    await _removeTemporaryFiles(dir);
    await outbox._lock.run(outbox._enforceLimits);
    return outbox;
  }

  final Directory dir;
  final OutboxLimits limits;
  final DateTime Function() _now;
  final _Mutex _lock = _Mutex();
  final Random _random = Random();
  Future<void>? _flushing;
  bool _closed = false;
  int _failures = 0;
  DateTime? _retryAt;

  /// Retryable failures per capsule in this process: entries that keep
  /// failing (a large capsule on a slow uplink) go behind newer ones.
  final Map<String, int> _attempts = {};

  final String extension;
  final RegExp _name;

  /// Earliest time the next upload attempt may run after failures.
  DateTime? get retryAt => _retryAt;

  Future<List<OutboxEntry>> entries() => _lock.run(_entries);

  Future<List<OutboxEntry>> _entries() async {
    final out = <OutboxEntry>[];
    if (!await dir.exists()) return out;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final m = _name.firstMatch(e.uri.pathSegments.last);
      if (m == null) continue;
      try {
        final stat = await e.stat();
        final ms = int.tryParse(m[1] ?? '');
        // Files from SDK 0.1.0 have no timestamp: use their mtime.
        final at = ms == null
            ? stat.modified
            : DateTime.fromMillisecondsSinceEpoch(ms);
        out.add(OutboxEntry(e, m[2]!, at, stat.size));
      } on FileSystemException {
        continue;
      }
    }
    out.sort((a, b) => a.enqueuedAt.compareTo(b.enqueuedAt));
    return out;
  }

  /// Queues a capsule. Returns false when it was not queued (closed, larger
  /// than the outbox, or an I/O error such as a full disk).
  Future<bool> enqueue(String capsuleId, List<int> bytes) {
    if (_closed || bytes.length > limits.maxBytes) return Future.value(false);
    return _lock.run(() async {
      final file = File(
        '${dir.path}/${_now().millisecondsSinceEpoch}_$capsuleId$extension',
      );
      try {
        await _writeAtomically(file, bytes);
      } on FileSystemException catch (e) {
        debugPrint(
          '[bugcapsule] could not queue capsule $capsuleId: ${e.osError?.message ?? e.message}',
        );
        return false;
      }
      await _enforceLimits();
      return file.existsSync();
    });
  }

  Future<void> _enforceLimits() async {
    final all = await _entries();
    final cutoff = _now().subtract(limits.maxAge);
    var count = all.length;
    var bytes = all.fold<int>(0, (s, e) => s + e.size);
    for (final e in all) {
      final expired = e.enqueuedAt.isBefore(cutoff);
      if (!expired && count <= limits.maxCount && bytes <= limits.maxBytes) {
        continue;
      }
      await _deleteQuietly(e.file);
      count--;
      bytes -= e.size;
    }
  }

  /// Deletes every queued capsule (kill switch). Returns how many.
  Future<int> purge() => _lock.run(() async {
    final all = await _entries();
    for (final e in all) {
      await _deleteQuietly(e.file);
    }
    return all.length;
  });

  /// Uploads queued capsules, oldest first, while [allowed] holds (checked
  /// before every upload). Returns the result for [onlyId] when given and
  /// attempted.
  Future<UploadResult?> flush({
    required Future<UploadResult> Function(List<int> bytes) upload,
    required bool Function() allowed,
    String? onlyId,
  }) async {
    while (_flushing != null) {
      await _flushing;
    }
    final done = Completer<void>();
    _flushing = done.future;
    try {
      return await _flushOnce(upload, allowed, onlyId);
    } finally {
      _flushing = null;
      done.complete();
    }
  }

  Future<UploadResult?> _flushOnce(
    Future<UploadResult> Function(List<int>) upload,
    bool Function() allowed,
    String? onlyId,
  ) async {
    UploadResult? mine;
    final retryAt = _retryAt;
    if (retryAt != null && _now().isBefore(retryAt)) {
      return onlyId == null
          ? null
          : const UploadResult(UploadStatus.retryLater, message: 'queued');
    }
    final queue = await entries();
    // Stable: oldest first among entries with the same number of failures.
    queue.sort(
      (a, b) =>
          (_attempts[a.capsuleId] ?? 0).compareTo(_attempts[b.capsuleId] ?? 0),
    );
    for (final entry in queue) {
      if (_closed || !allowed()) break;
      List<int> bytes;
      try {
        bytes = await entry.file.readAsBytes();
      } on FileSystemException {
        continue; // evicted meanwhile, or unreadable: next pass decides
      }
      if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
        debugPrint(
          '[bugcapsule] dropping corrupt queued capsule ${entry.capsuleId}',
        );
        await _lock.run(() => _deleteQuietly(entry.file));
        continue;
      }
      final result = await upload(bytes);
      if (entry.capsuleId == onlyId) mine = result;
      if (result.status == UploadStatus.retryLater) {
        _attempts.update(entry.capsuleId, (n) => n + 1, ifAbsent: () => 1);
        _failures++;
        final base =
            const Duration(seconds: 30) * pow(2, min(_failures - 1, 7)).toInt();
        var delay = base > const Duration(hours: 1)
            ? const Duration(hours: 1)
            : base;
        final after = result.retryAfter;
        if (after != null && after > delay) delay = after;
        final jittered =
            delay.inMilliseconds * (0.8 + _random.nextDouble() * 0.4);
        _retryAt = _now().add(Duration(milliseconds: jittered.round()));
        break;
      }
      _failures = 0;
      _retryAt = null;
      _attempts.remove(entry.capsuleId);
      if (result.status == UploadStatus.rejected) {
        debugPrint(
          '[bugcapsule] upload of ${entry.capsuleId} rejected: ${result.message}',
        );
      }
      await _lock.run(() => _deleteQuietly(entry.file));
    }
    if (onlyId != null && mine == null) {
      mine = const UploadResult(UploadStatus.retryLater, message: 'queued');
    }
    return mine;
  }

  /// Stops uploading after the current file; later [enqueue]s are refused.
  Future<void> close() async {
    _closed = true;
    await _flushing;
    // Drain queued enqueue/purge operations before callers remove storage.
    await _lock.run(() async {});
  }
}

DateTime _modified(File f) {
  try {
    return f.lastModifiedSync();
  } on FileSystemException {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

Future<void> _writeAtomically(File file, List<int> bytes) async {
  final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  } catch (_) {
    await _deleteQuietly(tmp);
    rethrow;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // already gone
  }
}

Future<void> _removeTemporaryFiles(Directory dir) async {
  try {
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.tmp')) await _deleteQuietly(e);
    }
  } on FileSystemException {
    // nothing to clean
  }
}
