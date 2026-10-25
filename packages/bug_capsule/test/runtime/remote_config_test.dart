import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule/src/runtime/remote_config.dart';

/// A backend whose answers the test scripts, on a fake clock.
class FakeBackend {
  FakeBackend(this.async);

  final FakeAsync async;
  final List<ConfigFetchResult Function()> script = [];
  int calls = 0;
  bool enabled = true;
  double sampleRate = 1;
  int ttl = 300;

  RemoteCaptureConfig config() => RemoteCaptureConfig(
        enabled: enabled,
        sampleRate: sampleRate,
        maxCapsuleBytes: 1024,
        captureNetworkBodies: true,
        redactKeys: const [],
        configTtlSeconds: ttl,
        fetchedAtMs: async.getClock(DateTime.utc(2026)).now().millisecondsSinceEpoch,
      );

  Future<ConfigFetchResult> fetch() async {
    calls++;
    if (script.isNotEmpty) return script.removeAt(0)();
    return ConfigFetched(config());
  }
}

class MemoryCache implements RemoteConfigCache {
  final Map<String, RemoteCaptureConfig> byScope = {};
  @override
  Future<RemoteCaptureConfig?> read(String scope) async => byScope[scope];
  @override
  Future<void> write(String scope, RemoteCaptureConfig config) async => byScope[scope] = config;
}

