import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:repro_core/repro_core.dart';

import 'actions.dart';
import 'backend.dart';
import 'config.dart';
import 'integration.dart';
import 'remote_config.dart';
import 'replay_engine.dart';

const _sdkName = 'repro_flutter';
const _sdkVersion = '0.2.0';

List<int> _encodeCapsule(Capsule capsule) => CapsuleCodec.encode(capsule);

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
class ReproTestOverrides {
  const ReproTestOverrides({this.storageDirectory, this.transport, this.random, this.setupTimeout});

  final Directory? storageDirectory;
  final ReproTransport? transport;
  final Random? random;
  final Duration? setupTimeout;
}

/// Entry point of the Repro SDK.
///
/// ```dart
/// void main() => Repro.init(
///       config: const ReproConfig(appVersion: '1.4.0', appBuild: '52'),
///       integrations: [ReproBloc(...), ReproDio(...), ReproSharedPreferences()],
///       appRunner: () => runApp(const MyApp()),
///     );
/// ```
///
/// Call [init] first in `main`, before `WidgetsFlutterBinding.ensureInitialized`,
/// so the binding is created inside Repro's zone and `clock.now()` is
/// controllable during replay.
///
/// Repro never stops the app from starting: if storage, an integration's
/// setup or anything else in capture setup fails, the app runs without
/// capture and the reason is printed with `debugPrint`.
abstract final class Repro {
  static _Runtime? _rt;

  @visibleForTesting
  static ReproTestOverrides? debugOverrides;

  static Future<void> init({
    required ReproConfig config,
    List<ReproIntegration> integrations = const [],
    required FutureOr<void> Function() appRunner,
  }) {
    if (_rt != null) throw StateError('Repro.init called twice');
    final rt = _rt = _Runtime(config, integrations, debugOverrides);
    return withClock(Clock(rt.wallClock), () => rt.start(appRunner));
  }

  static bool get isInitialized => _rt != null;
  static bool get isReplaying => _rt?.engine != null;
  static bool get isRecording => _rt?.isRecording ?? false;
  static CaptureMode? get mode => _rt?.config.mode;
  static ReproSession? get session => _rt;

  /// Seeded per session and restored in replay. Use it for randomness that
  /// affects behaviour you want reproducible.
  static Random get random => _rt?.random ?? _fallbackRandom;
  static final Random _fallbackRandom = Random();

  /// Wraps a UI callback as a named semantic action: records it, and lets
  /// semantic replay invoke it by [id].
  ///
  /// `onPressed: Repro.action('cart.checkout', () => bloc.add(Checkout()))`
  static VoidCallback action(String id, VoidCallback callback) {
    _actions.register(id, (_) => callback());
    return () {
      _rt?.record(EventTypes.action, {'id': id});
      callback();
    };
  }

