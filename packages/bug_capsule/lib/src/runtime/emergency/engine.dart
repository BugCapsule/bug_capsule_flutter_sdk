import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../config.dart' show BugCapsuleBackendConfig;
import 'contract.dart';
import 'store.dart';
import 'transport.dart';
import 'types.dart';

/// The last accepted document with what persists alongside it.
final class _Current {
  _Current(this.document, this.envelope, this.etag, this.receivedAt)
    : policiesKey = jsonEncode([for (final p in document.policies) p.toJson()]);

  final EmergencyPolicyDocument document;
  final Map<String, Object?> envelope;
  final String? etag;
  final DateTime receivedAt;

  /// Equal for two documents whose policies decide the same way.
  final String policiesKey;
}

/// The emergency client runtime of one configuration (§5, §7): keeps the
/// current verified document, refreshes it, sends receipts and answers
/// evaluations synchronously from memory.
///
/// Evaluations read [_current] once, so a swap is atomic for them. Fetches
/// run one at a time; callers arriving meanwhile join the running one.
/// While paused (app in the background) no timer runs.
class EmergencyEngine {
  EmergencyEngine({
    required this.anchor,
    required this.environment,
    required this.platform,
    required this.refreshInterval,
    required this.failureModes,
    required this.store,
    required this.transport,
    required this.connection,
    required this.appVersion,
    required this.sdkVersion,
    required this.installationId,
    required this.isReplaying,
    required this.onSnapshot,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random();

  /// A document is usable until this long after its `expires_at` (§7.4).
  static const grace = Duration(seconds: 300);
  static const maxBackoff = Duration(minutes: 15);

  /// At most one runtime report per this interval (§7.6).
  static const runtimeReportInterval = Duration(seconds: 60);

  final EmergencyTrustAnchor anchor;
  final String environment;
  final EmergencyPlatform platform;
  final Duration refreshInterval;
  final EmergencyFailureModes failureModes;

  /// Null when storage is unavailable: the module then works from memory.
  final EmergencyStore? store;
  final EmergencyTransport transport;
  final BugCapsuleBackendConfig? Function() connection;
  final String? Function() appVersion;
  final String sdkVersion;

  /// The default rollout subject and the receipt identity (§7.3).
  final String installationId;
  final bool Function() isReplaying;

  /// Called after every swap, off any lock, with the new snapshot.
  final void Function(EmergencySnapshot snapshot) onSnapshot;
  final DateTime Function() _now;
  final Random _random;

  _Current? _current;
  int _highestRevision = 0;
  int _failures = 0;
  bool _credentialRejected = false;
  bool _paused = false;
  bool _disposed = false;
  bool _started = false;
  DateTime? _lastFetchAt;
  DateTime? _lastAttemptAt;
  EmergencyError? _lastError;
  Timer? _timer;
  DateTime? _nextDueAt;
  Timer? _boundaryTimer;
  DateTime? _boundaryAt;
  Future<void>? _inFlight;
  Future<void> _persisting = Future.value();
  final Set<String> _receiptsSent = {};
  Map<String, Object?>? _runtime;
  String? _runtimeKey;
  final Set<String> _runtimeSent = {};
  DateTime? _runtimeSentAt;
  Timer? _runtimeTimer;
  final Set<String> _warned = {};
  EmergencySnapshot _snapshot = EmergencySnapshot.empty;

  EmergencySnapshot get snapshot => _snapshot;
  bool get credentialRejected => _credentialRejected;

  /// The delay of the pending scheduled fetch, for tests and diagnostics.
  @visibleForTesting
  DateTime? get nextFetchAt => _timer?.isActive ?? false ? _nextDueAt : null;

  void _warnOnce(String message) {
    if (_warned.add(message)) debugPrint('[bugcapsule] emergency: $message');
  }

  // ------------------------------------------------------------- startup

  /// Loads and re-verifies the cached envelope, publishes the snapshot and
  /// starts the first fetch in the background (§7.1). Never waits for the
  /// network.
  Future<void> start() async {
    await _loadCache();
    if (_disposed) return;
    _started = true;
    _publish();
    _sendRuntime(); // Waited for the highest revision of the cache.
    _scheduleBoundary();
    if (!_paused) unawaited(refresh());
  }

  Future<void> _loadCache() async {
    final s = store;
    if (s == null) return;
    EmergencyCacheEntry? entry;
    try {
      entry = await s.readCache(environment);
    } catch (e) {
      _warnOnce('cached policies unreadable: $e');
      return;
    }
    // A cache written for another application starts over.
    if (entry == null || entry.applicationId != anchor.applicationId) return;
    _highestRevision = entry.highestRevision;
    final envelope = entry.envelope;
    if (envelope == null) return;
    final verified = verifyEmergencyEnvelope(envelope, anchor, environment);
    switch (verified) {
      case EnvelopeVerified(:final document):
        _current = _Current(
          document,
          envelope,
          entry.etag,
          entry.receivedAt ?? _now(),
        );
        if (document.revision > _highestRevision) {
          _highestRevision = document.revision;
        }
      case EnvelopeRejected(:final reason):
        // A rotated key or another anchor: the cached document is no
        // longer trusted. The highest revision still guards against replay.
        _warnOnce(
          'discarding cached policies (${reason.wire}); the trust anchor '
          'or environment changed',
        );
        _persist(null);
    }
  }

  // ----------------------------------------------------------- evaluation

  bool _usable(_Current c, DateTime now) =>
      !now.isAfter(c.document.expiresAt.add(grace));

  EmergencyDocumentState _stateAt(_Current? c, DateTime now) => c == null
      ? EmergencyDocumentState.none
      : _usable(c, now)
      ? EmergencyDocumentState.usable
      : EmergencyDocumentState.expired;

  EmergencyDecision evaluate(String featureKey, {String? subject}) {
    final c = _current;
    final now = _now();
    EmergencyDecision fromDocument(EmergencyDecisionSource source) =>
        evaluateEmergencyPolicies(
          policies: c!.document.policies,
          documentRevision: c.document.revision,
          featureKey: featureKey,
          platform: platform.wire,
          appVersion: appVersion(),
          subject: subject ?? installationId,
          now: now,
          source: source,
        );
    if (c != null && _usable(c, now)) {
      return fromDocument(EmergencyDecisionSource.policy);
    }
    final mode = failureModes.modeFor(featureKey);
    if (mode == EmergencyFailureMode.useLastValidPolicy && c != null) {
      return fromDocument(EmergencyDecisionSource.stalePolicy);
    }
    return emergencyFailureDecision(featureKey, mode);
  }

  EmergencyStatus status() {
    final c = _current;
    return EmergencyStatus(
      initialized: true,
      active: true,
      state: _stateAt(c, _now()),
      revision: c?.document.revision,
      issuedAt: c?.document.issuedAt,
      expiresAt: c?.document.expiresAt,
      receivedAt: c?.receivedAt,
      lastFetchAt: _lastFetchAt,
      lastError: _lastError,
      credentialRejected: _credentialRejected,
      environment: environment,
      platform: platform,
    );
  }

  // -------------------------------------------------------------- refresh

  /// Fetches now, or joins the fetch already running (§7.2). A [scheduled]
  /// fetch is skipped after the backend refused the credential; an explicit
  /// one is still tried.
  Future<void> refresh({bool scheduled = false}) {
    if (_disposed || isReplaying()) return Future.value();
    if (scheduled && _credentialRejected) return Future.value();
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  Future<void> _refresh() async {
    _timer?.cancel();
    final backend = connection();
    if (backend == null) {
      _lastError = EmergencyError(
        code: 'not_connected',
        message:
            'no BugCapsule connection: pass a token or backend, '
            'or call BugCapsule.init',
        at: _now(),
      );
      _warnOnce('no BugCapsule connection yet; policies are not fetched');
      _schedule(refreshInterval);
      return;
    }
    _sendRuntime(); // A report that waited for a connection.
    final current = _current;
    EmergencyFetchResult result;
    try {
      result = await transport.fetchPolicies(
        EmergencyFetchRequest(
          backend: backend,
          applicationId: anchor.applicationId,
          environment: environment,
          platform: platform.wire,
          appVersion: appVersion(),
          sdkVersion: sdkVersion,
          etag: current?.etag,
        ),
      );
    } catch (e) {
      result = EmergencyFetchFailed('network_error', '$e');
    }
    _lastAttemptAt = _now();
    if (_disposed || isReplaying()) return;
    switch (result) {
      case EmergencyNotModified():
        _lastFetchAt = _now();
        _succeeded();
      case EmergencyFetched(:final body, :final etag):
        _lastFetchAt = _now();
        _accept(body, etag);
      case EmergencyFetchFailed():
        _failed(
          EmergencyError(
            code: result.code,
            message: result.message,
            at: _now(),
            httpStatus: result.status,
          ),
          retryAfter: result.retryAfter,
          credentialRejected: result.credentialRejected,
        );
    }
  }

  /// Verification (§4), then acceptance (§5) of a `200` body.
  void _accept(Object? body, String? etag) {
    final verified = verifyEmergencyEnvelope(body, anchor, environment);
    final EmergencyPolicyDocument doc;
    switch (verified) {
      case EnvelopeRejected(:final reason):
        // The unverified payload's revision is not trusted; the receipt
        // names the revision this installation still runs on.
        _reject(reason, _current?.document.revision ?? _highestRevision);
        return;
      case EnvelopeVerified(:final document):
        doc = document;
    }
    if (doc.revision < _highestRevision) {
      _reject(EmergencyRejection.staleRevision, doc.revision);
      return;
    }
    final previous = _current;
    if (previous != null &&
        doc.revision == previous.document.revision &&
        !doc.issuedAt.isAfter(previous.document.issuedAt)) {
      _succeeded(); // Same document or an older copy: nothing changes.
      return;
    }
    final now = _now();
    if (now.isAfter(doc.expiresAt.add(grace))) {
      _reject(EmergencyRejection.expiredOnArrival, doc.revision);
      return;
    }
    final next = _Current(
      doc,
      (body! as Map).cast<String, Object?>(),
      etag,
      now.toUtc(),
    );
    final mayDiffer =
        previous == null ||
        previous.document.revision != doc.revision ||
        !_usable(previous, now) ||
        previous.policiesKey != next.policiesKey;
    _current = next;
    if (doc.revision > _highestRevision) _highestRevision = doc.revision;
    _persist(next);
    _succeeded();
    _receipt(doc.revision, 'APPLIED', null);
    if (mayDiffer) {
      _publish();
    } else {
      _snapshot = _snapshotOf(next, now);
    }
    _scheduleBoundary();
  }

  void _reject(EmergencyRejection reason, int revision) {
    _warnOnce('rejected policy document: ${reason.wire}');
    _receipt(revision, 'FAILED', reason.wire);
    _failed(
      EmergencyError(
        code: reason.wire,
        message: 'policy document rejected: ${reason.wire}',
        at: _now(),
        httpStatus: 200,
      ),
    );
  }

  void _succeeded() {
    _failures = 0;
    _lastError = null;
    _credentialRejected = false;
    _schedule(refreshInterval);
  }

  void _failed(
    EmergencyError error, {
    Duration? retryAfter,
    bool credentialRejected = false,
  }) {
    _failures++;
    _lastError = error;
    if (credentialRejected) {
      // §3: no more scheduled fetches in this process; the cached document
      // stays in use until it expires.
      if (!_credentialRejected) {
        debugPrint(
          '[bugcapsule] emergency: the backend refused the credential '
          '(${error.message}); policies are no longer fetched in this '
          'process, the cached document is used until it expires',
        );
      }
      _credentialRejected = true;
      _timer?.cancel();
      _nextDueAt = null;
      return;
    }
    final exp = refreshInterval * pow(2, min(_failures - 1, 16)).toInt();
    var delay = exp > maxBackoff ? maxBackoff : exp;
    if (retryAfter != null && retryAfter > delay) delay = retryAfter;
    _schedule(_jitter(delay));
  }

  Duration _jitter(Duration d) => Duration(
    milliseconds: (d.inMilliseconds * (0.8 + _random.nextDouble() * 0.4))
        .round(),
  );

  void _schedule(Duration delay) {
    _timer?.cancel();
    _nextDueAt = _now().add(delay);
    if (_disposed || _paused) return;
    _timer = Timer(delay, () => unawaited(refresh(scheduled: true)));
  }

  // ------------------------------------------------------------ lifecycle

  /// The app went to the background: no timer runs until [onResumed].
  void onPaused() {
    _paused = true;
    _timer?.cancel();
    _boundaryTimer?.cancel();
    _runtimeTimer?.cancel();
    _runtimeTimer = null;
  }

  /// Back in the foreground: decisions that changed meanwhile are
  /// published, and policies are fetched unless a backoff is still running
  /// or a fetch finished less than 15 seconds ago.
  void onResumed() {
    if (!_paused || _disposed) return;
    _paused = false;
    final now = _now();
    final boundary = _boundaryAt;
    if (boundary != null && !now.isBefore(boundary)) _publish();
    _scheduleBoundary();
    _sendRuntime();
    if (_credentialRejected || _inFlight != null || isReplaying()) return;
    final due = _nextDueAt;
    final last = _lastAttemptAt;
    final recent =
        last != null &&
        now.difference(last) < EmergencyConfig.minRefreshInterval;
    if (due != null && due.isAfter(now) && (_failures > 0 || recent)) {
      _schedule(due.difference(now));
    } else {
      unawaited(refresh());
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _boundaryTimer?.cancel();
    _runtimeTimer?.cancel();
  }

  // ---------------------------------------------------- snapshots, storage

  EmergencySnapshot _snapshotOf(_Current? c, DateTime now) => c == null
      ? EmergencySnapshot.empty
      : EmergencySnapshot(
          document: c.document,
          state: _stateAt(c, now),
          receivedAt: c.receivedAt,
        );

  void _publish() {
    final s = _snapshot = _snapshotOf(_current, _now());
    try {
      onSnapshot(s);
    } catch (e) {
      _warnOnce('a snapshot observer failed: $e');
    }
  }

  /// Fires when the document stops being usable or a policy expires, since
  /// decisions change then without a new document. At most a day ahead;
  /// longer waits are re-armed.
  void _scheduleBoundary() {
    _boundaryTimer?.cancel();
    _boundaryAt = null;
    final c = _current;
    if (c == null || _disposed) return;
    final now = _now();
    DateTime? next;
    void consider(DateTime t) {
      if (t.isAfter(now) && (next == null || t.isBefore(next!))) next = t;
    }

    consider(
      c.document.expiresAt.add(grace).add(const Duration(milliseconds: 1)),
    );
    for (final p in c.document.policies) {
      final e = p.expiresAt;
      if (e != null) consider(e);
    }
    final at = next;
    if (at == null) return;
    _boundaryAt = at;
    if (_paused) return;
    var delay = at.difference(now);
    final rearm = delay > const Duration(days: 1);
    if (rearm) delay = const Duration(days: 1);
    _boundaryTimer = Timer(delay, () {
      if (_disposed) return;
      if (!rearm) _publish();
      _scheduleBoundary();
    });
  }

  /// Writes are chained so they land in the order they were made.
  void _persist(_Current? c) {
    final s = store;
    if (s == null) return;
    final entry = EmergencyCacheEntry(
      applicationId: anchor.applicationId,
      highestRevision: _highestRevision,
      envelope: c?.envelope,
      etag: c?.etag,
      receivedAt: c?.receivedAt,
    );
    _persisting = _persisting.then((_) async {
      try {
        await s.writeCache(environment, entry);
      } catch (e) {
        _warnOnce('could not persist policies: $e');
      }
    });
  }

  /// Waits for pending cache writes (tests, shutdown).
  Future<void> flush() => _persisting;

  // -------------------------------------------------------------- receipts

  /// Fire-and-forget, at most once per (revision, status, code) and process.
  /// Carries the latest runtime object when there is one (§7.6).
  void _receipt(int revision, String status, String? errorCode) {
    if (isReplaying()) return;
    final backend = connection();
    if (backend == null) return;
    if (!_receiptsSent.add('$revision|$status|${errorCode ?? ''}')) return;
    _post(backend, revision, status, errorCode, _runtime);
  }

  /// The adapters' state changed: [runtime] is the validated `runtime`
  /// object of §7.6. Reported at most once per distinct object and process,
  /// and at most once per [runtimeReportInterval]; an object that changes
  /// again within the interval is sent once, as it is when the interval
  /// ends.
  void updateRuntime(Map<String, Object?> runtime) {
    if (_disposed) return;
    _runtime = runtime;
    _runtimeKey = jsonEncode(runtime);
    _sendRuntime();
  }

  /// The latest runtime object, for diagnostics and tests.
  @visibleForTesting
  Map<String, Object?>? get runtime => _runtime;

  void _sendRuntime() {
    final runtime = _runtime;
    final key = _runtimeKey;
    if (runtime == null || key == null || _runtimeSent.contains(key)) return;
    if (!_started || _disposed || _paused || _runtimeTimer != null) return;
    if (isReplaying()) return;
    final backend = connection();
    if (backend == null) return; // Sent once there is a connection.
    final now = _now();
    final last = _runtimeSentAt;
    if (last != null) {
      final wait = last.add(runtimeReportInterval).difference(now);
      if (wait > Duration.zero) {
        _runtimeTimer = Timer(wait, () {
          _runtimeTimer = null;
          _sendRuntime();
        });
        return;
      }
    }
    _runtimeSent.add(key);
    _runtimeSentAt = now;
    _post(backend, _highestRevision, 'RUNTIME', null, runtime);
  }

  void _post(
    BugCapsuleBackendConfig backend,
    int revision,
    String status,
    String? errorCode,
    Map<String, Object?>? runtime,
  ) {
    final version = appVersion();
    final body = <String, Object?>{
      'environment': environment,
      'platform': platform.wire,
      'installationId': installationId,
      'appVersion': version != null && version.length <= 64 ? version : null,
      'sdkVersion': sdkVersion.length <= 64 ? sdkVersion : null,
      'revision': revision,
      'status': status,
      'errorCode': errorCode,
      'runtime': ?runtime,
    };
    unawaited(
      Future.sync(
        () => transport.sendReceipt(backend, anchor.applicationId, body),
      ).catchError((Object e) {
        debugPrint('[bugcapsule] emergency: receipt not sent: $e');
      }),
    );
  }
}