void main() {
  late List<(RemoteCaptureConfig?, RemoteCaptureConfig)> changes;

  RemoteConfigController controller(FakeAsync async, FakeBackend backend, MemoryCache cache,
          {String scope = 'prod'}) =>
      RemoteConfigController(
        fetch: backend.fetch,
        cache: cache,
        scope: scope,
        onChange: (p, n) => changes.add((p, n)),
        now: () => async.getClock(DateTime.utc(2026)).now(),
        random: Random(1),
      );

  setUp(() => changes = []);

  test('refreshes after the TTL and applies every change', () {
    fakeAsync((async) {
      final backend = FakeBackend(async)..ttl = 60;
      final c = controller(async, backend, MemoryCache());
      c.refresh();
      async.flushMicrotasks();
      expect(backend.calls, 1);
      expect(c.uploadsAllowed, isTrue);

      backend.enabled = false;
      async.elapse(const Duration(seconds: 59));
      expect(backend.calls, 1);
      async.elapse(const Duration(seconds: 2));
      expect(backend.calls, 2);
      expect(changes.last.$2.enabled, isFalse);
      expect(c.captureAllowed, isFalse);
      expect(c.uploadsAllowed, isFalse);
      c.dispose();
    });
  });

  test('a TTL of 0 is refreshed no more often than the minimum interval', () {
    fakeAsync((async) {
      final backend = FakeBackend(async)..ttl = 0;
      final c = controller(async, backend, MemoryCache());
      c.refresh();
      async.elapse(const Duration(seconds: 29));
      expect(backend.calls, 1);
      async.elapse(const Duration(seconds: 2));
      expect(backend.calls, 2);
      c.dispose();
    });
  });

  test('backs off exponentially on failures and honours Retry-After', () {
    fakeAsync((async) {
      final backend = FakeBackend(async);
      backend.script.addAll([
        () => const ConfigFetchFailed('offline'),
        () => const ConfigFetchFailed('offline'),
        () => const ConfigFetchFailed('busy', status: 429, retryAfter: Duration(minutes: 10)),
      ]);
      final c = controller(async, backend, MemoryCache());
      c.refresh();
      async.flushMicrotasks();
      expect(backend.calls, 1);
      async.elapse(const Duration(seconds: 37)); // 30 s ± 20 %
      expect(backend.calls, 2);
      async.elapse(const Duration(seconds: 73)); // 60 s ± 20 %
      expect(backend.calls, 3);
      async.elapse(const Duration(minutes: 7));
      expect(backend.calls, 3, reason: 'Retry-After (10 min) beats the 2 min backoff');
      async.elapse(const Duration(minutes: 5));
      expect(backend.calls, 4);
      expect(c.uploadsAllowed, isTrue);
      c.dispose();
    });
  });

  test('with no config yet, capture may run but uploads wait for a fetch', () {
    fakeAsync((async) {
      final backend = FakeBackend(async)..script.add(() => const ConfigFetchFailed('offline'));
      final c = controller(async, backend, MemoryCache());
      c.loadCached();
      c.refresh();
      async.flushMicrotasks();
      expect(c.current, isNull);
      expect(c.captureAllowed, isTrue);
      expect(c.uploadsAllowed, isFalse);
      c.dispose();
    });
  });

  test('the cache is scoped to backend and key, and a cached kill switch is sticky', () {
    fakeAsync((async) {
      final cache = MemoryCache();
      final backend = FakeBackend(async)..enabled = false;
      final staging = controller(async, backend, cache, scope: 'staging');
      staging.refresh();
      async.flushMicrotasks();
      staging.dispose();

      final prod = controller(async, FakeBackend(async), cache, scope: 'prod');
      prod.loadCached();
      async.flushMicrotasks();
      expect(prod.current, isNull, reason: "staging's kill switch must not apply to prod");
      prod.dispose();

      // Months later and offline, the staging app still honours its switch.
      async.elapse(const Duration(days: 90));
      final offline = FakeBackend(async)..script.add(() => const ConfigFetchFailed('offline'));
      final again = controller(async, offline, cache, scope: 'staging');
      again.loadCached();
      async.flushMicrotasks();
      expect(again.captureAllowed, isFalse);
      again.refresh();
      async.flushMicrotasks();
      expect(again.captureAllowed, isFalse);
      again.dispose();
    });
  });

  test('a stale config stops uploads but not capture', () {
    fakeAsync((async) {
      final cache = MemoryCache();
      final c = controller(async, FakeBackend(async), cache);
      c.refresh();
      async.flushMicrotasks();
      c.dispose();
      async.elapse(const Duration(days: 8));
      final later = controller(async, FakeBackend(async)..script.add(() => const ConfigFetchFailed('x')), cache);
      later.loadCached();
      async.flushMicrotasks();
      expect(later.captureAllowed, isTrue);
      expect(later.uploadsAllowed, isFalse, reason: 'older than maxStale (7 days)');
      later.dispose();
    });
  });

  test('a rejected ingest key acts as a kill switch for the session', () {
    fakeAsync((async) {
      final backend = FakeBackend(async)..script.add(() => const ConfigFetchFailed('HTTP 401', status: 401));
      final c = controller(async, backend, MemoryCache());
      c.refresh();
      async.flushMicrotasks();
      expect(c.captureAllowed, isFalse);
      expect(changes.single.$2.enabled, isFalse);
      c.dispose();
    });
  });

  test('a refusal is reported once with its reason; success and failures are tracked', () {
    fakeAsync((async) {
      final backend = FakeBackend(async);
      backend.script.addAll([
          () => const ConfigFetchFailed('offline'),
          () => ConfigFetched(backend.config()),
          () => const ConfigFetchFailed('HTTP 401',
              status: 401, reason: 'token_revoked', detail: 'generate a new token'),
          () => const ConfigFetchFailed('HTTP 401', status: 401, reason: 'token_revoked'),
        ]);
      final refused = <ConfigFetchFailed>[];
      final c = RemoteConfigController(
        fetch: backend.fetch,
        cache: MemoryCache(),
        scope: 'prod',
        onChange: (p, n) => changes.add((p, n)),
        onRejected: refused.add,
        now: () => async.getClock(DateTime.utc(2026)).now(),
        random: Random(1),
      );
      c.refresh();
      async.flushMicrotasks();
      expect(c.lastFailure?.transient, isTrue);
      expect(c.fetchedThisSession, isNull);
      c.refresh();
      async.flushMicrotasks();
      expect(c.lastFailure, isNull);
      expect(c.fetchedThisSession, DateTime.utc(2026));
      c.refresh();
      async.flushMicrotasks();
      c.refresh();
      async.flushMicrotasks();
      expect(c.rejected, isTrue);
      expect(c.lastFailure?.reason, 'token_revoked');
      expect(refused.single.detail, 'generate a new token');
      c.dispose();
    });
  });

  test('pause stops the timer; resume refreshes a stale config at once', () {
    fakeAsync((async) {
      final backend = FakeBackend(async)..ttl = 60;
      final c = controller(async, backend, MemoryCache());
      c.refresh();
      async.flushMicrotasks();
      c.onPaused();
      async.elapse(const Duration(minutes: 10));
      expect(backend.calls, 1, reason: 'no refresh while paused');
      c.onResumed();
      async.flushMicrotasks();
      expect(backend.calls, 2);
      c.onPaused();
      c.onResumed(); // fresh: reschedules instead of fetching
      async.flushMicrotasks();
      expect(backend.calls, 2);
      c.dispose();
    });
  });

  test('concurrent refreshes share one fetch; dispose cancels timers', () {
    fakeAsync((async) {
      final backend = FakeBackend(async);
      final c = controller(async, backend, MemoryCache());
      c.refresh();
      c.refresh();
      c.ensureFresh();
      async.flushMicrotasks();
      expect(backend.calls, 1);
      c.dispose();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(hours: 1));
      expect(backend.calls, 1);
    });
  });

  test('malformed config bodies are rejected, values are clamped', () {
    expect(() => RemoteCaptureConfig.fromJson({'enabled': 'no'}), throwsFormatException);
    final c = RemoteCaptureConfig.fromJson({'sampleRate': 7, 'configTtlSeconds': -5});
    expect(c.sampleRate, 1);
    expect(c.configTtlSeconds, 0);
  });
}