  /// Like [action] with a JSON payload passed to the handler.
  static void Function(Map<String, Object?> payload) actionWithPayload(
      String id, void Function(Map<String, Object?> payload) callback) {
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
  static void trackText(String id, TextEditingController controller, {bool sensitive = false}) {
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
    rt.handleFailure(
        FailureRecord.assertion(assertionId, message, rt.now(), scrub: rt.redactor.scrubText));
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
  /// its TTL and when the app resumes).
  static Future<void> refreshRemoteConfig() async => _rt?.remote?.refresh();

  /// Uploads queued capsules now, if the remote config allows it.
  static Future<void> flushUploads() async => _rt?.flushOutbox();

  // Used by ReproOverlay so its own touches are not recorded.
  static void suppressPointer(int pointer) => _rt?.suppressedPointers.add(pointer);
  static bool get overlayEnabled =>
      (_rt?.config.showOverlay ?? false) && !isReplaying && (_rt?.isRecording ?? false);

  static final ActionRegistry _actions = ActionRegistry();

  @visibleForTesting
  static Future<void> resetForTest() async {
    await _rt?.dispose();
    _rt = null;
  }
}

class _Runtime with WidgetsBindingObserver implements ReproSession {
  _Runtime(this.config, this.integrations, this._overrides)
      : _random = _overrides?.random ?? Random();

  @override
  final ReproConfig config;
  final List<ReproIntegration> integrations;
  final ReproTestOverrides? _overrides;
  final Random _random;

  final Stopwatch _sw = Stopwatch()..start();
  final String _sessionId = uuidV4();
  final DateTime _startedAt = DateTime.now();
  late final int _seed = newSeed();
  late Random random = Random(_seed);

  FlightRecorder? _recorder;
  ReplayEngine? engine;
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
  ReproTransport? _transport;
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
    if (_warned.add(message)) debugPrint('[repro] $message');
  }

  @override
  void record(String type, [Map<String, Object?> data = const {}]) {
    if (!_recording) return;
    final recorder = _recorder;
    if (recorder == null) return;
    final clean = _sanitizeEvent(type, data);
    if (clean != null) recorder.add(now(), type, clean);
  }

  /// Defense in depth: whatever an integration records goes through the
  /// redactor again (idempotent for already-redacted data), then the app's
  /// [ReproConfig.beforeRecord]. Pointer and lifecycle events carry only
  /// numbers and enum names and skip the walk.
  Map<String, Object?>? _sanitizeEvent(String type, Map<String, Object?> data, {bool hook = true}) {
    try {
      var out = data;
      // An exchange that started before bodies were turned off finishes
      // after: its bodies must not be kept either.
      if (type == EventTypes.http && !_captureBodies) {
        out = _withoutBodies(ReproEvent(seq: 0, t: 0, type: type, data: out)).data;
      }
      if (type != EventTypes.pointer && type != EventTypes.lifecycle) {
        out = (_redactor.redactJson(out) as Map).cast<String, Object?>();
        // Fields derived from already-redacted input stay byte-identical:
        // the request key must match what replay computes, and base64 bodies
        // are binary, not text.
        if (type == EventTypes.http) {
          for (final f in const ['key']) {
            if (data.containsKey(f)) out[f] = data[f];
          }
          if (out['bodyEncoding'] == 'base64') out['responseBody'] = data['responseBody'];
          if (out['requestEncoding'] == 'base64') out['requestBody'] = data['requestBody'];
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

  @override
  void reportError(Object error, StackTrace? stack) => _onError(error, stack);

  // ---------------------------------------------------------------- startup

  Future<void> start(FutureOr<void> Function() appRunner) async {
    final binding = WidgetsFlutterBinding.ensureInitialized();
    String? replayUrl;
    try {
      replayUrl = config.replayUrl ?? await _replayUrlFromEnvironment(_overrides?.storageDirectory);
    } catch (e) {
      debugPrint('[repro] could not read replay request: $e');
    }
    if (replayUrl != null) {
      if (kReleaseMode) {
        debugPrint('[repro] ignoring replay request: replay is disabled in release builds');
      } else {
        debugPrint('[repro] replay mode: $replayUrl');
        await _startReplay(replayUrl, appRunner, binding);
        return;
      }
    }
    try {
      // A plugin or integration that never answers must not hold the app.
      await _prepareCapture(binding).timeout(_overrides?.setupTimeout ?? setupTimeout);
    } catch (e, st) {
      _setupAbandoned = true;
      debugPrint('[repro] capture setup failed; the app runs without capture: $e\n$st');
      _stopRecording();
    }
    await appRunner();
    _afterAppStarted();
  }

  /// Replay requests come from (in order): the `REPRO_REPLAY_URL`
  /// dart-define, the process environment, or a one-shot request file the
  /// CLI drops into the app's sandbox (`<support>/repro/replay_request.json`),
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
      if (createdAt == null || DateTime.now().difference(createdAt).inMinutes > 10) return null;
      return json['url'] as String?;
    } catch (e) {
      debugPrint('[repro] could not read replay request: $e');
      return null;
    }
  }

  /// Cache scope of the remote config: one per backend URL and ingest key,
  /// so a config fetched for staging never applies to production.
  static String _scope(ReproBackendConfig? backend) {
    final input = utf8.encode('${backend?.url ?? ''}|${backend?.ingestKey ?? ''}');
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

    final transport = _overrides?.transport ??
        (config.backend == null ? null : ReproBackendClient(config.backend!));
    final storeFuture = store = CapsuleStore.open(root: _overrides?.storageDirectory);
    final s = await storeFuture;

    if (transport != null) {
      _transport = transport;
      _outbox = await UploadOutbox.open(s.outboxDirectory, limits: config.outboxLimits);
      final controller = remote = RemoteConfigController(
        fetch: transport.fetchConfig,
        cache: s.configCache,
        scope: _scope(config.backend),
        onChange: _applyRemote,
        maxStale: config.maxStaleConfig,
      );
      await controller.loadCached();
    }

    final cached = remote?.current;
    _redactor = _baseRedactor(remote: cached?.redactKeys ?? const []);
    _captureBodies = config.captureNetworkBodies && (cached?.captureNetworkBodies ?? true);
    _maxCapsuleBytes = cached?.maxCapsuleBytes ?? _maxCapsuleBytes;
    _recording = _decideRecording(cached);
    if (_setupAbandoned) return _stopRecording();

    for (final integration in integrations) {
      try {
        await integration.setUp(this);
      } catch (e) {
        debugPrint('[repro] ${integration.name} setup failed: $e');
      }
    }

    if (_setupAbandoned) return _stopRecording();
    binding.addObserver(this);
    _observing = true;
    if (_recording) {
      final launch = Checkpoint(
        kind: CheckpointKind.launch,
        t: now(),
        wallClockMs: DateTime.now().millisecondsSinceEpoch,
        afterSeq: 0,
        data: await _snapshot(CheckpointKind.launch),
      );
      if (_setupAbandoned) return _stopRecording();
      _recorder = FlightRecorder(
        launch: launch,
        maxEvents: config.maxEvents,
        windowMs: config.window.inMilliseconds,
      );
      _installCapture();
    }

    binding.addPostFrameCallback((_) {
      _anchorMs = now();
      _wallAtAnchorMs = DateTime.now().millisecondsSinceEpoch;
    });
  }

  void _afterAppStarted() {
    if (_disposed || remote == null) return;
    unawaited(remote!.refresh().then((_) => flushOutbox()).then((_) {}, onError: (Object e) {
      debugPrint('[repro] startup sync failed: $e');
    }));
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
    _checkpointTimer = Timer.periodic(config.checkpointInterval, (_) => _periodicCheckpoint());
  }

  void _installErrorHandlers() {
    if (_handlersInstalled) return;
    _handlersInstalled = true;
    final previousFlutterError = _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.silent) _guard(() => _onError(details.exception, details.stack));
      previousFlutterError?.call(details);
    };
    final previousPlatformError = _previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _guard(() => _onError(error, stack));
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
        debugPrint('[repro] ${integration.name} snapshot failed: $e');
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
      if (epoch != _captureEpoch || !identical(recorder, _recorder)) return;
      recorder.addCheckpoint(Checkpoint(
        kind: CheckpointKind.periodic,
        t: t,
        wallClockMs: DateTime.now().millisecondsSinceEpoch,
        afterSeq: afterSeq,
        data: data,
      ));
    } catch (e) {
      _warnOnce('periodic checkpoint failed: $e');
    } finally {
      _checkpointBusy = false;
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
    final controller = remote;
    if (controller == null) return;
    if (state == AppLifecycleState.resumed) {
      controller.onResumed();
      unawaited(flushOutbox());
    } else if (state == AppLifecycleState.paused) {
      controller.onPaused();
    }
  }

  void _onError(Object error, StackTrace? stack) {
    if (config.ignoreError?.call(error) ?? false) return;
    handleFailure(FailureRecord.exception(error, stack, now(), scrub: _redactor.scrubText));
  }

  void handleFailure(FailureRecord failure) {
    final replaying = engine;
    if (replaying != null) {
      replaying.onFailure(failure);
      return;
    }
    if (!_recording) return;
    record(EventTypes.failure, failure.toJson()..remove('stack'));
    lastFailure = failure;
    if (!_seenSignatures.add(failure.signature)) return;
    if (!config.autoCaptureOnFailure) return;
    if (_capsulesWritten >= config.maxCapsulesPerSession) return;
    if (!_capturedSignatures.add(failure.signature)) return;
    // Let the failure settle (error widgets, follow-up events) before writing.
    Timer(const Duration(milliseconds: 300), () {
      unawaited(writeCapsule(failure: failure).then((r) {
        if (r != null) {
          debugPrint('[repro] captured ${r.capsuleId} '
              '(${r.eligibility.status.name}) → ${r.file.path}');
        }
      }).catchError((Object e) => debugPrint('[repro] capture failed: $e')));
    });
  }

  // --------------------------------------------------------------- capsule

  Future<CaptureResult?> writeCapsule({
    FailureRecord? failure,
    Map<String, String> labels = const {},
  }) async {
    final recorder = _recorder;
    if (!_recording || recorder == null) return null;
    _capsulesWritten++;
    final window = recorder.window();
    final anchor = _anchorMs ?? now();
    final wallAtAnchor =
        _wallAtAnchorMs ?? (window.checkpoint.wallClockMs + anchor - window.checkpoint.t);

    final eligibility = EligibilityBuilder();
    if (config.gitSha == null) {
      eligibility.missing('build.gitSha', 'REPRO_GIT_SHA was not set at build time');
    } else if (config.gitDirty == true) {
      eligibility.missing('build.gitSha', 'built from a tree with uncommitted changes');
    }
    if (failure == null) {
      eligibility.missing('failure.assertion', 'manual capture without a failure assertion',
          blocking: true);
    }
    if (recorder.rewriteDropped > 0) {
      eligibility.missing('events.redaction',
          '${recorder.rewriteDropped} buffered events were dropped when redaction rules changed');
    }
    if (window.hasGap) {
      eligibility.missing('events.window',
          'events between the checkpoint and the window were evicted; raise window or maxEvents');
    }
    for (final integration in integrations) {
      try {
        integration.describeEligibility(eligibility, window);
      } catch (e) {
        eligibility.missing('integration.${integration.name}', 'eligibility check failed: $e');
      }
    }

    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final logical = view.physicalSize / view.devicePixelRatio;
    final events = [for (final e in window.events) e.shift(anchor)];
    final capsule = Capsule(
      manifest: CapsuleManifest(
        capsuleId: uuidV4(),
        createdAt: DateTime.now(),
        mode: config.mode,
        app: AppInfo(
          id: _cutOrNull(config.appId, 200),
          name: _cutOrNull(config.appName, 200),
          version: _cut(config.appVersion, 200),
          build: _cut(config.appBuild, 200),
          flavor: _cutOrNull(config.flavor, 200),
        ),
        gitSha: config.gitSha,
        dirty: config.gitDirty,
        sdkName: _sdkName,
        sdkVersion: _sdkVersion,
        stateSchemaVersion: config.stateSchemaVersion,
        platform: PlatformInfo(
          os: Platform.operatingSystem,
          osVersion: _osVersion(),
          locale: Platform.localeName,
          screenWidth: logical.width,
          screenHeight: logical.height,
          pixelRatio: view.devicePixelRatio,
          dartVersion: Platform.version.split(' ').first,
        ),
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
      ),
      checkpoint: window.checkpoint.shift(anchor),
      events: events,
    );

    // Never queue what a reader would reject; keep it locally for inspection.
    final problem = validateCapsuleDocument(CapsuleCodec.toJson(capsule));
    final bytes = await compute(_encodeCapsule, capsule);
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
      debugPrint('[repro] capsule ${capsule.manifest.capsuleId} failed validation, not uploaded: $problem');
      if (outbox != null) upload = UploadResult(UploadStatus.rejected, message: 'invalid capsule: $problem');
    } else if (outbox != null) {
      if (bytes.length > _maxCapsuleBytes) {
        upload = UploadResult(UploadStatus.rejected,
            message: 'capsule is ${bytes.length} bytes, limit $_maxCapsuleBytes');
      } else if (!await outbox.enqueue(capsule.manifest.capsuleId, bytes)) {
        upload = const UploadResult(UploadStatus.rejected, message: 'not queued (outbox limit or disk error)');
      } else if (_killed) {
        await outbox.purge();
        return null;
      } else {
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

  /// Redacted and cut to the capsule format's bounds (100 labels, 100-char
  /// keys, 2,000-char values), so a long QA note never invalidates a capsule.
  Map<String, String> _sanitizeLabels(Map<String, String> labels) => {
        for (final e in labels.entries.take(100))
          _cut(e.key, 100): _redactor.isSensitiveKey(e.key)
              ? Redactor.placeholder
              : _cut(_redactor.scrubText(e.value), 2000),
      };

  static String _cut(String s, int max) => s.length <= max ? s : s.substring(0, max);
  static String? _cutOrNull(String? s, int max) => s == null ? null : _cut(s, max);

  bool get _uploadsAllowed => !_disposed && (remote?.uploadsAllowed ?? false);

  /// Uploads pending capsules; returns the result for [onlyId] if given.
  /// The remote config is refreshed first when it is older than its TTL, so
  /// a kill switch set since the last fetch is seen before anything is sent.
  Future<UploadResult?> flushOutbox({String? onlyId}) async {
    final outbox = _outbox;
    final transport = _transport;
    final controller = remote;
    if (outbox == null || transport == null || controller == null || _disposed) return null;
    try {
      await controller.ensureFresh();
      if (!_uploadsAllowed) {
        return onlyId == null
            ? null
            : const UploadResult(UploadStatus.retryLater, message: 'waiting for remote config');
      }
      return await outbox.flush(
        upload: (bytes) async {
          final result = await transport.upload(bytes);
          if (result.message == 'capture_disabled') unawaited(controller.refresh());
          return result;
        },
        allowed: () => _uploadsAllowed,
        onlyId: onlyId,
      );
    } catch (e) {
      debugPrint('[repro] outbox flush failed: $e');
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
    _maxCapsuleBytes = next.maxCapsuleBytes;
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
          debugPrint('[repro] sample rate lowered to $rate; this session stops recording');
          _stopRecording();
        }
      }
    }
    final bodies = config.captureNetworkBodies && next.captureNetworkBodies;
    if (_captureBodies && !bodies) {
      _recorder?.rewrite(event: (e) => e.type == EventTypes.http ? _withoutBodies(e) : e);
    }
    _captureBodies = bodies;
    if (!listEquals(_redactor.extraKeys, [...config.redactKeys, ...next.redactKeys])) {
      _redactor = _baseRedactor(remote: next.redactKeys);
      final recorder = _recorder;
      try {
        recorder?.rewrite(
          // Request keys were computed with the old rules and can embed
          // values the new rules redact; replay could not match them either.
          // Buffered exchanges are dropped (the capsule reports it), the rest
          // is redacted again. Events that cannot be are dropped too.
          event: (e) {
            if (e.type == EventTypes.http) return null;
            final data = _sanitizeEvent(e.type, e.data, hook: false);
            return data == null ? null : ReproEvent(seq: e.seq, t: e.t, type: e.type, data: data);
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
        debugPrint('[repro] could not apply new redaction rules to the buffer ($e); dropping it');
        _stopRecording();
      }
    }
  }

  static ReproEvent _withoutBodies(ReproEvent e) {
    final d = Map<String, Object?>.of(e.data);
    d['requestBody'] = null;
    d['responseBody'] = null;
    d['bodyEncoding'] = 'omitted';
    if (d['requestEncoding'] != null && d['requestEncoding'] != 'json') d['requestEncoding'] = 'omitted';
    return ReproEvent(seq: e.seq, t: e.t, type: e.type, data: d);
  }

  void _stopRecording() {
    _captureEpoch++;
    _recording = false;
    _recorder = null;
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
    if (wasRecording) debugPrint('[repro] capture disabled by remote config');
    final outbox = _outbox;
    if (outbox != null) unawaited(outbox.purge().then((_) {}, onError: (Object _) {}));
    final s = store;
    if (s != null) {
      unawaited(s.then((s) => s.clearSavedCaptures()).then((_) {}, onError: (Object _) {}));
    }
  }

  // ---------------------------------------------------------------- replay

  Future<void> _startReplay(
      String url, FutureOr<void> Function() appRunner, WidgetsBinding binding) async {
    final channel = ReplayChannel(url);
    final Capsule capsule;
    final ReplaySettings settings;
    try {
      (capsule, settings) = await channel.fetch();
    } catch (e) {
      await channel.report(ReplayReport(
        outcome: e is CapsuleFormatException ? ReplayOutcome.incompatible : ReplayOutcome.error,
        attempt: 1,
        durationMs: 0,
        strategy: ReplayStrategy.auto,
        message: 'could not load capsule: $e',
      ));
      await appRunner();
      return;
    }

    final replay = engine = ReplayEngine(
      capsule: capsule,
      settings: settings,
      actions: Repro._actions,
      buildGitSha: config.gitSha,
    );
    random = Random(capsule.manifest.session.seed);
    // The capture's redaction rules, so request keys of redacted bodies match.
    _redactor = Redactor(
      extraKeys: {...config.redactKeys, ...capsule.manifest.redactionKeys},
      extraHeaders: {...config.redactHeaders, ...capsule.manifest.redactionHeaders},
      patterns: config.redactPatterns,
    );

    if (capsule.manifest.stateSchemaVersion != config.stateSchemaVersion &&
        capsule.checkpoint.kind == CheckpointKind.periodic) {
      await channel.report(ReplayReport(
        outcome: ReplayOutcome.incompatible,
        attempt: settings.attempt,
        durationMs: 0,
        strategy: settings.strategy,
        expectedSignature: capsule.manifest.failure?.signature,
        message: 'state schema v${capsule.manifest.stateSchemaVersion} captured, '
            'app is v${config.stateSchemaVersion}; register a migration or mark the capsule stale',
      ));
      engine = null;
      await appRunner();
      return;
    }
    replay.precheck();

    _installErrorHandlers();

    final names = {for (final i in integrations) i.name};
    for (final name in capsule.manifest.integrations) {
      if (!names.contains(name)) {
        replay.diverge('integration.missing', '$name was used when capturing but is not set up');
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
      if (!names.contains(name)) replay.diverge('restore.missingIntegration', name);
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
      unawaited(replay.run().then(channel.report).catchError((Object e, StackTrace st) {
        return channel.report(ReplayReport(
          outcome: ReplayOutcome.error,
          attempt: settings.attempt,
          durationMs: 0,
          strategy: settings.strategy,
          expectedSignature: capsule.manifest.failure?.signature,
          message: 'replay crashed: $e',
        ));
      }));
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

  Future<void> dispose() async {
    _disposed = true;
    _stopRecording();
    remote?.dispose();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    if (_pointerRouteInstalled) GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    if (_handlersInstalled) {
      FlutterError.onError = _previousFlutterError;
      PlatformDispatcher.instance.onError = _previousPlatformError;
    }
    await _outbox?.close();
    _transport?.close();
  }
}
