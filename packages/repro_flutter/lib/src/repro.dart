import 'dart:async';
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
import 'replay_engine.dart';

const _sdkName = 'repro_flutter';
const _sdkVersion = '0.1.0';

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
abstract final class Repro {
  static _Runtime? _rt;

  static Future<void> init({
    required ReproConfig config,
    List<ReproIntegration> integrations = const [],
    required FutureOr<void> Function() appRunner,
  }) {
    if (_rt != null) throw StateError('Repro.init called twice');
    final rt = _rt = _Runtime(config, integrations);
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
      _rt?.record(EventTypes.action, {'id': id, 'payload': _rt?.redactor.redactJson(payload)});
      callback(payload);
    };
  }

  /// Records edits of [controller] under [id] and restores them in replay.
  /// Values of sensitive ids (`password`, `otp`, ...) are redacted.
  static void trackText(String id, TextEditingController controller) {
    _actions.trackText(id, controller);
    var last = controller.text;
    controller.addListener(() {
      if (controller.text == last) return;
      last = controller.text;
      final rt = _rt;
      if (rt == null || !rt.isRecording) return;
      rt.record(EventTypes.text, {'id': id, 'value': rt.redactor.redactText(id, last)});
    });
  }

  static void untrackText(String id, TextEditingController controller) =>
      _actions.untrackText(id, controller);

  /// Raises a named failure assertion. Replay is judged against [assertionId].
  static void fail(String assertionId, [String message = '']) =>
      _rt?.handleFailure(FailureRecord.assertion(assertionId, message, _rt!.now()));

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

  // Used by ReproOverlay so its own touches are not recorded.
  static void suppressPointer(int pointer) => _rt?.suppressedPointers.add(pointer);
  static bool get overlayEnabled =>
      (_rt?.config.showOverlay ?? false) && !isReplaying && (_rt?.isRecording ?? false);

  static final ActionRegistry _actions = ActionRegistry();

  @visibleForTesting
  static void resetForTest() {
    _rt?.dispose();
    _rt = null;
  }
}

class _Runtime with WidgetsBindingObserver implements ReproSession {
  _Runtime(this.config, this.integrations);

  @override
  final ReproConfig config;
  final List<ReproIntegration> integrations;

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
  ReproBackendClient? _backend;
  bool _uploading = false;

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

  @override
  void record(String type, [Map<String, Object?> data = const {}]) {
    if (_recording) _recorder?.add(now(), type, data);
  }

  @override
  void reportError(Object error, StackTrace? stack) => _onError(error, stack);

  // ---------------------------------------------------------------- startup

  Future<void> start(FutureOr<void> Function() appRunner) async {
    final binding = WidgetsFlutterBinding.ensureInitialized();
    final replayUrl = config.replayUrl ?? _replayUrlFromEnvironment();
    if (replayUrl != null) {
      if (kReleaseMode) {
        debugPrint('[repro] ignoring REPRO_REPLAY_URL: replay is disabled in release builds');
      } else {
        await _startReplay(replayUrl, appRunner, binding);
        return;
      }
    }
    await _startCapture(appRunner, binding);
  }

  static String? _replayUrlFromEnvironment() {
    const fromDefine = String.fromEnvironment(ReplayProtocol.envUrl);
    if (fromDefine.isNotEmpty) return fromDefine;
    final fromEnv = Platform.environment[ReplayProtocol.envUrl];
    return fromEnv == null || fromEnv.isEmpty ? null : fromEnv;
  }

  Future<void> _startCapture(FutureOr<void> Function() appRunner, WidgetsBinding binding) async {
    if (config.backend != null) {
      _backend = ReproBackendClient(config.backend!);
    }
    store = CapsuleStore.open();
    final remote = _backend == null ? null : await (await store!).readConfig();
    _recording = _decideRecording(remote);
    _captureBodies = config.captureNetworkBodies && (remote?.captureNetworkBodies ?? true);
    _maxCapsuleBytes = remote?.maxCapsuleBytes ?? _maxCapsuleBytes;
    _redactor = Redactor(
      extraKeys: [...config.redactKeys, ...?remote?.redactKeys],
      extraHeaders: config.redactHeaders,
    );

    for (final integration in integrations) {
      await integration.setUp(this);
    }

    if (_recording) {
      final launch = Checkpoint(
        kind: CheckpointKind.launch,
        t: now(),
        wallClockMs: DateTime.now().millisecondsSinceEpoch,
        afterSeq: 0,
        data: await _snapshot(CheckpointKind.launch),
      );
      _recorder = FlightRecorder(
        launch: launch,
        maxEvents: config.maxEvents,
        windowMs: config.window.inMilliseconds,
      );
      _installCapture(binding);
    }

    binding.addPostFrameCallback((_) {
      _anchorMs = now();
      _wallAtAnchorMs = DateTime.now().millisecondsSinceEpoch;
    });
    await appRunner();

    if (_backend != null) {
      unawaited(_refreshRemoteConfig());
      unawaited(_flushOutbox());
    }
  }

