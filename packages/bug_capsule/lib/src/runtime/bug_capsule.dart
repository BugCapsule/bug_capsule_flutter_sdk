import '../version.dart';
import 'dart:async';
import 'dart:async' as async show runZonedGuarded;
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import '../core/core.dart';

import 'actions.dart';
import 'backend.dart';
import 'binding.dart';
import 'config.dart';
import 'connection_token.dart';
import 'integration.dart';
import 'interactions.dart';
import 'monitoring/breadcrumbs.dart';
import 'monitoring/hub.dart';
import 'monitoring/scope.dart';
import 'monitoring/tracing.dart';
import 'remote_config.dart';
import 'replay_engine.dart';
import 'state_tracker.dart';
import 'status.dart';

// The capsule's `sdk.name`: the backend and CLI read it to pick the Flutter
// runtime, so it keeps the old package name.
const _sdkName = 'bug_capsule_flutter';
const _sdkVersion = bugCapsuleVersion;

List<int> _encodeCapsule(Capsule capsule) => CapsuleCodec.encode(capsule);

/// Reads [journalPath] and builds its crash capsule; top-level so that only
/// its arguments cross to the background isolate.
CrashCapsuleBuild? _buildFromJournal(
  String journalPath,
  CrashCapsuleRequest request,
) {
  final contents = JournalContents.read(Directory(journalPath));
  return contents == null ? null : buildCrashCapsule(contents, request);
}

Future<CrashCapsuleBuild?> _buildInBackground(
  String journalPath,
  CrashCapsuleRequest request,
) => Isolate.run(() => _buildFromJournal(journalPath, request));

/// Result of writing a capsule.
class CaptureResult {
  const CaptureResult({
    required this.capsuleId,
    required this.file,
    required this.eligibility,
    required this.upload,
    this.failureSignature,
  });

  final String capsuleId;
  final File file;
  final Eligibility eligibility;
  final String? failureSignature;

  /// Null when no backend is configured or upload was skipped.
  final UploadResult? upload;
}

/// Replaces the SDK's storage location, backend transport and sampling
/// randomness in tests.
@visibleForTesting
class BugCapsuleTestOverrides {
  const BugCapsuleTestOverrides({
    this.storageDirectory,
    this.transport,
    this.envelopeTransport,
    this.random,
    this.setupTimeout,
    this.encodeCapsule,
  });

  final Directory? storageDirectory;
  final BugCapsuleTransport? transport;

  /// Monitoring envelopes; defaults to [transport] when it implements
  /// [EnvelopeTransport].
  final EnvelopeTransport? envelopeTransport;
  final Random? random;
  final Duration? setupTimeout;

  /// Deterministic encoding boundary for capture cancellation tests.
  final Future<List<int>> Function(Capsule)? encodeCapsule;
}

/// Entry point of the BugCapsule SDK.
///
/// ```dart
/// void main() => BugCapsule.init(
///       config: const BugCapsuleConfig(token: 'bcsdk.v1.…'),
///       appRunner: () => runApp(const MyApp()),
///     );
/// ```
///
/// Replay gets more complete with each integration the app adds:
/// `integrations: [BugCapsuleDio(...), BugCapsuleGoRouter(), BugCapsuleBloc(...)]`.
/// [status] tells what is connected and what is still missing.
///
/// Call [init] first in `main`, before `WidgetsFlutterBinding.ensureInitialized`,
/// so the binding is created inside BugCapsule's zone and `clock.now()` is
/// controllable during replay.
///
/// BugCapsule never stops the app from starting: if storage, an integration's
/// setup or anything else in capture setup fails, the app runs without
/// capture and the reason is printed with `debugPrint`.
abstract final class BugCapsule {
  static _Runtime? _rt;

  @visibleForTesting
  static BugCapsuleTestOverrides? debugOverrides;

  static Future<void> init({
    required BugCapsuleConfig config,
    List<BugCapsuleIntegration> integrations = const [],
    required FutureOr<void> Function() appRunner,
  }) {
    if (_rt != null) throw StateError('BugCapsule.init called twice');
    final rt = _rt = _Runtime(
      config,
      integrations,
      debugOverrides,
      _callerPackage(StackTrace.current),
    );
    return withClock(Clock(rt.wallClock), () => rt.start(appRunner));
  }

  static bool get isInitialized => _rt != null;

  /// Connection and instrumentation, for setup checks and support: whether
  /// the token works, whether the backend accepted the config fetch and the
  /// first data, and which replay integrations are still missing. Before
  /// [init] the state is `notConfigured`.
  static BugCapsuleStatus get status =>
      _rt?.status ?? _Runtime.statusBeforeInit;
  static bool get isReplaying => _rt?.engine != null;
  static bool get isRecording => _rt?.isRecording ?? false;
  static CaptureMode? get mode => _rt?.config.mode;
  static BugCapsuleSession? get session => _rt;

  /// Seeded per session and restored in replay. Use it for randomness that
  /// affects behaviour you want reproducible.
  static Random get random => _rt?.random ?? _fallbackRandom;
  static final Random _fallbackRandom = Random();

  /// Wraps a UI callback as a named semantic action: records it, and lets
  /// semantic replay invoke it by [id].
  ///
  /// `onPressed: BugCapsule.action('cart.checkout', () => bloc.add(Checkout()))`
  static VoidCallback action(String id, VoidCallback callback) {
    _actions.register(id, (_) => callback());
    return () {
      _rt?.record(EventTypes.action, {'id': id});
      _rt?.hub?.onUserAction(id);
      callback();
    };
  }

  /// Like [action] with a JSON payload passed to the handler.
  static void Function(Map<String, Object?> payload) actionWithPayload(
    String id,
    void Function(Map<String, Object?> payload) callback,
  ) {
    _actions.register(id, (p) => callback(p ?? const {}));
    return (payload) {
      _rt?.record(EventTypes.action, {'id': id, 'payload': payload});
      callback(payload);
    };
  }

  /// Records edits of [controller] under [id] and restores them in replay.
  /// Values are redacted when [sensitive] is true (use it for any obscured
  /// field) or the id looks sensitive (`password`, `otp`, ...); credentials
  /// found inside other values are scrubbed.
  static void trackText(
    String id,
    TextEditingController controller, {
    bool sensitive = false,
  }) {
    _actions.trackText(id, controller);
    var last = controller.text;
    controller.addListener(() {
      if (controller.text == last) return;
      last = controller.text;
      final rt = _rt;
      if (rt == null || !rt.isRecording) return;
      final value = rt.redactor.redactText(id, last, sensitive: sensitive);
      rt.record(EventTypes.text, {
        'id': id.length <= 200 ? id : id.substring(0, 200),
        'value': value.length <= 100000 ? value : value.substring(0, 100000),
      });
    });
  }

  static void untrackText(String id, TextEditingController controller) =>
      _actions.untrackText(id, controller);

  /// Raises a named failure assertion. Replay is judged against [assertionId].
  static void fail(String assertionId, [String message = '']) {
    final rt = _rt;
    if (rt == null) return;
    final prepared = rt.hub?.prepareException(
      StateError(message),
      StackTrace.current,
      mechanism: Mechanism.assertion,
      typeOverride: assertionId,
      valueOverride: message,
    );
    final capsule = rt.handleFailure(
      FailureRecord.assertion(
        assertionId,
        message,
        rt.now(),
        scrub: rt.redactor.scrubText,
      ),
      monitoring: prepared?.monitoringInfo(),
    );
    if (prepared != null) rt.hub!.submit(prepared, capsule: capsule);
  }

  /// Raises [assertionId] when [condition] is false.
  static void check(String assertionId, bool condition, [String message = '']) {
    if (!condition) fail(assertionId, message);
  }

  static void log(String message, {String level = 'info'}) =>
      _rt?.record(EventTypes.log, {'level': level, 'message': message});

  /// Writes a capsule now (QA "capture" button). Uses the latest failure in
  /// the window as the assertion when there is one.
  static Future<CaptureResult?> capture({String? note}) async =>
      _rt?.writeCapsule(failure: _rt?.lastFailure, labels: {'note': ?note});

  static Future<List<File>> savedCaptures() async =>
      (await _rt?.store)?.savedCaptures() ?? const [];

  /// Fetches the remote capture config now (it is otherwise refreshed after
  /// its TTL and when the app resumes). The returned future completes with
  /// a config fetched after this call, also when a fetch was already running
  /// (such as the one `init` starts).
  static Future<void> refreshRemoteConfig() async =>
      _rt?.remote?.refresh(current: true);

  /// Uploads queued capsules now, if the remote config allows it.
  static Future<void> flushUploads() async => _rt?.flushOutbox();

  // Used by BugCapsuleOverlay so its own touches are not recorded.
  static void suppressPointer(int pointer) =>
      _rt?.suppressedPointers.add(pointer);
  static bool get overlayEnabled =>
      (_rt?.config.showOverlay ?? false) &&
      !isReplaying &&
      (_rt?.isRecording ?? false);

  static final ActionRegistry _actions = ActionRegistry();

  // ------------------------------------------------------------ monitoring

