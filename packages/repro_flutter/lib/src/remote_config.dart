import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Capture config the backend can change at runtime (kill switch, sampling,
/// bodies, redaction).
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

  /// Parses the `/v1/sdk/config` body (or the cache file). Throws
  /// [FormatException] on wrong types; values are clamped to sane ranges.
  factory RemoteCaptureConfig.fromJson(Map<String, Object?> j, {int? fetchedAtMs}) {
    T? field<T>(String key) {
      final v = j[key];
      if (v == null || v is T) return v as T?;
      throw FormatException('remote config "$key" has type ${v.runtimeType}');
    }

    final rate = field<num>('sampleRate')?.toDouble() ?? 1;
    final ttl = field<int>('configTtlSeconds') ?? 300;
    final maxBytes = field<int>('maxCapsuleBytes') ?? 5 * 1024 * 1024;
    return RemoteCaptureConfig(
      enabled: field<bool>('enabled') ?? true,
      sampleRate: rate.isNaN ? 0 : rate.clamp(0, 1).toDouble(),
      maxCapsuleBytes: maxBytes < 1 ? 1 : maxBytes,
      captureNetworkBodies: field<bool>('captureNetworkBodies') ?? true,
      redactKeys: [for (final k in field<List<Object?>>('redactKeys') ?? const []) '$k'],
      configTtlSeconds: ttl.clamp(0, 86400),
      fetchedAtMs: fetchedAtMs ?? field<int>('fetchedAtMs') ?? 0,
    );
  }

  final bool enabled;
  final double sampleRate;
  final int maxCapsuleBytes;
  final bool captureNetworkBodies;
  final List<String> redactKeys;
  final int configTtlSeconds;

  /// Wall clock (epoch ms) of the successful fetch this config came from.
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

/// Result of one `GET /v1/sdk/config`.
sealed class ConfigFetchResult {
  const ConfigFetchResult();
}

class ConfigFetched extends ConfigFetchResult {
  const ConfigFetched(this.config);
  final RemoteCaptureConfig config;
}

class ConfigFetchFailed extends ConfigFetchResult {
  const ConfigFetchFailed(this.message, {this.status, this.retryAfter});
  final String message;

  /// HTTP status, null for network errors.
  final int? status;
  final Duration? retryAfter;

  /// The ingest key was rejected (revoked or rotated).
  bool get unauthorized => status == 401 || status == 403;
}

/// Where the last good config is persisted between launches.
abstract interface class RemoteConfigCache {
  /// The cached config for [scope], or null (missing, corrupt, or written
  /// for another backend/ingest key).
  Future<RemoteCaptureConfig?> read(String scope);
  Future<void> write(String scope, RemoteCaptureConfig config);
}

/// Keeps the remote capture config current and decides what it allows.
///
/// **Startup.** [loadCached] restores the last config fetched for this
/// backend and ingest key ([scope]); a config cached for another environment
/// is ignored. A cached kill switch stays in force however old it is, until a
/// successful fetch says otherwise.
///
/// **Refresh.** After a successful fetch the next one is scheduled after the
/// config's TTL (at least [minInterval]); after a failure it backs off
/// exponentially from [minInterval] to [maxBackoff] with ±20 % jitter,
/// honouring `Retry-After`. [onResumed] refreshes a stale config when the app
/// returns to the foreground; [onPaused] stops the timer.
///
/// **Uploads** are allowed only with a config that is enabled and was
/// fetched within [maxStale]: with no config yet (first launch, offline),
/// captures wait in the outbox until a fetch succeeds.
///
/// **Rejected key.** A 401/403 behaves like a kill switch for the rest of
/// the session (not persisted).
class RemoteConfigController {
  RemoteConfigController({
    required this.fetch,
    required this.cache,
    required this.scope,
    required this.onChange,
    this.maxStale = const Duration(days: 7),
    this.minInterval = const Duration(seconds: 30),
    this.maxBackoff = const Duration(minutes: 30),
    DateTime Function()? now,
    Random? random,
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random();

  final Future<ConfigFetchResult> Function() fetch;
  final RemoteConfigCache cache;
  final String scope;

  /// Called with the previous and the new config whenever a fetch (or a
  /// rejected key) changes what applies.
  final void Function(RemoteCaptureConfig? previous, RemoteCaptureConfig next) onChange;
  final Duration maxStale;
  final Duration minInterval;
  final Duration maxBackoff;
  final DateTime Function() _now;
  final Random _random;

  RemoteCaptureConfig? _current;
  bool _keyRejected = false;
  int _failures = 0;
  Timer? _timer;
  Future<void>? _inFlight;
  bool _paused = false;
  bool _disposed = false;

  RemoteCaptureConfig? get current => _current;

  Duration get _ttl {
    final ttl = Duration(seconds: _current?.configTtlSeconds ?? 0);
    return ttl < minInterval ? minInterval : ttl;
  }

  Duration? get age => _current == null
      ? null
      : Duration(milliseconds: _now().millisecondsSinceEpoch - _current!.fetchedAtMs);

  bool get isFresh => age != null && age! < _ttl;

  /// Capture may run: nothing says otherwise. Without any config the app's
  /// local settings decide (uploads still wait, see [uploadsAllowed]).
  bool get captureAllowed => !_keyRejected && (_current?.enabled ?? true);

  bool get uploadsAllowed =>
      !_keyRejected && _current != null && _current!.enabled && age! <= maxStale;

  Future<void> loadCached() async {
    try {
      _current = await cache.read(scope);
    } catch (e) {
      debugPrint('[repro] cached config unreadable: $e');
    }
  }

  /// Fetches now unless a fetch is already running (then waits for it).
  Future<void> refresh() {
    if (_disposed) return Future.value();
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  /// Refreshes first when the config is missing or older than its TTL.
  Future<void> ensureFresh() => isFresh ? Future.value() : refresh();

  Future<void> _refresh() async {
    _timer?.cancel();
    ConfigFetchResult result;
    try {
      result = await fetch();
    } catch (e) {
      result = ConfigFetchFailed('$e');
    }
    if (_disposed) return;
    switch (result) {
      case ConfigFetched(:final config):
        _failures = 0;
        final previous = _current;
        _current = config;
        _keyRejected = false;
        try {
          await cache.write(scope, config);
        } catch (e) {
          debugPrint('[repro] could not cache remote config: $e');
        }
        if (_disposed) return;
        _notify(previous, config);
        _schedule(_ttl);
      case ConfigFetchFailed():
        _failures++;
        if (result.unauthorized && !_keyRejected) {
          _keyRejected = true;
          debugPrint('[repro] ingest key rejected (HTTP ${result.status}); capture stopped');
          final previous = _current;
          _notify(previous, _disabledLike(previous));
        }
        final exp = minInterval * pow(2, min(_failures - 1, 16)).toInt();
        var delay = exp > maxBackoff ? maxBackoff : exp;
        final retryAfter = result.retryAfter;
        if (retryAfter != null && retryAfter > delay) delay = retryAfter;
        _schedule(_jitter(delay));
    }
  }

  void _notify(RemoteCaptureConfig? previous, RemoteCaptureConfig next) {
    try {
      onChange(previous, next);
    } catch (e) {
      debugPrint('[repro] applying remote config failed: $e');
    }
  }

  RemoteCaptureConfig _disabledLike(RemoteCaptureConfig? c) => RemoteCaptureConfig(
        enabled: false,
        sampleRate: c?.sampleRate ?? 0,
        maxCapsuleBytes: c?.maxCapsuleBytes ?? 0,
        captureNetworkBodies: false,
        redactKeys: c?.redactKeys ?? const [],
        configTtlSeconds: c?.configTtlSeconds ?? 0,
        fetchedAtMs: c?.fetchedAtMs ?? 0,
      );

  Duration _jitter(Duration d) =>
      Duration(milliseconds: (d.inMilliseconds * (0.8 + _random.nextDouble() * 0.4)).round());

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (_disposed || _paused) return;
    _timer = Timer(delay, () => unawaited(refresh()));
  }

  void onPaused() {
    _paused = true;
    _timer?.cancel();
  }

  void onResumed() {
    if (!_paused || _disposed) return;
    _paused = false;
    if (_inFlight != null) return;
    if (isFresh) {
      final remaining = _ttl - age!;
      _schedule(remaining);
    } else {
      unawaited(refresh());
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