  bool _decideRecording(RemoteCaptureConfig? remote) {
    if (!config.enabled) return false;
    if (remote != null && !remote.enabled) return false;
    if (config.mode != CaptureMode.production) return true;
    final rate = remote?.sampleRate ?? config.productionSampleRate;
    return Random().nextDouble() < rate;
  }

  void _installCapture(WidgetsBinding binding) {
    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.silent) _onError(details.exception, details.stack);
      previousFlutterError?.call(details);
    };
    final previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _onError(error, stack);
      return previousPlatformError?.call(error, stack) ?? false;
    };
    binding.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _checkpointTimer = Timer.periodic(config.checkpointInterval, (_) => _periodicCheckpoint());
  }

  Future<Map<String, Object?>> _snapshot(CheckpointKind kind) async {
    final data = <String, Object?>{};
    for (final integration in integrations) {
      try {
        final value = await integration.snapshot(kind);
        if (value != null) data[integration.name] = value;
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
    try {
      final t = now();
      final afterSeq = recorder.lastSeq;
      final data = await _snapshot(CheckpointKind.periodic);
      recorder.addCheckpoint(Checkpoint(
        kind: CheckpointKind.periodic,
        t: t,
        wallClockMs: DateTime.now().millisecondsSinceEpoch,
        afterSeq: afterSeq,
        data: data,
      ));
    } finally {
      _checkpointBusy = false;
    }
  }

  // ------------------------------------------------------------- recording

  void _onPointer(PointerEvent event) {
    if (!_recording) return;
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
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      record(EventTypes.lifecycle, {'state': state.name});

  void _onError(Object error, StackTrace? stack) {
    if (config.ignoreError?.call(error) ?? false) return;
    handleFailure(FailureRecord.exception(error, stack, now()));
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
    if (window.hasGap) {
      eligibility.missing('events.window',
          'events between the checkpoint and the window were evicted; raise window or maxEvents');
    }
    for (final integration in integrations) {
      integration.describeEligibility(eligibility, window);
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
          id: config.appId,
          name: config.appName,
          version: config.appVersion,
          build: config.appBuild,
          flavor: config.flavor,
        ),
        gitSha: config.gitSha,
        dirty: config.gitDirty,
        sdkName: _sdkName,
        sdkVersion: _sdkVersion,
        stateSchemaVersion: config.stateSchemaVersion,
        platform: PlatformInfo(
          os: Platform.operatingSystem,
          osVersion: Platform.operatingSystemVersion,
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
        labels: {...config.labels, ...labels},
      ),
      checkpoint: window.checkpoint.shift(anchor),
      events: events,
    );

    final bytes = await compute(_encodeCapsule, capsule);
    final s = await store!;
    final file = await s.save(capsule.manifest.capsuleId, bytes);

    UploadResult? upload;
    if (_backend != null) {
      if (bytes.length > _maxCapsuleBytes) {
        upload = UploadResult(UploadStatus.rejected,
            message: 'capsule is ${bytes.length} bytes, limit $_maxCapsuleBytes');
      } else {
        await s.enqueue(capsule.manifest.capsuleId, bytes);
        upload = await _flushOutbox(onlyId: capsule.manifest.capsuleId);
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

  /// Uploads pending capsules; returns the result for [onlyId] if given.
  Future<UploadResult?> _flushOutbox({String? onlyId}) async {
    final backend = _backend;
    if (backend == null || _uploading) return null;
    _uploading = true;
    UploadResult? mine;
    try {
      final s = await store!;
      for (final file in await s.pendingUploads()) {
        final id = file.uri.pathSegments.last.replaceAll('.repro', '');
        final result = await backend.upload(await file.readAsBytes());
        if (id == onlyId) mine = result;
        if (result.status != UploadStatus.retryLater) await file.delete();
        if (result.status == UploadStatus.rejected) {
          debugPrint('[repro] upload of $id rejected: ${result.message}');
          if (result.message == 'capture_disabled') _disableCapture();
        }
        if (result.status == UploadStatus.retryLater) break;
      }
    } catch (e) {
      debugPrint('[repro] outbox flush failed: $e');
    } finally {
      _uploading = false;
    }
    return mine;
  }

  Future<void> _refreshRemoteConfig() async {
    final remote = await _backend!.fetchConfig();
    if (remote == null) return;
    await (await store!).writeConfig(remote);
    if (!remote.enabled) _disableCapture();
  }

  /// Kill switch: stop recording and drop the buffer immediately.
  void _disableCapture() {
    if (!_recording) return;
    debugPrint('[repro] capture disabled by remote config');
    _recording = false;
    _recorder = null;
    _checkpointTimer?.cancel();
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
    _redactor = Redactor(extraKeys: config.redactKeys, extraHeaders: config.redactHeaders);

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

    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      _onError(details.exception, details.stack);
      previousFlutterError?.call(details);
    };
    final previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _onError(error, stack);
      return previousPlatformError?.call(error, stack) ?? true;
    };

    for (final integration in integrations) {
      await integration.setUp(this);
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
          message: 'replay crashed: $e',
        ));
      }));
    });
    await appRunner();
  }

  void dispose() {
    _checkpointTimer?.cancel();
    _recording = false;
  }
}