  /// Sends [error] as an error event (handled, level `error` unless given)
  /// with the current scope. Returns the event id, or null when monitoring is
  /// off or the event was sampled out.
  static String? captureException(
    Object error, {
    StackTrace? stackTrace,
    EventLevel? level,
    Map<String, String>? tags,
    Map<String, Object?>? extra,
    List<String>? fingerprint,
    Map<String, Object?>? contexts,
  }) {
    final hub = _rt?.hub;
    return hub?.capture(
      hub.prepareException(
        error,
        stackTrace ?? StackTrace.current,
        mechanism: Mechanism.manual,
        level: level,
        tags: tags,
        extra: extra,
        fingerprint: fingerprint,
        contexts: contexts,
      ),
    );
  }

  /// Sends a message event (with the current stack when `attachStacktrace`).
  static String? captureMessage(
    String message, {
    EventLevel level = EventLevel.info,
    Map<String, String>? tags,
  }) {
    final hub = _rt?.hub;
    return hub?.capture(hub.prepareMessage(message, level: level, tags: tags));
  }

  /// Sends user feedback (monitoring-v1 §9), linked to [eventId] when given.
  /// With [captureCapsule] (default: `MonitoringOptions.captureCapsuleWithFeedback`,
  /// true in QA mode) a capsule is written too and linked by `capsuleId`.
  /// Returns the feedback id, or null when monitoring is off or [message]
  /// is empty.
  static Future<String?> captureFeedback({
    required String message,
    String? name,
    String? email,
    String? eventId,
    String? url,
    Map<String, String>? tags,
    bool? captureCapsule,
  }) async => _rt?.hub?.captureFeedback(
    message: message,
    name: name,
    email: email,
    eventId: eventId,
    url: url,
    tags: tags,
    captureCapsule: captureCapsule,
  );

  /// Id of the last error event that was sent (not sampled out).
  static String? lastEventId() => _rt?.hub?.lastEventId;

  static void setUser(MonitoringUser? user) => Scope.current.setUser(user);
  static void setTag(String key, String value) =>
      Scope.current.setTag(key, value);
  static void setTags(Map<String, String> tags) => Scope.current.setTags(tags);
  static void setExtra(String key, Object? value) =>
      Scope.current.setExtra(key, value);
  static void setExtras(Map<String, Object?> extras) =>
      Scope.current.setExtras(extras);
  static void setContext(String name, Object? value) =>
      Scope.current.setContext(name, value);
  static void setLevel(EventLevel? level) => Scope.current.setLevel(level);
  static void setFingerprint(List<String>? fingerprint) =>
      Scope.current.setFingerprint(fingerprint);

  static void addBreadcrumb(Breadcrumb breadcrumb) =>
      _rt?.hub?.addBreadcrumb(breadcrumb);
  static void clearBreadcrumbs() => _rt?.hub?.clearBreadcrumbs();

  /// Runs [fn] with a copy of the current scope; changes to it apply only to
  /// what is captured inside [fn] (including its async continuations).
  static R withScope<R>(R Function(Scope scope) fn) {
    final scope = Scope.current.clone();
    return runZoned(() => fn(scope), zoneValues: {scopeZoneKey: scope});
  }

  static void configureScope(void Function(Scope scope) fn) =>
      fn(Scope.current);

  /// Starts a root transaction (a new trace, or the one passed to
  /// [continueTrace]). With [bindToScope] it becomes the parent of spans
  /// started outside [startSpan] (e.g. HTTP spans). Finish it to send it.
  static BugCapsuleTransaction startTransaction(
    String name,
    String op, {
    bool bindToScope = false,
  }) =>
      _rt?.hub?.startTransaction(name, op, bindToScope: bindToScope) ??
      TransactionImpl(name: name, op: op, sink: _noopSink, sampled: false);

  /// Runs [fn] inside a span that is active for its zone (children, HTTP
  /// spans and error events attach to it) and finishes it when [fn]
  /// completes (status `internal_error` if it throws). A child of the active
  /// span, else a new transaction.
  static FutureOr<R> startSpan<R>(
    String name,
    String op,
    FutureOr<R> Function(BugCapsuleSpan span) fn,
  ) {
    final parent = activeSpan;
    final BugCapsuleSpan span =
        parent?.startChild(op, description: name) ?? startTransaction(name, op);
    final FutureOr<R> result;
    try {
      result = runZoned(() => fn(span), zoneValues: {spanZoneKey: span});
    } catch (_) {
      span.finish(status: SpanStatus.internalError);
      rethrow;
    }
    if (result is Future<R>) return _finishAfter(result, span);
    span.finish();
    return result;
  }

  static Future<R> _finishAfter<R>(
    Future<R> future,
    BugCapsuleSpan span,
  ) async {
    try {
      final value = await future;
      span.finish();
      return value;
    } catch (_) {
      span.finish(status: SpanStatus.internalError);
      rethrow;
    }
  }

  /// The span of the current zone ([startSpan]), else the transaction bound
  /// to the scope (the current screen), if open.
  static BugCapsuleSpan? get activeSpan => Scope.current.activeSpan;

  /// `traceparent` for a request made by a custom client, or null when no
  /// span is active.
  static String? getTraceparent() => activeSpan?.toTraceparent();
  static String? getBaggage() => activeSpan?.toBaggage();

  /// Continues an incoming trace: the next root transaction uses its trace
  /// id, parent span and sampling decision.
  static void continueTrace(String? traceparent, String? baggage) {
    final parent = TraceParent.parse(traceparent);
    if (parent == null) return;
    final rate = double.tryParse(Baggage.parse(baggage)['sample_rate'] ?? '');
    Scope.current.continuedTrace = ContinuedTrace(
      parent.traceId,
      parent.parentSpanId,
      parent.sampled,
      sampleRate: rate,
    );
  }

  /// Sessions are automatic; these are for apps that manage them.
  static void startSession() => _rt?.hub?.startSession();
  static void endSession() => _rt?.hub?.endSession();

  /// Uploads queued monitoring envelopes. True when the queue is empty.
  static Future<bool> flush([
    Duration timeout = const Duration(seconds: 10),
  ]) async => await _rt?.hub?.flush(timeout: timeout) ?? true;

  /// Ends the session, uploads queued envelopes and stops monitoring.
  static Future<void> close() async => _rt?.closeMonitoring();

  /// `runZonedGuarded` that sends uncaught zone errors as `uncaught` events
  /// (and treats them as failures), then calls [onError]:
  ///
  /// ```dart
  /// void main() => BugCapsule.runZonedGuarded(() => BugCapsule.init(...));
  /// ```
  static R? runZonedGuarded<R>(
    R Function() body, {
    void Function(Object error, StackTrace stack)? onError,
  }) => async.runZonedGuarded(body, (error, stack) {
    _rt?.onUncaught(error, stack, Mechanism.uncaught);
    onError?.call(error, stack);
  });

  /// Sends uncaught errors of [isolate] (one the app spawned) as events.
  static void addIsolateErrorListener(Isolate isolate) =>
      _rt?.hub?.addIsolate(isolate);

  static final TransactionSink _noopSink = _NoopSink();

  /// The package of the first frame outside BugCapsule: the app's, which
  /// marks its frames `inApp`.
  static String? _callerPackage(StackTrace stack) {
    for (final line in stack.toString().split('\n')) {
      final m = RegExp(r'\(package:([^/]+)/').firstMatch(line);
      if (m != null &&
          m[1] != 'bug_capsule' &&
          m[1] != 'flutter' &&
          m[1] != 'clock') {
        return m[1];
      }
    }
    return null;
  }

  @visibleForTesting
  static Future<void> resetForTest() async {
    await _rt?.dispose();
    _rt = null;
    Scope.root.clear();
  }
}

class _NoopSink implements TransactionSink {
  @override
  String? get release => null;
  @override
  String? get environment => null;
  @override
  void transactionFinished(TransactionImpl transaction) {}
}

/// How [BugCapsuleConfig.token] and [BugCapsuleConfig.backend] resolve
/// (spec/connection-token-v1.md): an explicit backend wins; an unusable
/// token leaves no backend, so the app runs without BugCapsule instead of
/// failing.
typedef _Connection = ({
  BugCapsuleBackendConfig? backend,
  BugCapsuleConnectionSource? source,
  InvalidConnectionToken? tokenError,
});

_Connection _resolveConnection(BugCapsuleConfig config) {
  final backend = config.backend;
  final token = config.token;
  if (backend != null) {
    if (token != null && token.trim().isNotEmpty) {
      debugPrint(
        '[bugcapsule] both token and backend are set; using backend and ignoring token',
      );
    }
    return (
      backend: backend,
      source: BugCapsuleConnectionSource.backend,
      tokenError: null,
    );
  }
  if (token == null) return (backend: null, source: null, tokenError: null);
  switch (parseConnectionToken(token)) {
    case ValidConnectionToken(:final backend):
      return (
        backend: backend,
        source: BugCapsuleConnectionSource.token,
        tokenError: null,
      );
    case final InvalidConnectionToken error:
      debugPrint(
        "[bugcapsule] the SDK token can't be used (${error.error.code}): ${error.message}. "
        'The app runs without BugCapsule.',
      );
      return (
        backend: null,
        source: BugCapsuleConnectionSource.token,
        tokenError: error,
      );
  }
}

class _Runtime with WidgetsBindingObserver implements InteractionSession {
  _Runtime(this.config, this.integrations, this._overrides, this._appPackage)
    : _random = _overrides?.random ?? Random(),
      _connection = _resolveConnection(config);

  final _Connection _connection;

  /// From the token or the explicit backend config.
  BugCapsuleBackendConfig? get _backend => _connection.backend;

  DateTime? _firstEventAcceptedAt;
  DateTime? _firstCapsuleAcceptedAt;

  final String? _appPackage;

  /// Monitoring; null when off, before setup and during replay.
  MonitoringHub? hub;

  @override
  final BugCapsuleConfig config;
  final List<BugCapsuleIntegration> integrations;
  final BugCapsuleTestOverrides? _overrides;
  final Random _random;

  final Stopwatch _sw = Stopwatch()..start();
  final String _sessionId = uuidV4();
  final DateTime _startedAt = DateTime.now();
  late final int _seed = newSeed();
  late Random random = Random(_seed);

  FlightRecorder? _recorder;
  ReplayEngine? engine;

  /// The crash journal of this process while it records (crash-capsules §1).
  CrashJournal? _journal;
  Directory? _storageRoot;

  /// Journals of earlier processes already claimed by a fatal event.
  final Set<String> _claimedJournals = {};

  /// Names this process's journal: the process id, the same as the native
  /// pid (the Dart VM runs in the app's process on Android and iOS).
  final String _journalId = '$pid';

  @override
  final InteractionHost interactions = InteractionHost();

  /// Interaction adapters with unique dependency ids (a duplicate would
  /// make every capsule invalid; it is left out with a warning).
  late final List<InteractionIntegration> _interactionAdapters = () {
    final seen = <String>{};
    final out = <InteractionIntegration>[];
    for (final a in integrations.whereType<InteractionIntegration>()) {
      if (seen.add(a.dependencyId)) {
        out.add(a);
      } else {
        assert(
          false,
          'two interaction adapters use the dependency id "${a.dependencyId}"',
        );
        debugPrint(
          '[bugcapsule] ${a.adapter}: dependency id "${a.dependencyId}" is '
          'already used; give one of them an `id:` (it is not recorded)',
        );
      }
    }
    return out;
  }();
  Redactor _redactor = Redactor();
  bool _recording = false;
  bool _captureBodies = true;
  int _maxCapsuleBytes = 5 * 1024 * 1024;

  /// Probability that this production session records; only ever lowered.
  double _sessionRate = 1;

  /// Bumped whenever recording stops, so periodic checkpoints started
  /// before the decision are discarded.
  int _captureEpoch = 0;

  /// The kill switch fired: captures still being written are discarded.
  bool _killed = false;
  int? _anchorMs;
  int? _wallAtAnchorMs;
  Timer? _checkpointTimer;
  bool _checkpointBusy = false;
  FailureRecord? lastFailure;
  final Set<String> _capturedSignatures = {};
  final Set<String> _seenSignatures = {};
  int _capsulesWritten = 0;
  final Set<int> suppressedPointers = {};
  Future<CapsuleStore>? store;
  BugCapsuleTransport? _transport;
  UploadOutbox? _outbox;
  RemoteConfigController? remote;
  bool _observing = false;
  bool _pointerRouteInstalled = false;
  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object, StackTrace)? _previousPlatformError;
  bool _handlersInstalled = false;
  bool _disposed = false;
  final Set<String> _warned = {};

  /// Capture setup is given this long before the app starts without it.
  static const setupTimeout = Duration(seconds: 5);
  bool _setupAbandoned = false;

  @override
  CaptureMode get mode => config.mode;
  @override
  bool get isRecording => _recording;
  @override
  bool get isReplaying => engine != null;
  @override
  Redactor get redactor => _redactor;
  @override
  bool get captureNetworkBodies => _captureBodies;
  @override
  int get maxBodyBytes => config.maxBodyBytes;
  @override
  ReplayContext? get replay => engine;

  @override
  int now() => _sw.elapsedMilliseconds;

  DateTime wallClock() => engine?.now() ?? DateTime.now();

  void _warnOnce(String message) {
    if (_warned.add(message)) debugPrint('[bugcapsule] $message');
  }

  /// Records into the flight recorder while recording; monitoring derives
  /// breadcrumbs from the same (sanitized) events, also when this session
  /// does not record a capsule.
  @override
  void record(String type, [Map<String, Object?> data = const {}]) {
    final recorder = _recording ? _recorder : null;
    final hub = this.hub;
    final crumb = hub != null && BreadcrumbMapper.wants(type);
    if (recorder == null && !crumb) return;
    final clean = _sanitizeEvent(type, data);
    if (clean == null) return;
    if (crumb) _guard(() => hub.onRecorded(type, clean));
    recorder?.add(now(), type, clean);
  }

  /// Defense in depth: whatever an integration records goes through the
  /// redactor again (idempotent for already-redacted data), then the app's
  /// [BugCapsuleConfig.beforeRecord]. Pointer and lifecycle events carry only
  /// numbers and enum names and skip the walk.
  Map<String, Object?>? _sanitizeEvent(
    String type,
    Map<String, Object?> data, {
    bool hook = true,
  }) {
    try {
      var out = data;
      // An exchange that started before bodies were turned off finishes
      // after: its bodies must not be kept either.
      if (type == EventTypes.http && !_captureBodies) {
        out = _withoutBodies(
          BugCapsuleEvent(seq: 0, t: 0, type: type, data: out),
        ).data;
      }
      if (InteractionTypes.isInteraction(type)) {
        out = _redactInteraction(out);
      } else if (type != EventTypes.pointer && type != EventTypes.lifecycle) {
        out = (_redactor.redactJson(out) as Map).cast<String, Object?>();
        // Fields derived from already-redacted input stay byte-identical:
        // the request key must match what replay computes, and base64 bodies
        // are binary, not text.
        if (type == EventTypes.http) {
          for (final f in const ['key']) {
            if (data.containsKey(f)) out[f] = data[f];
          }
          if (out['bodyEncoding'] == 'base64') {
            out['responseBody'] = data['responseBody'];
          }
          if (out['requestEncoding'] == 'base64') {
            out['requestBody'] = data['requestBody'];
          }
        }
        if (type == EventTypes.failure && data['signature'] is String) {
          out['signature'] = data['signature'];
        }
      }
      final beforeRecord = config.beforeRecord;
      return beforeRecord == null || !hook ? out : beforeRecord(type, out);
    } catch (e) {
      _warnOnce('dropping a $type event: sanitizer failed ($e)');
      return null;
    }
  }

  /// Interaction events: payload objects hold typed values (bytes must
  /// stay base64, numbers keep their tags), so they are redacted with
  /// [TypedValue.redact]; a payload the current rules change is no longer
  /// replayable. Match keys were computed from redacted input and are kept.
  Map<String, Object?> _redactInteraction(Map<String, Object?> data) {
    final out = <String, Object?>{};
    for (final e in data.entries) {
      final v = e.value;
      if (e.key == 'key' || e.key == 'dep') {
        out[e.key] = v;
      } else if (InteractionTypes.payloadFields.contains(e.key) &&
          v is Map &&
          v.containsKey('mode')) {
        final payload = Map<String, Object?>.of(v.cast<String, Object?>());
        if (payload.containsKey('value')) {
          final (value, changed) = TypedValue.redact(
            payload['value'],
            _redactor,
          );
          payload['value'] = value;
          if (changed) {
            payload['mode'] = PayloadMode.redacted.name;
            payload['replayable'] = false;
          }
        }
        out[e.key] = payload;
      } else {
        out[e.key] = _redactor.redactJson(v);
      }
    }
    return out;
  }

  @override
  void reportError(Object error, StackTrace? stack) =>
      _onError(error, stack, Mechanism.manual);

  // ---------------------------------------------------------------- startup

  Future<void> start(FutureOr<void> Function() appRunner) async {
    // Platform channel capture wraps the default messenger before plugins
    // can use it, so the binding is created here.
    final binding = BugCapsuleBinding.ensureInitialized([
      for (final i in integrations.whereType<MessengerInterceptor>())
        if (i.interceptDefaultMessenger) i,
    ]);
    String? replayUrl;
    try {
      replayUrl =
          config.replayUrl ??
          await _replayUrlFromEnvironment(_overrides?.storageDirectory);
    } catch (e) {
      debugPrint('[bugcapsule] could not read replay request: $e');
    }
    if (replayUrl != null) {
      if (kReleaseMode) {
        debugPrint(
          '[bugcapsule] ignoring replay request: replay is disabled in release builds',
        );
      } else {
        debugPrint('[bugcapsule] replay mode: $replayUrl');
        await _startReplay(replayUrl, appRunner, binding);
        return;
      }
    }
    try {
      // A plugin or integration that never answers must not hold the app.
      await _prepareCapture(
        binding,
      ).timeout(_overrides?.setupTimeout ?? setupTimeout);
    } catch (e, st) {
      _setupAbandoned = true;
      debugPrint(
        '[bugcapsule] capture setup failed; the app runs without capture: $e\n$st',
      );
      _stopRecording();
      final h = hub;
      hub = null;
      unawaited(h?.dispose());
    }
    await appRunner();
    _afterAppStarted();
  }

  /// Replay requests come from (in order): the `BUGCAPSULE_REPLAY_URL`
  /// dart-define, the process environment, or a one-shot request file the
  /// CLI drops into the app's sandbox (`<support>/bugcapsule/replay_request.json`),
  /// which works on simulators where environment variables don't reach the app.
  static Future<String?> _replayUrlFromEnvironment(Directory? root) async {
    const fromDefine = String.fromEnvironment(ReplayProtocol.envUrl);
    if (fromDefine.isNotEmpty) return fromDefine;
    final fromEnv = Platform.environment[ReplayProtocol.envUrl];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    if (kReleaseMode) return null;
    try {
      final file = await CapsuleStore.replayRequestFile(root: root);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map;
      await file.delete();
      final createdAt = DateTime.tryParse('${json['createdAt']}');
      if (createdAt == null ||
          DateTime.now().difference(createdAt).inMinutes > 10) {
        return null;
      }
      return json['url'] as String?;
    } catch (e) {
      debugPrint('[bugcapsule] could not read replay request: $e');
      return null;
    }
  }

  /// Cache scope of the remote config: one per backend URL and ingest key,
  /// so a config fetched for staging never applies to production.
  static String _scope(BugCapsuleBackendConfig? backend) {
    final input = utf8.encode(
      '${backend?.url ?? ''}|${backend?.ingestKey ?? ''}',
    );
    var h = 0xcbf29ce484222325;
    for (final b in input) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toUnsigned(64).toRadixString(16);
  }

  Future<void> _prepareCapture(WidgetsBinding binding) async {
    _redactor = _baseRedactor();
    if (!config.enabled) return;

    // No backend (none configured, or an unusable token): capture still runs
    // locally, nothing is uploaded.
    final backend = _backend;
    final transport =
        _overrides?.transport ??
        (backend == null ? null : BugCapsuleBackendClient(backend));
    final storeFuture = store = CapsuleStore.open(
      root: _overrides?.storageDirectory,
    );
    final s = await storeFuture;
    _storageRoot = s.root;
    try {
      CrashJournals.reserve(s.root, _journalId);
      CrashJournals.sweep(
        s.root,
        olderThan: DateTime.now().subtract(CrashJournalLayout.maxAge),
      );
    } catch (e) {
      debugPrint('[bugcapsule] could not prepare crash journals: $e');
    }

    if (transport != null) {
      _transport = transport;
      _outbox = await UploadOutbox.open(
        s.outboxDirectory,
        limits: config.outboxLimits,
      );
      final controller = remote = RemoteConfigController(
        fetch: transport.fetchConfig,
        cache: s.configCache,
        scope: _scope(backend),
        onChange: _applyRemote,
        maxStale: config.maxStaleConfig,
        onRejected: (f) => debugPrint(
          "[bugcapsule] the backend refused this app's "
          "${_connection.source == BugCapsuleConnectionSource.token ? 'SDK token' : 'ingest key'} "
          "(${f.reason ?? 'HTTP ${f.status}'})${f.detail == null ? '' : ': ${f.detail}'}. "
          'Capture and uploads are off for this session.',
        ),
      );
      await controller.loadCached();
    }

    final cached = remote?.current;
    _redactor = _baseRedactor(remote: cached?.redactKeys ?? const []);
    _captureBodies =
        config.captureNetworkBodies && (cached?.captureNetworkBodies ?? true);
    _maxCapsuleBytes = cached?.maxCapsuleBytes ?? _maxCapsuleBytes;
    _applyInteractionPolicy(cached);
    _recording = _decideRecording(cached);
    if (_setupAbandoned) return _stopRecording();

    for (final integration in integrations) {
      try {
        await integration.setUp(this);
      } catch (e) {
        debugPrint('[bugcapsule] ${integration.name} setup failed: $e');
      }
    }

    if (_setupAbandoned) return _stopRecording();
    // Monitoring starts once capture setup has finished (a setup that never
    // finishes leaves the app without capture and without monitoring).
    final baseEnvelopes =
        _overrides?.envelopeTransport ??
        (transport is EnvelopeTransport
            ? transport as EnvelopeTransport
            : null);
    final envelopes = baseEnvelopes == null
        ? null
        : _ObservedEnvelopes(
            baseEnvelopes,
            () => _firstEventAcceptedAt ??= DateTime.now(),
          );
    if (config.monitoring.enabled && (cached?.enabled ?? true)) {
      final h = MonitoringHub(
        options: config.monitoring,
        host: MonitoringHost(
          config: config,
          redactor: () => _redactor,
          remote: () => remote?.current,
          uploadsAllowed: () => _uploadsAllowed,
          ensureFreshConfig: () => remote?.ensureFresh() ?? Future.value(),
          refreshConfig: () => remote?.refresh() ?? Future.value(),
          writeCapsule: (note, monitoring) async {
            String? queued;
            await writeCapsule(
              failure: lastFailure,
              labels: {'note': note, 'source': 'feedback'},
              monitoring: monitoring,
              onQueued: (id) => queued = id,
            );
            return queued;
          },
          isRecording: () => _recording,
          crashCapsule: _crashCapsule,
          journalId: () => _journal == null ? null : _journalId,
        ),
        sdkVersion: _sdkVersion,
        startedAt: _startedAt,
        storage: s.root,
        transport: envelopes,
        appPackage: _appPackage,
      );
      await h.start(lifecycle: binding.lifecycleState);
      if (_setupAbandoned) {
        await h.dispose();
        return _stopRecording();
      }
      hub = h;
    }
    // Journals no fatal event of an earlier run claimed go once those events
    // were handled (crash-capsules §1).
    final pending = hub?.nativePendingHandled ?? Future<void>.value();
    unawaited(
      pending.then((_) {
        try {
          CrashJournals.sweep(
            s.root,
            keep: CrashJournals.dirFor(s.root, _journalId),
          );
        } catch (_) {}
      }),
    );
    binding.addObserver(this);
    _observing = true;
    if (hub != null) _installErrorHandlers();
    if (_recording) {
      final launch = Checkpoint(
        kind: CheckpointKind.launch,
        t: now(),
        wallClockMs: DateTime.now().millisecondsSinceEpoch,
        afterSeq: 0,
        data: await _snapshot(CheckpointKind.launch),
      );
      if (_setupAbandoned) return _stopRecording();
      final recorder = _recorder = FlightRecorder(
        launch: launch,
        maxEvents: config.maxEvents,
        windowMs: config.window.inMilliseconds,
      );
      _startJournal(s.root, recorder);
      _installCapture();
    }

    binding.addPostFrameCallback((_) {
      _anchorMs = now();
      _wallAtAnchorMs = DateTime.now().millisecondsSinceEpoch;
      _refreshJournalHeader();
    });
  }

  // ---------------------------------------------------------- crash journal

  void _startJournal(Directory root, FlightRecorder recorder) {
    if (!config.crashJournal) return;
    try {
      final dir = CrashJournals.dirFor(root, _journalId);
      final maxBytes = 2 * _maxCapsuleBytes;
      _journal = CrashJournal.start(
        directory: dir,
        recorder: recorder,
        header: _journalHeader(recorder),
        sink: _overrides == null
            ? IsolateJournalSink.start(dir, maxBytes: maxBytes)
            : InlineJournalSink(JournalWriter(dir, maxBytes: maxBytes)),
      );
      hub?.onJournalChanged();
    } catch (e) {
      debugPrint('[bugcapsule] crash journal is off: $e');
    }
  }

  void _refreshJournalHeader() {
    final journal = _journal;
    final recorder = _recorder;
    if (journal == null || recorder == null) return;
    _guard(() => journal.updateHeader(_journalHeader(recorder)));
  }

  /// Every manifest field known now (crash-capsules §1), plus what the
  /// next launch needs to finish the capsule: the anchor, this process's
  /// integration gaps for either checkpoint kind and each interaction
  /// adapter's dependency entry.
  Map<String, Object?> _journalHeader(FlightRecorder recorder) {
    final templates = [
      for (final a in _interactionAdapters)
        ?_tryOr(
          () => a.dependency(
            RecordedWindow(
              checkpoint: recorder.launch,
              events: [
                BugCapsuleEvent(
                  seq: 1,
                  t: 0,
                  type: InteractionTypes.wsSend,
                  data: {'dep': a.dependencyId},
                ),
              ],
              droppedEvents: 0,
              hasGap: false,
            ),
          ),
          null,
        ),
    ];
    List<Map<String, Object?>> gaps(CheckpointKind kind) {
      final b = EligibilityBuilder();
      final window = RecordedWindow(
        checkpoint: Checkpoint(kind: kind, t: 0, wallClockMs: 0, afterSeq: 0),
        events: const [],
        droppedEvents: 0,
        hasGap: false,
      );
      for (final integration in integrations) {
        try {
          integration.describeEligibility(b, window);
        } catch (_) {}
      }
      return [for (final m in b.build().missing) m.toJson()];
    }

    final h = hub;
    return {
      'journal': CrashJournalLayout.version,
      'pid': pid,
      'processId': _journalId,
      'release': h?.release,
      'environment': h?.environment,
      'writtenAt': DateTime.now().toUtc().toIso8601String(),
      'anchorMs': _anchorMs,
      'mode': config.mode.name,
      'app': _appInfo().toJson(),
      'source': {'gitSha': config.gitSha, 'dirty': config.gitDirty},
      'sdk': {'name': _sdkName, 'version': _sdkVersion},
      'stateSchemaVersion': config.stateSchemaVersion,
      'platform': _platformInfo().toJson(),
      'session': {
        'id': _sessionId,
        'startedAt': _startedAt.toUtc().toIso8601String(),
        'wallClockAtAnchorMs': _wallAtAnchorMs,
        'seed': _seed,
      },
      'integrations': [for (final i in integrations) i.name],
      'redaction': {
        'extraKeys': _redactor.extraKeys,
        'extraHeaders': _redactor.extraHeaders,
      },
      'labels': _sanitizeLabels(config.labels),
      'runtime': _runtimeInfo().toJson(),
      'capabilities': _capabilities(templates),
      'dependencies': [for (final d in templates) d.toJson()],
      'eligibilityGaps': {
        for (final kind in CheckpointKind.values) kind.name: gaps(kind),
      },
      'rewriteDropped': recorder.rewriteDropped,
    };
  }

  /// The crash capsule of an earlier process's fatal [event], built from
  /// that process's journal and queued; completes with its id once queued.
  /// Null when nothing is tried (capture off, no journal for the event).
  /// Crash capsules do not count against `maxCapsulesPerSession`.
  Future<String?>? _crashCapsule(
    ErrorEvent event, {
    String? journalId,
    required bool lastRunCrashed,
  }) {
    final root = _storageRoot;
    final s = store;
    if (root == null ||
        s == null ||
        !config.enabled ||
        !config.crashJournal ||
        _killed ||
        remote?.current?.enabled == false) {
      return null;
    }
    final JournalInfo? journal;
    try {
      journal = CrashJournals.forCrash(
        [
          for (final j in CrashJournals.list(
            root,
            except: CrashJournals.dirFor(root, _journalId),
          ))
            if (!_claimedJournals.contains(j.dir.path)) j,
        ],
        crashedAt: event.timestamp,
        lastRunCrashed: lastRunCrashed,
        journalId: journalId,
      );
    } catch (e) {
      debugPrint('[bugcapsule] could not read crash journals: $e');
      return null;
    }
    if (journal == null) return null;
    _claimedJournals.add(journal.dir.path);
    final request = CrashCapsuleRequest(
      capsuleId: uuidV4(),
      createdAt: DateTime.now(),
      failure: CrashFailure.fromEvent(event),
      monitoring: CapsuleMonitoring(
        eventId: event.eventId,
        release: event.release,
        environment: event.environment,
      ),
      maxCapsuleBytes: _maxCapsuleBytes,
      crashedAt: event.timestamp,
    );
    return _queueCrashCapsule(journal.dir, request, storeFuture: s);
  }

  Future<String?> _queueCrashCapsule(
    Directory journal,
    CrashCapsuleRequest request, {
    required Future<CapsuleStore> storeFuture,
  }) async {
    try {
      final build = await (_overrides == null
          ? _buildInBackground(journal.path, request)
          : Future.sync(() => _buildFromJournal(journal.path, request)));
      if (build == null || _killed) return null;
      final id = request.capsuleId;
      final s = await storeFuture;
      await s.save(id, build.bytes);
      final outbox = _outbox;
      if (outbox == null || !await outbox.enqueue(id, build.bytes)) {
        return null;
      }
      if (_killed) {
        await outbox.purge();
        return null;
      }
      debugPrint(
        '[bugcapsule] crash capsule $id (${build.eligibility.status.name}) '
        'from the journal of an earlier process',
      );
      unawaited(flushOutbox(onlyId: id));
      return id;
    } catch (e) {
      debugPrint('[bugcapsule] crash capsule failed: $e');
      return null;
    } finally {
      // The journal goes once the capsule is in the outbox (or cannot be).
      try {
        if (journal.existsSync()) journal.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  void _afterAppStarted() {
    if (_disposed || remote == null) return;
    unawaited(
      remote!
          .refresh()
          .then((_) => flushOutbox())
          .then(
            (_) {},
            onError: (Object e) {
              debugPrint('[bugcapsule] startup sync failed: $e');
            },
          ),
    );
  }

  Redactor _baseRedactor({List<String> remote = const []}) => Redactor(
    extraKeys: [...config.redactKeys, ...remote],
    extraHeaders: config.redactHeaders,
    patterns: config.redactPatterns,
  );

  double _effectiveRate(RemoteCaptureConfig? remote) {
    final cap = config.productionSampleRate.clamp(0.0, 1.0);
    final remoteRate = remote?.sampleRate ?? 1.0;
    return remoteRate < cap ? remoteRate : cap;
  }

  /// Startup decision. A cached kill switch applies however old it is; with
  /// no cached config the app's own settings decide (uploads still wait for
  /// a successful fetch). Production sessions are sampled at the lower of
  /// the app's cap and the remote rate.
  bool _decideRecording(RemoteCaptureConfig? remote) {
    if (!config.enabled) return false;
    if (remote != null && !remote.enabled) return false;
    if (config.mode != CaptureMode.production) return true;
    _sessionRate = _effectiveRate(remote);
    return _random.nextDouble() < _sessionRate;
  }

  void _installCapture() {
    _installErrorHandlers();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _pointerRouteInstalled = true;
    _checkpointTimer = Timer.periodic(
      config.checkpointInterval,
      (_) => _periodicCheckpoint(),
    );
  }

  void _installErrorHandlers() {
    if (_handlersInstalled) return;
    _handlersInstalled = true;
    final previousFlutterError = _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.silent) {
        _guard(
          () => _onError(
            details.exception,
            details.stack,
            Mechanism(
              'flutter_error',
              handled: false,
              data: {
                'library': ?details.library,
                if (details.context != null)
                  'context': details.context.toString(),
              },
            ),
          ),
        );
      }
      previousFlutterError?.call(details);
    };
    final previousPlatformError = _previousPlatformError =
        PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _guard(() => _onError(error, stack, Mechanism.platformDispatcher));
      return previousPlatformError?.call(error, stack) ?? isReplaying;
    };
  }

  /// SDK work triggered from the app's own callbacks must never throw into
  /// them.
  void _guard(void Function() fn) {
    try {
      fn();
    } catch (e) {
      _warnOnce('internal error ignored: $e');
    }
  }

  Future<Map<String, Object?>> _snapshot(CheckpointKind kind) async {
    final data = <String, Object?>{};
    for (final integration in integrations) {
      try {
        final value = await integration.snapshot(kind);
        if (value == null) continue;
        Object? clean = _redactor.redactJson(value);
        final hook = config.beforeCheckpoint;
        if (hook != null) clean = hook(integration.name, clean);
        if (clean != null) data[integration.name] = clean;
      } catch (e) {
        debugPrint('[bugcapsule] ${integration.name} snapshot failed: $e');
      }
    }
    return data;
  }

  Future<void> _periodicCheckpoint() async {
    final recorder = _recorder;
    if (!_recording || recorder == null || _checkpointBusy) return;
    _checkpointBusy = true;
    final epoch = _captureEpoch;
    try {
      final t = now();
      final afterSeq = recorder.lastSeq;
      final data = await _snapshot(CheckpointKind.periodic);
      final open = _openInteractions();
      if (open.isNotEmpty) data['interactions'] = {'open': open};
      if (epoch != _captureEpoch || !identical(recorder, _recorder)) return;
      recorder.addCheckpoint(
        Checkpoint(
          kind: CheckpointKind.periodic,
          t: t,
          wallClockMs: DateTime.now().millisecondsSinceEpoch,
          afterSeq: afterSeq,
          data: data,
        ),
      );
      _refreshJournalHeader();
    } catch (e) {
      _warnOnce('periodic checkpoint failed: $e');
    } finally {
      _checkpointBusy = false;
    }
  }

  /// Connections and subscriptions open now (capsule-v2 §6).
  List<Map<String, Object?>> _openInteractions() => [
    for (final a in _interactionAdapters)
      for (final o in _tryOr<List<Map<String, Object?>>>(
        a.openInteractions,
        const [],
      ))
        {'dep': a.dependencyId, ...o},
  ];

  static T _tryOr<T>(T Function() fn, T fallback) {
    try {
      return fn();
    } catch (_) {
      return fallback;
    }
  }

  // ------------------------------------------------------------- recording

  void _onPointer(PointerEvent event) {
    if (!_recording) return;
    _guard(() {
      final pointer = event.pointer;
      if (suppressedPointers.contains(pointer)) {
        if (event is PointerUpEvent || event is PointerCancelEvent) {
          suppressedPointers.remove(pointer);
        }
        return;
      }
      final phase = switch (event) {
        PointerDownEvent() => 'down',
        PointerMoveEvent() => 'move',
        PointerUpEvent() => 'up',
        PointerCancelEvent() => 'cancel',
        _ => null,
      };
      if (phase == null) return;
      record(EventTypes.pointer, {
        'phase': phase,
        'pointer': pointer,
        'x': double.parse(event.position.dx.toStringAsFixed(2)),
        'y': double.parse(event.position.dy.toStringAsFixed(2)),
        'kind': event.kind.name,
        if (event.buttons != kPrimaryButton) 'buttons': event.buttons,
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _guard(() => record(EventTypes.lifecycle, {'state': state.name}));
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Going to the background: the system may kill the process.
      _refreshJournalHeader();
      _guard(() => _journal?.flush());
    }
    _guard(() => hub?.onLifecycle(state));
    final controller = remote;
    if (controller == null) return;
    if (state == AppLifecycleState.resumed) {
      controller.onResumed();
      unawaited(flushOutbox());
    } else if (state == AppLifecycleState.paused) {
      controller.onPaused();
    }
  }

  /// Errors already sent as events, so one error reaching several handlers
  /// (an integration's `reportError`, then the zone or PlatformDispatcher)
  /// is sent once.
  final Expando<bool> _reported = Expando();

  /// An uncaught zone error (`BugCapsule.runZonedGuarded`).
  void onUncaught(Object error, StackTrace stack, Mechanism mechanism) =>
      _guard(() => _onError(error, stack, mechanism));

  void _onError(Object error, StackTrace? stack, Mechanism mechanism) {
    if (config.ignoreError?.call(error) ?? false) return;
    var h = engine == null ? hub : null;
    if (h != null && _canExpando(error)) {
      if (_reported[error] == true) h = null;
      _reported[error] = true;
    }
    final prepared = h?.prepareException(error, stack, mechanism: mechanism);
    final capsule = handleFailure(
      FailureRecord.exception(error, stack, now(), scrub: _redactor.scrubText),
      monitoring: prepared?.monitoringInfo(),
    );
    if (prepared != null) h!.submit(prepared, capsule: capsule);
  }

  static bool _canExpando(Object o) =>
      o is! num && o is! String && o is! bool && o is! Record;

  /// Records the failure and, when it is new and capture is on, schedules
  /// a capsule. Returns the capsule id once the capsule is queued for upload
  /// (null if it is not written or not queued), or null when none is
  /// scheduled. [monitoring] goes into `manifest.monitoring`.
  Future<String?>? handleFailure(
    FailureRecord failure, {
    CapsuleMonitoring? monitoring,
  }) {
    final replaying = engine;
    if (replaying != null) {
      replaying.onFailure(failure);
      return null;
    }
    if (!_recording) return null;
    record(EventTypes.failure, failure.toJson()..remove('stack'));
    lastFailure = failure;
    _guard(() => _journal?.flush());
    if (!_seenSignatures.add(failure.signature)) return null;
    if (!config.autoCaptureOnFailure) return null;
    if (_capsulesWritten >= config.maxCapsulesPerSession) return null;
    if (!_capturedSignatures.add(failure.signature)) return null;
    final queued = Completer<String?>();
    // Let the failure settle (error widgets, follow-up events) before writing.
    Timer(const Duration(milliseconds: 300), () {
      unawaited(
        writeCapsule(
              failure: failure,
              monitoring: monitoring,
              onQueued: (id) {
                if (!queued.isCompleted) queued.complete(id);
              },
            )
            .then((r) {
              if (r != null) {
                debugPrint(
                  '[bugcapsule] captured ${r.capsuleId} '
                  '(${r.eligibility.status.name}) → ${r.file.path}',
                );
              }
            })
            .catchError(
              (Object e) => debugPrint('[bugcapsule] capture failed: $e'),
            )
            .whenComplete(() {
              if (!queued.isCompleted) queued.complete(null);
            }),
      );
    });
    return queued.future;
  }

  // --------------------------------------------------------------- capsule

  /// [onQueued] is called with the capsule id once it is in the upload
  /// outbox (before the upload), so a monitoring event can link to it.
  Future<CaptureResult?> writeCapsule({
    FailureRecord? failure,
    Map<String, String> labels = const {},
    CapsuleMonitoring? monitoring,
    void Function(String capsuleId)? onQueued,
  }) async {
    final recorder = _recorder;
    if (!_recording || recorder == null) return null;
    _capsulesWritten++;
    final window = recorder.window();
    final anchor = _anchorMs ?? now();
    final wallAtAnchor =
        _wallAtAnchorMs ??
        (window.checkpoint.wallClockMs + anchor - window.checkpoint.t);

    final eligibility = EligibilityBuilder();
    if (config.gitSha == null) {
      eligibility.missing(
        'build.gitSha',
        'BUGCAPSULE_GIT_SHA was not set at build time',
      );
    } else if (config.gitDirty == true) {
      eligibility.missing(
        'build.gitSha',
        'built from a tree with uncommitted changes',
      );
    }
    if (failure == null) {
      eligibility.missing(
        'failure.assertion',
        'manual capture without a failure assertion',
        blocking: true,
      );
    }
    if (recorder.rewriteDropped > 0) {
      eligibility.missing(
        'events.redaction',
        '${recorder.rewriteDropped} buffered events were dropped when redaction rules changed',
      );
    }
    if (window.hasGap) {
      eligibility.missing(
        'events.window',
        'events between the checkpoint and the window were evicted; raise window or maxEvents',
      );
    }
    final dependencies = [
      for (final a in _interactionAdapters)
        ?_tryOr(() => a.dependency(window), null),
    ];
    final open = window.checkpoint.kind == CheckpointKind.periodic
        ? window.checkpoint.data['interactions']
        : null;
    final openList = open is Map ? open['open'] : null;
    if (openList is List &&
        openList.any((o) => o is Map && o['restorable'] != true)) {
      eligibility.missing(
        'interactions.restore',
        '${openList.length} connections or subscriptions were open at the '
            'periodic checkpoint and cannot be restored',
        blocking: true,
      );
    }
    for (final integration in integrations) {
      try {
        integration.describeEligibility(eligibility, window);
      } catch (e) {
        eligibility.missing(
          'integration.${integration.name}',
          'eligibility check failed: $e',
        );
      }
    }

    final events = rebaseOccurrences([
      for (final e in window.events)
        if (!InteractionTypes.isInteraction(e.type) ||
            _interactionAdapters.any((a) => a.dependencyId == e.data['dep']))
          e.shift(anchor),
    ]);
    final capsule = Capsule(
      manifest: CapsuleManifest(
        capsuleId: uuidV4(),
        createdAt: DateTime.now(),
        mode: config.mode,
        app: _appInfo(),
        gitSha: config.gitSha,
        dirty: config.gitDirty,
        sdkName: _sdkName,
        sdkVersion: _sdkVersion,
        stateSchemaVersion: config.stateSchemaVersion,
        platform: _platformInfo(),
        session: SessionInfo(
          id: _sessionId,
          startedAt: _startedAt,
          wallClockAtAnchorMs: wallAtAnchor,
          seed: _seed,
          durationMs: now() - anchor,
        ),
        failure: failure?.shift(anchor),
        eligibility: eligibility.build(),
        integrations: [for (final i in integrations) i.name],
        eventCount: events.length,
        droppedEvents: window.droppedEvents,
        checkpointKind: window.checkpoint.kind,
        labels: _sanitizeLabels({...config.labels, ...labels}),
        redactionKeys: _redactor.extraKeys,
        redactionHeaders: _redactor.extraHeaders,
        runtime: _runtimeInfo(),
        capabilities: _capabilities(dependencies),
        monitoring: monitoring,
        dependencies: dependencies,
      ),
      checkpoint: window.checkpoint.shift(anchor),
      events: events,
    );

    // Never queue what a reader would reject; keep it locally for inspection.
    final problem = validateCapsuleDocument(CapsuleCodec.toJson(capsule));
    final bytes =
        await (_overrides?.encodeCapsule?.call(capsule) ??
            compute(_encodeCapsule, capsule));
    // The kill switch fired while encoding: drop the capsule.
    if (_killed) return null;
    final s = await store!;
    final file = await s.save(capsule.manifest.capsuleId, bytes);
    if (_killed) {
      await s.clearSavedCaptures();
      return null;
    }

    UploadResult? upload;
    final outbox = _outbox;
    if (problem != null) {
      debugPrint(
        '[bugcapsule] capsule ${capsule.manifest.capsuleId} failed validation, not uploaded: $problem',
      );
      if (outbox != null) {
        upload = UploadResult(
          UploadStatus.rejected,
          message: 'invalid capsule: $problem',
        );
      }
    } else if (outbox != null) {
      if (bytes.length > _maxCapsuleBytes) {
        upload = UploadResult(
          UploadStatus.rejected,
          message: 'capsule is ${bytes.length} bytes, limit $_maxCapsuleBytes',
        );
      } else if (!await outbox.enqueue(capsule.manifest.capsuleId, bytes)) {
        upload = const UploadResult(
          UploadStatus.rejected,
          message: 'not queued (outbox limit or disk error)',
        );
      } else if (_killed) {
        await outbox.purge();
        return null;
      } else {
        onQueued?.call(capsule.manifest.capsuleId);
        upload = await flushOutbox(onlyId: capsule.manifest.capsuleId);
      }
    }
    return CaptureResult(
      capsuleId: capsule.manifest.capsuleId,
      file: file,
      eligibility: capsule.manifest.eligibility,
      failureSignature: failure?.signature,
      upload: upload,
    );
  }

  AppInfo _appInfo() => AppInfo(
    id: _cutOrNull(config.appId, 200),
    name: _cutOrNull(config.appName, 200),
    version: _cut(config.appVersion, 200),
    build: _cut(config.appBuild, 200),
    flavor: _cutOrNull(config.flavor, 200),
  );

  PlatformInfo _platformInfo() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final logical = view.physicalSize / view.devicePixelRatio;
    return PlatformInfo(
      os: Platform.operatingSystem,
      osVersion: _osVersion(),
      locale: Platform.localeName,
      screenWidth: logical.width,
      screenHeight: logical.height,
      pixelRatio: view.devicePixelRatio,
      dartVersion: Platform.version.split(' ').first,
    );
  }

  static RuntimeInfo _runtimeInfo() => RuntimeInfo(
    name: 'flutter',
    version: Platform.version.split(' ').first,
    language: 'dart',
    frameworks: const ['flutter'],
  );

  Map<String, String> _capabilities(List<CapsuleDependency> dependencies) => {
    'input.pointer.capture': 'supported',
    'input.pointer.replay': 'supported',
    'input.semantic.replay': 'supported',
    'text.replay': 'supported',
    'lifecycle.replay': 'supported',
    'errors.uncaught': 'supported',
    'clock.virtual': 'explicit',
    'random.seeded': 'explicit',
    for (final i in integrations) 'integration.${i.name}': 'supported',
    for (final d in dependencies)
      'interaction.${d.adapter}': d.required ? 'supported' : 'partial',
  };

  /// Redacted and cut to the capsule format's bounds (100 labels, 100-char
  /// keys, 2,000-char values), so a long QA note never invalidates a capsule.
  Map<String, String> _sanitizeLabels(Map<String, String> labels) => {
    for (final e in labels.entries.take(100))
      _cut(e.key, 100): _redactor.isSensitiveKey(e.key)
          ? Redactor.placeholder
          : _cut(_redactor.scrubText(e.value), 2000),
  };

  static String _cut(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);
  static String? _cutOrNull(String? s, int max) =>
      s == null ? null : _cut(s, max);

  bool get _uploadsAllowed => !_disposed && (remote?.uploadsAllowed ?? false);

  /// Uploads pending capsules; returns the result for [onlyId] if given.
  /// The remote config is refreshed first when it is older than its TTL, so
  /// a kill switch set since the last fetch is seen before anything is sent.
  Future<UploadResult?> flushOutbox({String? onlyId}) async {
    final outbox = _outbox;
    final transport = _transport;
    final controller = remote;
    if (outbox == null ||
        transport == null ||
        controller == null ||
        _disposed) {
      return null;
    }
    try {
      await controller.ensureFresh();
      if (!_uploadsAllowed) {
        return onlyId == null
            ? null
            : const UploadResult(
                UploadStatus.retryLater,
                message: 'waiting for remote config',
              );
      }
      return await outbox.flush(
        upload: (bytes) async {
          final result = await transport.upload(bytes);
          if (result.status == UploadStatus.uploaded) {
            _firstCapsuleAcceptedAt ??= DateTime.now();
          }
          // A refused credential: the config fetch learns why and stops.
          if (result.message == 'capture_disabled' || result.unauthorized) {
            unawaited(controller.refresh());
          }
          return result;
        },
        allowed: () => _uploadsAllowed,
        onlyId: onlyId,
      );
    } catch (e) {
      debugPrint('[bugcapsule] outbox flush failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------- remote config

  /// Applies a freshly fetched config to the running session:
  /// * kill switch: stop recording, drop the buffer, delete queued and saved
  ///   captures; a later re-enable takes effect at the next launch;
  /// * bodies off: stop capturing bodies and strip those already buffered;
  /// * redaction keys: re-redact the buffer with the new rules;
  /// * sample rate (production): a lower rate keeps this session with
  ///   probability new/old, so the share of recording sessions matches the
  ///   new rate; a higher rate applies from the next launch. Never above the
  ///   app's `productionSampleRate`;
  /// * `maxCapsuleBytes`: applies to the next capsule.
  void _applyRemote(RemoteCaptureConfig? previous, RemoteCaptureConfig next) {
    if (next.maxCapsuleBytes != _maxCapsuleBytes) {
      _journal?.maxBytes = 2 * next.maxCapsuleBytes;
    }
    _maxCapsuleBytes = next.maxCapsuleBytes;
    _applyInteractionPolicy(next);
    _guard(() => hub?.onRemoteConfig(next));
    if (!next.enabled) {
      _disableCapture();
      return;
    }
    // Cheapest and most important first: sampling, then bodies, then
    // re-redaction (which may fail on odd data without undoing the others).
    if (config.mode == CaptureMode.production && _recording) {
      final rate = _effectiveRate(next);
      if (rate < _sessionRate) {
        final keep = _sessionRate <= 0 ? 0.0 : rate / _sessionRate;
        _sessionRate = rate;
        if (_random.nextDouble() >= keep) {
          debugPrint(
            '[bugcapsule] sample rate lowered to $rate; this session stops recording',
          );
          _stopRecording();
        }
      }
    }
    final bodies = config.captureNetworkBodies && next.captureNetworkBodies;
    if (_captureBodies && !bodies) {
      _recorder?.rewrite(
        event: (e) => e.type == EventTypes.http ? _withoutBodies(e) : e,
      );
    }
    _captureBodies = bodies;
    if (!listEquals(_redactor.extraKeys, [
      ...config.redactKeys,
      ...next.redactKeys,
    ])) {
      _redactor = _baseRedactor(remote: next.redactKeys);
      final recorder = _recorder;
      try {
        recorder?.rewrite(
          // Request keys were computed with the old rules and can embed
          // values the new rules redact; replay could not match them either.
          // Buffered exchanges are dropped (the capsule reports it), the rest
          // is redacted again. Events that cannot be are dropped too.
          event: (e) {
            if (e.type == EventTypes.http ||
                InteractionTypes.isInteraction(e.type)) {
              return null;
            }
            final data = _sanitizeEvent(e.type, e.data, hook: false);
            return data == null
                ? null
                : BugCapsuleEvent(seq: e.seq, t: e.t, type: e.type, data: data);
          },
          checkpoint: (c) => Checkpoint(
            kind: c.kind,
            t: c.t,
            wallClockMs: c.wallClockMs,
            afterSeq: c.afterSeq,
            data: (_redactor.redactJson(c.data) as Map).cast<String, Object?>(),
          ),
        );
      } catch (e) {
        // A buffer that cannot be re-redacted must not be uploaded.
        debugPrint(
          '[bugcapsule] could not apply new redaction rules to the buffer ($e); dropping it',
        );
        _stopRecording();
      }
    }
  }

  /// Interaction adapters (capsule-v2 §7): per-adapter kill switch and
  /// payload limits no higher than the body limit and remote policy.
  void _applyInteractionPolicy(RemoteCaptureConfig? remote) {
    final disabled = {...?remote?.disabledAdapters};
    final newly = disabled.difference(interactions.disabledAdapters);
    // What a now-disabled adapter already buffered is dropped too (the
    // adapter may have been turned off for the data it records).
    final dropped = {
      for (final a in _interactionAdapters)
        if (newly.contains(a.adapter)) a.dependencyId,
    };
    if (dropped.isNotEmpty) {
      _recorder?.rewrite(
        event: (e) =>
            InteractionTypes.isInteraction(e.type) &&
                dropped.contains(e.data['dep'])
            ? null
            : e,
      );
    }
    interactions
      ..disabledAdapters = disabled
      ..limits = const InteractionLimits().lowered(
        maxPayloadBytes: remote?.maxInteractionPayloadBytes == null
            ? config.maxBodyBytes
            : min(config.maxBodyBytes, remote!.maxInteractionPayloadBytes!),
      );
  }

  static BugCapsuleEvent _withoutBodies(BugCapsuleEvent e) {
    final d = Map<String, Object?>.of(e.data);
    d['requestBody'] = null;
    d['responseBody'] = null;
    d['bodyEncoding'] = 'omitted';
    if (d['requestEncoding'] != null && d['requestEncoding'] != 'json') {
      d['requestEncoding'] = 'omitted';
    }
    return BugCapsuleEvent(seq: e.seq, t: e.t, type: e.type, data: d);
  }

  void _stopRecording() {
    _captureEpoch++;
    _recording = false;
    _recorder = null;
    final journal = _journal;
    _journal = null;
    if (journal != null) {
      unawaited(journal.discard());
      _guard(() => hub?.onJournalChanged());
    }
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
  }

  /// Kill switch: stop recording, drop the buffer, and delete everything
  /// captured but not yet uploaded. An upload already on the wire finishes
  /// (the backend rejects it while capture is disabled there).
  void _disableCapture() {
    final wasRecording = _recording;
    _killed = true;
    _stopRecording();
    // A refused credential was already explained in one line.
    if (wasRecording && !(remote?.rejected ?? false)) {
      debugPrint('[bugcapsule] capture disabled by remote config');
    }
    final outbox = _outbox;
    if (outbox != null) {
      unawaited(outbox.purge().then((_) {}, onError: (Object _) {}));
    }
    final s = store;
    if (s != null) {
      unawaited(
        s
            .then((s) => s.clearSavedCaptures())
            .then((_) {}, onError: (Object _) {}),
      );
    }
    // Journals are captured data too.
    final root = _storageRoot;
    if (root != null) {
      unawaited(
        Future(
          () => CrashJournals.sweep(root),
        ).then((_) {}, onError: (Object _) {}),
      );
    }
  }

  // ---------------------------------------------------------------- replay

  Future<void> _startReplay(
    String url,
    FutureOr<void> Function() appRunner,
    WidgetsBinding binding,
  ) async {
    final channel = ReplayChannel(url);
    final Capsule capsule;
    final ReplaySettings settings;
    try {
      (capsule, settings) = await channel.fetch();
    } catch (e) {
      await channel.report(
        ReplayReport(
          outcome: e is CapsuleFormatException
              ? ReplayOutcome.incompatible
              : ReplayOutcome.error,
          attempt: 1,
          durationMs: 0,
          strategy: ReplayStrategy.auto,
          message: 'could not load capsule: $e',
        ),
      );
      await appRunner();
      return;
    }

    final replay = engine = ReplayEngine(
      capsule: capsule,
      settings: settings,
      actions: BugCapsule._actions,
      buildGitSha: config.gitSha,
    );
    random = Random(capsule.manifest.session.seed);
    // The capture's redaction rules, so request keys of redacted bodies match.
    _redactor = Redactor(
      extraKeys: {...config.redactKeys, ...capsule.manifest.redactionKeys},
      extraHeaders: {
        ...config.redactHeaders,
        ...capsule.manifest.redactionHeaders,
      },
      patterns: config.redactPatterns,
    );

    if (capsule.manifest.stateSchemaVersion != config.stateSchemaVersion &&
        capsule.checkpoint.kind == CheckpointKind.periodic) {
      await channel.report(
        ReplayReport(
          outcome: ReplayOutcome.incompatible,
          attempt: settings.attempt,
          durationMs: 0,
          strategy: settings.strategy,
          expectedSignature: capsule.manifest.failure?.signature,
          message:
              'state schema v${capsule.manifest.stateSchemaVersion} captured, '
              'app is v${config.stateSchemaVersion}; register a migration or mark the capsule stale',
        ),
      );
      engine = null;
      await appRunner();
      return;
    }
    replay.precheck();
    interactions.replay = replay.interactions;
    final blocked = replay.preflight(_interactionAdapters);
    if (blocked != null) {
      await channel.report(
        ReplayReport(
          outcome: ReplayOutcome.incompatible,
          attempt: settings.attempt,
          durationMs: 0,
          strategy: settings.strategy,
          expectedSignature: capsule.manifest.failure?.signature,
          message: blocked,
          attemptId: settings.attemptId,
          runtime: 'flutter',
        ),
      );
      engine = null;
      interactions.replay = null;
      await appRunner();
      return;
    }

    _installErrorHandlers();

    final names = {for (final i in integrations) i.name};
    for (final name in capsule.manifest.integrations) {
      if (!names.contains(name)) {
        replay.diverge(
          'integration.missing',
          '$name was used when capturing but is not set up',
        );
      }
    }
    for (final integration in integrations) {
      try {
        await integration.setUp(this);
      } catch (e) {
        replay.diverge('restore.${integration.name}', 'setup failed: $e');
      }
    }
    for (final name in capsule.checkpoint.data.keys) {
      if (!names.contains(name)) {
        replay.diverge('restore.missingIntegration', name);
      }
    }
    for (final integration in integrations) {
      final data = capsule.checkpoint.data[integration.name];
      try {
        await integration.restore(data, this);
      } catch (e) {
        replay.diverge('restore.${integration.name}', '$e');
      }
    }

    binding.addPostFrameCallback((_) {
      unawaited(
        replay.run().then(channel.report).catchError((Object e, StackTrace st) {
          return channel.report(
            ReplayReport(
              outcome: ReplayOutcome.error,
              attempt: settings.attempt,
              durationMs: 0,
              strategy: settings.strategy,
              expectedSignature: capsule.manifest.failure?.signature,
              message: 'replay crashed: $e',
            ),
          );
        }),
      );
    });
    await appRunner();
  }

  /// "Version 27.0 (Build 24A434)" -> "27.0 (24A434)".
  static String _osVersion() {
    final raw = Platform.operatingSystemVersion;
    final version = RegExp(r'\d+(\.\d+)+').firstMatch(raw)?.group(0);
    final build = RegExp(r'Build ([^)\s]+)').firstMatch(raw)?.group(1);
    if (version == null) return raw;
    return build == null ? version : '$version ($build)';
  }

  // ---------------------------------------------------------------- status

  static const _networkIntegrations = {'dio', 'http'};
  static const _navigationIntegrations = {'go_router'};
  static const _stateIntegrations = {
    'bloc',
    'riverpod',
    'notifier',
    'getx',
    'mobx',
    'shared_preferences',
  };

  static const statusBeforeInit = BugCapsuleStatus(
    connection: BugCapsuleConnectionStatus(
      state: BugCapsuleConnectionState.notConfigured,
    ),
    instrumentation: BugCapsuleInstrumentationStatus(
      recording: false,
      network: false,
      navigation: false,
      appState: false,
      integrations: [],
      missing: ['network', 'navigation', 'app_state'],
    ),
  );

  BugCapsuleStatus get status {
    final controller = remote;
    final failure = controller?.lastFailure;
    final tokenError = _connection.tokenError;
    final current = controller?.current;
    final state = switch (tokenError?.error) {
      ConnectionTokenError.invalidToken =>
        BugCapsuleConnectionState.invalidToken,
      ConnectionTokenError.unsupportedTokenVersion =>
        BugCapsuleConnectionState.unsupportedTokenVersion,
      null when _backend == null && _overrides?.transport == null =>
        BugCapsuleConnectionState.notConfigured,
      null when !config.enabled => BugCapsuleConnectionState.disabled,
      null when controller?.rejected ?? false =>
        BugCapsuleConnectionState.rejected,
      null when current != null && !current.enabled =>
        BugCapsuleConnectionState.disabled,
      null when controller?.fetchedThisSession != null =>
        BugCapsuleConnectionState.connected,
      null when failure != null && failure.transient =>
        BugCapsuleConnectionState.offline,
      null => BugCapsuleConnectionState.connecting,
    };
    final names = [for (final i in integrations) i.name];
    final network = names.any(_networkIntegrations.contains);
    final navigation = names.any(_navigationIntegrations.contains);
    final appState =
        names.any(_stateIntegrations.contains) ||
        integrations.any((i) => i is TrackedStateIntegration);
    return BugCapsuleStatus(
      connection: BugCapsuleConnectionStatus(
        state: state,
        source: _connection.source,
        apiUrl: _backend?.url.replaceAll(RegExp(r'/+$'), ''),
        reason:
            tokenError?.error.code ??
            switch (state) {
              BugCapsuleConnectionState.rejected =>
                failure?.reason ?? failure?.message,
              BugCapsuleConnectionState.offline =>
                failure?.reason ?? failure?.message,
              _ => null,
            },
        message:
            tokenError?.message ??
            switch (state) {
              BugCapsuleConnectionState.rejected =>
                failure?.detail ?? 'the backend refused the credential',
              BugCapsuleConnectionState.offline =>
                'the backend could not be reached; data is kept and retried',
              _ => null,
            },
        configFetchedAt: controller?.fetchedThisSession,
        firstEventAcceptedAt: _firstEventAcceptedAt,
        firstCapsuleAcceptedAt: _firstCapsuleAcceptedAt,
      ),
      instrumentation: BugCapsuleInstrumentationStatus(
        recording: _recording,
        network: network,
        navigation: navigation,
        appState: appState,
        integrations: List.unmodifiable(names),
        missing: List.unmodifiable([
          if (!network) 'network',
          if (!navigation) 'navigation',
          if (!appState) 'app_state',
        ]),
      ),
    );
  }

  Future<void> closeMonitoring() async {
    final h = hub;
    hub = null;
    await h?.close();
  }

  Future<void> dispose() async {
    _disposed = true;
    final h = hub;
    hub = null;
    // Disposing is not a crash, but the journal stays like at a normal exit.
    final journal = _journal;
    _journal = null;
    await journal?.close();
    _stopRecording();
    remote?.dispose();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    if (_pointerRouteInstalled) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    }
    if (_handlersInstalled) {
      FlutterError.onError = _previousFlutterError;
      PlatformDispatcher.instance.onError = _previousPlatformError;
    }
    await h?.dispose();
    await _outbox?.close();
    _transport?.close();
  }
}

/// Notes the first error event the backend accepted (connection
/// confirmation 2) without changing results.
class _ObservedEnvelopes implements EnvelopeTransport {
  _ObservedEnvelopes(this._base, this._onEventAccepted);

  final EnvelopeTransport _base;
  final void Function() _onEventAccepted;
  bool _seen = false;

  @override
  Future<UploadResult> sendEnvelope(List<int> gzippedBody) async {
    final result = await _base.sendEnvelope(gzippedBody);
    if (!_seen &&
        result.status == UploadStatus.uploaded &&
        _hasEvent(gzippedBody)) {
      _seen = true;
      _onEventAccepted();
    }
    return result;
  }

  static bool _hasEvent(List<int> gzippedBody) {
    try {
      final items = EnvelopeCodec.decode(gzippedBody)['items'];
      return items is List &&
          items.any((i) => i is Map && i['type'] == EnvelopeItemType.event);
    } catch (_) {
      return false;
    }
  }
}
