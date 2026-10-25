import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/core.dart';
import '../backend.dart';
import '../config.dart';
import '../remote_config.dart';
import 'breadcrumbs.dart';
import 'options.dart';
import 'scope.dart';
import 'sessions.dart';
import 'tracing.dart';

/// An error event built from the scope at the moment of the error, waiting
/// for `beforeSend` (and, when a capsule is written for the same failure,
/// for that capsule's id).
class PreparedEvent {
  PreparedEvent(
    this.event,
    this.hint, {
    required this.sampledOut,
    this.sessionUpdate,
  });

  final ErrorEvent event;
  final EventHint hint;
  final bool sampledOut;
  final Map<String, Object?>? sessionUpdate;

  /// What the capsule written for this failure records in
  /// `manifest.monitoring`.
  CapsuleMonitoring monitoringInfo() => CapsuleMonitoring(
    eventId: event.eventId,
    traceId: (event.contexts['trace'] as Map?)?['traceId'] as String?,
    release: event.release,
    environment: event.environment,
  );
}

/// What the hub needs from the capture runtime.
class MonitoringHost {
  const MonitoringHost({
    required this.config,
    required this.redactor,
    required this.remote,
    required this.uploadsAllowed,
    required this.ensureFreshConfig,
    required this.refreshConfig,
    required this.writeCapsule,
    required this.isRecording,
  });

  final BugCapsuleConfig config;
  final Redactor Function() redactor;
  final RemoteCaptureConfig? Function() remote;
  final bool Function() uploadsAllowed;
  final Future<void> Function() ensureFreshConfig;
  final Future<void> Function() refreshConfig;

  /// Writes a capsule now (feedback); returns its id.
  final Future<String?> Function(String note, CapsuleMonitoring? monitoring)
  writeCapsule;
  final bool Function() isRecording;
}

/// Monitoring state of one SDK instance (monitoring-v1): builds events,
/// sessions, transactions and feedback from the current [Scope], redacts
/// them with the capture redactor and queues them as envelopes in their own
/// outbox (the capsule outbox's rules: persisted, backoff, `Retry-After`,
/// dropped after 7 days).
class MonitoringHub implements TransactionSink {
  MonitoringHub({
    required this.options,
    required this.host,
    required this.sdkVersion,
    required this.startedAt,
    this.storage,
    this.transport,
    this.appPackage,
    Random? random,
  }) : _random = random ?? Random() {
    _breadcrumbs = BreadcrumbBuffer(options.maxBreadcrumbs.clamp(0, 100));
  }

  /// The running hub; integrations (Dio, http, routers) reach it here.
  static MonitoringHub? current;

  /// Replaces the `BUGCAPSULE_OBFUSCATION_ID` dart-define in tests.
  @visibleForTesting
  static String? debugObfuscationId;

  final MonitoringOptions options;
  final MonitoringHost host;
  final String sdkVersion;

  /// When `BugCapsule.init` ran: the start of the app-start transaction.
  final DateTime startedAt;
  final Directory? storage;
  final EnvelopeTransport? transport;

  /// The app's Dart package, detected from the caller of `BugCapsule.init`.
  final String? appPackage;
  final Random _random;

  late final BreadcrumbBuffer _breadcrumbs;
  UploadOutbox? _outbox;
  SessionTracker? _sessions;
  String _installId = uuidV4();
  String? _lastEventId;
  String? _lastRoute;
  Map<String, Object?> _baseContexts = const {};
  bool _inForeground = true;
  bool _disposed = false;
  Future<void> _writes = Future.value();
  Timer? _flushTimer;
  RawReceivePort? _isolatePort;
  TimingsCallback? _timingsCallback;
  TransactionImpl? _navigation;
  final Set<TransactionImpl> _open = {};
  final Map<TransactionImpl, _FrameCounter> _frames = {};
  final List<(String, DateTime)> _recentUnhandled = [];

  RemoteCaptureConfig? get _remote => host.remote();
  BugCapsuleConfig get _config => host.config;

  @override
  String? get release {
    if (options.release != null) return options.release;
    final id = _config.appId ?? _config.appName;
    final version = '${_config.appVersion}+${_config.appBuild}';
    return id == null ? version : '$id@$version';
  }

  @override
  String get environment =>
      options.environment ??
      switch (_config.mode) {
        CaptureMode.production => 'production',
        CaptureMode.qa => 'qa',
        CaptureMode.debug => 'development',
      };

  InAppRules get inAppRules => InAppRules(
    includes: options.inAppIncludes.isNotEmpty
        ? options.inAppIncludes
        : [?appPackage],
    excludes: options.inAppExcludes,
  );

  double get errorSampleRate => min(
    options.errorSampleRate,
    _remote?.errorSampleRate ?? 1.0,
  ).clamp(0.0, 1.0);

  double get tracesSampleRate =>
      (_remote?.tracesSampleRate ?? options.tracesSampleRate ?? 0)
          .clamp(0.0, 1.0)
          .toDouble();

  PropagationTargets get propagationTargets => PropagationTargets(
    _remote?.tracePropagationTargets ?? options.tracePropagationTargets,
  );

  bool get _sessionTracking =>
      options.enableAutoSessionTracking && (_remote?.sessionTracking ?? true);

  /// The backend's `monitoringEnabled` (and the kill switch) allow sending.
  bool get _sendingAllowed =>
      !_disposed &&
      (_remote?.monitoringEnabled ?? true) &&
      (_remote?.enabled ?? true);

  String? get lastEventId => _lastEventId;
  bool get inForeground => _inForeground;

  // ------------------------------------------------------------------ setup

  Future<void> start({AppLifecycleState? lifecycle}) async {
    final root = storage;
    if (root != null) {
      if (transport != null) {
        _outbox = await UploadOutbox.open(
          Directory('${root.path}/envelopes'),
          limits: options.outboxLimits,
          extension: '.envelope',
        );
      }
      _installId = _readInstallId(root);
    }
    _baseContexts = _defaultContexts();
    _inForeground =
        lifecycle == null ||
        lifecycle == AppLifecycleState.resumed ||
        lifecycle == AppLifecycleState.inactive;

    final sessions = _sessions = SessionTracker(
      release: release,
      environment: environment,
      distinctId: () => Scope.root.user?.id ?? _installId,
      send: (payload) {
        if (_sessionTracking) {
          _enqueue([EnvelopeItem(EnvelopeItemType.session, payload)]);
        }
      },
      persist: _persistSession,
    );
    final previous = sessions.recover(_readSession());
    if (previous != null) {
      _enqueue([EnvelopeItem(EnvelopeItemType.session, previous)]);
    }
    _persistSession(null);
    if (_sessionTracking && _inForeground) sessions.start();

    if (options.captureIsolateErrors) _listenToIsolate(Isolate.current);
    if (options.enableFramesTracking) {
      SchedulerBinding.instance.addTimingsCallback(
        _timingsCallback = _onTimings,
      );
    }
    if (options.enableAppStartTracking) {
      unawaited(
        WidgetsBinding.instance.waitUntilFirstFrameRasterized.then(
          (_) => _appStarted(),
        ),
      );
    }
    current = this;
  }

  String _readInstallId(Directory root) {
    final file = File('${root.path}/install_id');
    try {
      final existing = file.existsSync() ? file.readAsStringSync().trim() : '';
      if (existing.isNotEmpty) return existing;
      final id = uuidV4();
      file.writeAsStringSync(id);
      return id;
    } catch (_) {
      return _installId;
    }
  }

  File? get _sessionFile =>
      storage == null ? null : File('${storage!.path}/session.json');

  Map<String, Object?>? _readSession() {
    try {
      final f = _sessionFile;
      if (f == null || !f.existsSync()) return null;
      return (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  void _persistSession(Map<String, Object?>? state) {
    final f = _sessionFile;
    if (f == null || _disposed) return;
    try {
      if (state == null) {
        if (f.existsSync()) f.deleteSync();
      } else {
        f.writeAsStringSync(jsonEncode(state), flush: true);
      }
    } catch (_) {
      // Release health is best effort; never fail the app over it.
    }
  }

  Map<String, Object?> _defaultContexts() {
    final contexts = <String, Object?>{
      'os': {'name': _osName(), 'version': Platform.operatingSystemVersion},
      'device': {'arch': _arch()},
      'app': {
        'appId': ?_config.appId,
        'appName': ?_config.appName,
        'appVersion': _config.appVersion,
        'appBuild': _config.appBuild,
        'flavor': ?_config.flavor,
      },
      'runtime': {'name': 'dart', 'version': Platform.version.split(' ').first},
      'culture': {'locale': Platform.localeName},
    };
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final logical = view.physicalSize / view.devicePixelRatio;
      contexts['screen'] = {
        'width': logical.width,
        'height': logical.height,
        'density': view.devicePixelRatio,
      };
    } catch (_) {
      // No view (headless): no screen context.
    }
    return contexts;
  }

  static String _osName() => switch (Platform.operatingSystem) {
    'android' => 'Android',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    final other => other,
  };

  static String _arch() {
    final abi = Abi.current().toString();
    final arch = abi.substring(abi.indexOf('_') + 1);
    return switch (arch) {
      'x64' => 'x86_64',
      'ia32' => 'x86',
      _ => arch,
    };
  }

  // ------------------------------------------------------------ breadcrumbs

  /// A flight-recorder event (already redacted) as a breadcrumb.
  void onRecorded(String type, Map<String, Object?> data) {
    final crumb = BreadcrumbMapper.fromEvent(
      type,
      data,
      previousRoute: _lastRoute,
    );
    if (type == EventTypes.route) _lastRoute = data['location'] as String?;
    if (crumb != null) addBreadcrumb(crumb, redacted: true);
  }

  void addBreadcrumb(Breadcrumb crumb, {bool redacted = false}) {
    if (_disposed) return;
    var b = crumb;
    final hook = options.beforeBreadcrumb;
    if (hook != null) {
      try {
        final kept = hook(b);
        if (kept == null) return;
        b = kept;
      } catch (_) {
        // A throwing hook keeps the breadcrumb.
      }
    }
    _breadcrumbs.max = min(
      options.maxBreadcrumbs,
      _remote?.maxBreadcrumbs ?? 100,
    ).clamp(0, 100);
    _breadcrumbs.add(b);
  }

  void navigationBreadcrumb(String to, {String? from}) {
    final location = host.redactor().redactUrl(to);
    addBreadcrumb(
      Breadcrumb(
        type: BreadcrumbType.navigation,
        category: 'navigation',
        data: {'from': ?(from ?? _lastRoute), 'to': location},
      ),
    );
    _lastRoute = location;
  }

  void clearBreadcrumbs() => _breadcrumbs.clear();

  // ----------------------------------------------------------------- errors

  /// Builds the event for [error] with the current scope. Returns null when
  /// monitoring is off.
  PreparedEvent? prepareException(
    Object error,
    StackTrace? stack, {
    required Mechanism mechanism,
    EventLevel? level,
    Map<String, String>? tags,
    Map<String, Object?>? extra,
    List<String>? fingerprint,
    Map<String, Object?>? contexts,
    String? valueOverride,
    String? typeOverride,
  }) {
    if (_disposed) return null;
    final trace = stack ?? (error is Error ? error.stackTrace : null);
    final parsed = trace == null
        ? null
        : parseDartStack(trace.toString(), rules: inAppRules);
    final value = valueOverride ?? _safeToString(error);
    final exception = ExceptionValue(
      type: typeOverride ?? error.runtimeType.toString(),
      value: value,
      mechanism: mechanism,
      frames: parsed?.frames ?? const [],
    );
    final unhandled = !mechanism.handled;
    final fatal = unhandled && options.crashOnUnhandled;
    final event = _buildEvent(
      level: level ?? (fatal ? EventLevel.fatal : EventLevel.error),
      tags: tags,
      extra: extra,
      fingerprint: fingerprint,
      contexts: contexts,
    )..exceptions.add(exception);
    event.debugImages.addAll(parsed?.debugImages ?? const []);
    _addObfuscationImage(event);
    if (unhandled) _rememberUnhandled(value);
    return _prepared(
      event,
      EventHint(error: error, stackTrace: trace, mechanism: mechanism),
    );
  }

  PreparedEvent? prepareMessage(
    String message, {
    EventLevel level = EventLevel.info,
    Map<String, String>? tags,
  }) {
    if (_disposed) return null;
    final event = _buildEvent(level: level, tags: tags)..message = message;
    if (options.attachStacktrace) {
      final frames = parseDartStack(
        StackTrace.current.toString(),
        rules: inAppRules,
      ).frames.where((f) => f.package != 'bug_capsule').toList();
      if (frames.isNotEmpty) {
        event.threads = [
          {
            'id': 'main',
            'name': 'main',
            'crashed': false,
            'current': true,
            'stacktrace': {
              'frames': [for (final f in frames) f.toJson()],
            },
          },
        ];
      }
    }
    _addObfuscationImage(event);
    return _prepared(event, const EventHint());
  }

  PreparedEvent _prepared(ErrorEvent event, EventHint hint) {
    final countsAsError =
        event.level == EventLevel.fatal || event.level == EventLevel.error;
    final sessionUpdate = countsAsError && _sessionTracking
        ? _sessions?.onError(
            crashed: event.level == EventLevel.fatal && event.unhandled,
          )
        : null;
    final sampledOut =
        (event.level != EventLevel.fatal &&
            _random.nextDouble() >= errorSampleRate) ||
        _flooding(event);
    if (!sampledOut) _lastEventId = event.eventId;
    return PreparedEvent(
      event,
      hint,
      sampledOut: sampledOut,
      sessionUpdate: sessionUpdate,
    );
  }

  /// Events of one error per minute beyond which repeats are dropped (an
  /// error thrown in `build` can repeat every frame).
  static const maxRepeatsPerMinute = 10;
  final Map<String, (int, DateTime)> _repeats = {};

  bool _flooding(ErrorEvent event) {
    final key = [
      for (final e in event.exceptions)
        '${e.type}:${e.value}:${e.frames.isEmpty ? '' : e.frames.last.function}',
      event.message ?? '',
    ].join('|');
    final now = DateTime.now();
    final (count, since) = _repeats[key] ?? (0, now);
    if (now.difference(since) > const Duration(minutes: 1)) {
      _repeats[key] = (1, now);
      return false;
    }
    if (_repeats.length > 200) _repeats.clear();
    _repeats[key] = (count + 1, since);
    return count + 1 > maxRepeatsPerMinute;
  }

  ErrorEvent _buildEvent({
    required EventLevel level,
    Map<String, String>? tags,
    Map<String, Object?>? extra,
    List<String>? fingerprint,
    Map<String, Object?>? contexts,
  }) {
    final scope = Scope.current;
    final span = scope.activeSpan;
    return ErrorEvent(
      eventId: uuidV4(),
      timestamp: DateTime.now(),
      level: scope.level ?? level,
      release: release,
      environment: environment,
      tags: {
        if (options.dist != null) 'dist': options.dist!,
        ...scope.tags,
        ...?tags,
      },
      user: _user(scope),
      contexts: {
        ..._contexts(),
        ...scope.contexts,
        ...?contexts,
        if (span != null)
          'trace': {
            'traceId': span.traceId,
            'spanId': span.spanId,
            'op': span.op,
          },
      },
      breadcrumbs: _breadcrumbs.snapshot(),
      extra: {...scope.extras, ...?extra},
      fingerprint: fingerprint ?? scope.fingerprint,
    );
  }

  Map<String, Object?> _contexts() => {
    ..._baseContexts,
    'app': {
      ...(_baseContexts['app'] as Map? ?? const {}),
      'inForeground': _inForeground,
    },
  };

  MonitoringUser? _user(Scope scope) {
    final user = scope.user;
    if (!options.sendDefaultPii || user?.ipAddress != null) return user;
    return MonitoringUser(
      id: user?.id,
      email: user?.email,
      username: user?.username,
      segment: user?.segment,
      data: user?.data,
      ipAddress: '{{auto}}',
    );
  }

  void _addObfuscationImage(ErrorEvent event) {
    const fromDefine = String.fromEnvironment('BUGCAPSULE_OBFUSCATION_ID');
    final id = debugObfuscationId ?? fromDefine;
    if (id.isNotEmpty) {
      event.debugImages.add({'type': 'dart_obfuscation', 'debugId': id});
    }
  }

  static String _safeToString(Object error) {
    try {
      return error.toString();
    } catch (_) {
      return 'Instance of ${error.runtimeType}';
    }
  }

  void _rememberUnhandled(String value) {
    final now = DateTime.now();
    _recentUnhandled
      ..removeWhere((e) => now.difference(e.$2) > const Duration(seconds: 10))
      ..add((value, now));
  }

  /// Applies sampling and `beforeSend` and queues the event. With [capsule]
  /// (a capsule is being written for the same failure) the event waits for
  /// it and carries its `capsuleId`; linked events are never sampled out.
  void submit(PreparedEvent prepared, {Future<String?>? capsule}) {
    if (capsule == null) return _finish(prepared, linked: false);
    _lastEventId = prepared.event.eventId;
    unawaited(
      capsule.then((id) => id, onError: (Object _) => null).then((id) {
        prepared.event.capsuleId = id;
        _finish(prepared, linked: id != null);
      }),
    );
  }

  void _finish(PreparedEvent prepared, {required bool linked}) {
    final items = <EnvelopeItem>[];
    if (linked || !prepared.sampledOut) {
      ErrorEvent? event = prepared.event;
      final hook = options.beforeSend;
      if (hook != null) {
        try {
          event = hook(prepared.event, prepared.hint);
        } catch (e) {
          debugPrint(
            '[bugcapsule] beforeSend threw ($e); sending the event unchanged',
          );
          event = prepared.event;
        }
      }
      if (event != null) {
        items.add(EnvelopeItem(EnvelopeItemType.event, event.toJson()));
      }
    }
    final session = prepared.sessionUpdate;
    if (session != null) {
      items.add(EnvelopeItem(EnvelopeItemType.session, session));
    }
    if (items.isNotEmpty) _enqueue(items);
  }

  /// `captureException` / `captureMessage` from the app: no capsule.
  String? capture(PreparedEvent? prepared) {
    if (prepared == null) return null;
    submit(prepared);
    return prepared.sampledOut ? null : prepared.event.eventId;
  }

  void _listenToIsolate(Isolate isolate) {
    final port = _isolatePort ??= RawReceivePort((Object? message) {
      if (message is! List || message.length != 2) return;
      _onIsolateError('${message[0]}', '${message[1]}');
    });
    isolate.addErrorListener(port.sendPort);
  }

  void addIsolate(Isolate isolate) => _listenToIsolate(isolate);

  void _onIsolateError(String error, String stack) {
    // The same error often reached PlatformDispatcher.onError first.
    if (_recentUnhandled.any((e) => e.$1 == error)) return;
    final type =
        RegExp(r'^([A-Za-z_$][\w$]*)(?::|$)').firstMatch(error)?[1] ??
        'IsolateError';
    final prepared = prepareException(
      _IsolateError(error),
      StackTrace.fromString(stack),
      mechanism: Mechanism.uncaught,
      valueOverride: error,
      typeOverride: type,
    );
    if (prepared != null) submit(prepared);
  }

  // --------------------------------------------------------------- feedback

  Future<String?> captureFeedback({
    required String message,
    String? name,
    String? email,
    String? eventId,
    String? url,
    Map<String, String>? tags,
    bool? captureCapsule,
  }) async {
    final text = message.trim();
    if (_disposed || text.isEmpty) return null;
    final scope = Scope.current;
    final span = scope.activeSpan;
    final feedbackId = uuidV4();
    String? capsuleId;
    final withCapsule =
        captureCapsule ??
        options.captureCapsuleWithFeedback ??
        (_config.mode == CaptureMode.qa);
    if (withCapsule && host.isRecording()) {
      try {
        capsuleId = await host.writeCapsule(
          cut(text, 2000),
          eventId == null
              ? null
              : CapsuleMonitoring(
                  eventId: eventId,
                  traceId: span?.traceId,
                  release: release,
                  environment: environment,
                ),
        );
      } catch (e) {
        debugPrint('[bugcapsule] feedback capsule failed: $e');
      }
    }
    _enqueue([
      EnvelopeItem(EnvelopeItemType.feedback, {
        'feedbackId': feedbackId,
        'timestamp': isoTimestamp(DateTime.now()),
        'eventId': ?eventId,
        'name': name == null ? null : cut(name, 200),
        'email': email == null ? null : cut(email, 200),
        'message': cut(text, 5000),
        'url': url ?? _lastRoute,
        'release': ?release,
        'environment': environment,
        'runtime': 'flutter',
        if (_user(scope) != null) 'user': _user(scope)!.toJson(),
        'contexts': {
          if (span != null)
            'trace': {'traceId': span.traceId, 'spanId': span.spanId},
        },
        'tags': sanitizeTags({...scope.tags, ...?tags}),
        'capsuleId': capsuleId,
      }),
    ]);
    return feedbackId;
  }

  // ---------------------------------------------------------------- tracing

  TransactionImpl startTransaction(
    String name,
    String op, {
    bool bindToScope = false,
    Duration? idleTimeout,
    DateTime? startTimestamp,
  }) {
    final scope = Scope.current;
    final continued = scope.continuedTrace;
    scope.continuedTrace = null;
    bool sampled;
    double? rate;
    if (continued != null) {
      sampled = continued.sampled;
      rate = continued.sampleRate;
    } else {
      final sampler = options.tracesSampler;
      double? decided;
      if (sampler != null) {
        try {
          decided = sampler(SamplingContext(name: name, op: op));
        } catch (_) {
          decided = null;
        }
      }
      rate =
          (decided ??
                  (sampler != null
                      ? options.tracesSampleRate ?? 0
                      : tracesSampleRate))
              .clamp(0.0, 1.0);
      sampled = !_disposed && _random.nextDouble() < rate;
    }
    final tx = TransactionImpl(
      name: name,
      op: op,
      sink: this,
      sampled: sampled,
      sampleRate: rate,
      traceId: continued?.traceId,
      parentSpanId: continued?.parentSpanId,
      startTimestamp: startTimestamp,
      idleTimeout: idleTimeout,
    );
    _open.add(tx);
    if (options.enableFramesTracking &&
        sampled &&
        (op == 'navigation' || op == 'ui.load')) {
      final counter = _frames[tx] = _FrameCounter();
      tx.beforeFinish.add((t) {
        _frames.remove(t);
        counter.attach(t);
      });
    }
    if (bindToScope) scope.transaction = tx;
    return tx;
  }

  /// The router saw a new screen: the previous screen transaction ends and
  /// a `navigation` transaction named after the route pattern starts,
  /// with a `ui.load.initial_display` span until the next frame.
  void onNavigation(String name) {
    if (_disposed) return;
    final routeName = name.startsWith('/') ? parameterizePath(name) : name;
    final previous = _navigation;
    if (previous != null && !previous.finished) {
      if (previous.name == routeName &&
          DateTime.now().difference(previous.startTimestamp).inMilliseconds <
              500) {
        return; // the router integration and a NavigatorObserver saw the same change
      }
      previous.finish();
    }
    final tx = _navigation = startTransaction(
      routeName,
      'navigation',
      bindToScope: true,
      idleTimeout: options.idleTimeout,
    );
    final ttid = tx.startChild(
      'ui.load.initial_display',
      description: '$routeName initial display',
    );
    try {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (ttid.finished) return;
        ttid.finish();
        final span = ttid as SpanImpl;
        tx.setMeasurement(
          'time_to_initial_display',
          span.endTimestamp!.difference(span.startTimestamp).inMilliseconds,
          unit: 'millisecond',
        );
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    } catch (_) {
      ttid.finish();
    }
  }

  /// `BugCapsule.action` with `enableUserInteractionTracing`.
  void onUserAction(String id) {
    if (_disposed ||
        !options.enableUserInteractionTracing ||
        Scope.current.activeSpan != null) {
      return;
    }
    startTransaction(
      id,
      'ui.action.click',
      bindToScope: true,
      idleTimeout: options.idleTimeout,
    );
  }

  void _appStarted() {
    if (_disposed) return;
    final tx = startTransaction(
      'App Start',
      'app.start.cold',
      startTimestamp: startedAt,
    );
    final ms = DateTime.now().difference(startedAt).inMilliseconds;
    (tx.startChild('app.start.cold', description: 'Cold start') as SpanImpl)
        .finish();
    tx.setMeasurement('app_start_cold', ms, unit: 'millisecond');
    tx.finish();
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_frames.isEmpty) return;
    double refresh = 60;
    try {
      refresh = WidgetsBinding
          .instance
          .platformDispatcher
          .views
          .first
          .display
          .refreshRate;
    } catch (_) {
      // keep 60 Hz
    }
    onFrameDurations([
      for (final t in timings) t.totalSpan,
    ], refreshRate: refresh);
  }

  @visibleForTesting
  void onFrameDurations(List<Duration> frames, {double refreshRate = 60}) {
    final budgetUs = (1000000 / (refreshRate <= 0 ? 60 : refreshRate)).round();
    for (final counter in _frames.values) {
      for (final d in frames) {
        counter.add(d.inMicroseconds, budgetUs);
      }
    }
  }

  /// Starts an `http.client` span under the active span and returns the
  /// headers to add: `traceparent` / `baggage` for URLs matching
  /// `tracePropagationTargets` (never when the request already has a
  /// `traceparent`). Returns null when monitoring is off.
  HttpSpan? startHttpSpan(
    String method,
    Uri url,
    Map<String, Object?> existingHeaders,
  ) {
    if (_disposed) return null;
    final redactor = host.redactor();
    final redacted = redactor.redactUri(url);
    final parent = Scope.current.activeSpan;
    BugCapsuleSpan? span;
    final headers = <String, String>{};
    if (parent != null) {
      final base = redacted
          .replace(query: '', fragment: '')
          .toString()
          .replaceAll(RegExp(r'[?#]+$'), '');
      span =
          parent.startChild(
              'http.client',
              description: '${method.toUpperCase()} $base',
            )
            ..setData('http.request.method', method.toUpperCase())
            ..setData('url', base);
      final lower = {for (final k in existingHeaders.keys) k.toLowerCase(): k};
      if (!lower.containsKey('traceparent') &&
          propagationTargets.matches(url.toString())) {
        headers['traceparent'] = span.toTraceparent();
        final existing = existingHeaders[lower['baggage']];
        headers['baggage'] = Baggage.merge(
          existing is List ? existing.join(',') : existing?.toString(),
          span.toBaggage(),
        );
      }
    }
    return HttpSpan._(
      this,
      span,
      headers,
      method.toUpperCase(),
      redacted.toString(),
    );
  }

  // ---------------------------------------------------------------- sending

  static const _structural = {
    'eventId',
    'feedbackId',
    'sid',
    'did',
    'seq',
    'init',
    'traceId',
    'spanId',
    'parentSpanId',
    'timestamp',
    'startTimestamp',
    'started',
    'capsuleId',
    'release',
    'environment',
    'runtime',
    'debugImages',
    'level',
    'status',
    'errors',
    'duration',
    'measurements',
  };

  /// Every string of the payload through the capture redactor; ids,
  /// timestamps and debug images are kept byte for byte.
  Map<String, Object?> _redact(Map<String, Object?> payload) {
    final out = (host.redactor().redactJson(payload) as Map)
        .cast<String, Object?>();
    for (final k in _structural) {
      if (payload.containsKey(k)) out[k] = payload[k];
    }
    return out;
  }

  void _enqueue(List<EnvelopeItem> items) {
    final outbox = _outbox;
    if (outbox == null || !_sendingAllowed) return;
    final List<int> bytes;
    try {
      bytes = EnvelopeCodec.encode([
        for (final i in items) EnvelopeItem(i.type, _redact(i.payload)),
      ], sdkVersion: sdkVersion);
    } catch (e) {
      debugPrint('[bugcapsule] dropping a monitoring envelope: $e');
      return;
    }
    if (bytes.length > 1024 * 1024) {
      debugPrint(
        '[bugcapsule] dropping a monitoring envelope of ${bytes.length} bytes (limit 1 MiB)',
      );
      return;
    }
    _writes = _writes
        .then((_) => outbox.enqueue(uuidV4(), bytes))
        .then((_) {}, onError: (Object _) {});
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushTimer?.isActive ?? false) return;
    _flushTimer = Timer(const Duration(seconds: 2), () => unawaited(flush()));
  }

  /// Uploads queued envelopes; true when nothing is left (or nothing could be
  /// sent at all: no backend, monitoring off).
  Future<bool> flush({Duration timeout = const Duration(seconds: 10)}) async {
    final outbox = _outbox;
    final transport = this.transport;
    if (outbox == null || transport == null) return true;
    try {
      await _writes.timeout(timeout);
      await host.ensureFreshConfig().timeout(timeout);
      if (!_canUpload) return false;
      await outbox
          .flush(
            upload: (bytes) async {
              final result = await transport.sendEnvelope(
                EnvelopeCodec.restamp(bytes, DateTime.now()),
              );
              if (result.message == 'capture_disabled' || result.unauthorized) {
                unawaited(host.refreshConfig());
              }
              return result;
            },
            allowed: () => _canUpload,
          )
          .timeout(timeout);
      return (await outbox.entries()).isEmpty;
    } catch (e) {
      debugPrint('[bugcapsule] envelope flush failed: $e');
      return false;
    }
  }

  bool get _canUpload => _sendingAllowed && host.uploadsAllowed();

  // -------------------------------------------------------------- lifecycle

  void onLifecycle(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _inForeground = true;
        if (_sessionTracking) {
          _sessions?.onForeground(options.sessionBackgroundTimeout);
        }
        unawaited(flush());
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        if (!_inForeground) return;
        _inForeground = false;
        _sessions?.onBackground();
        unawaited(flush());
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  void startSession() => _sessions?.start();
  void endSession() => _sessions?.end();

  /// A newly fetched remote config: `monitoringEnabled: false` (or the kill
  /// switch) drops queued envelopes.
  void onRemoteConfig(RemoteCaptureConfig next) {
    if (!next.enabled || !next.monitoringEnabled) unawaited(purge());
  }

  Future<void> purge() async {
    await _outbox?.purge();
  }

  @override
  void transactionFinished(TransactionImpl tx) {
    _open.remove(tx);
    _frames.remove(tx);
    if (identical(Scope.root.transaction, tx)) Scope.root.transaction = null;
    if (identical(_navigation, tx)) _navigation = null;
    if (!tx.sampled || tx.discarded || _disposed) return;
    final scope = Scope.current;
    Map<String, Object?>? payload = tx.payload()
      ..['tags'] = sanitizeTags({
        if (options.dist != null) 'dist': options.dist!,
        ...scope.tags,
        ...tx.tags,
      })
      ..['contexts'] = {
        ..._contexts(),
        ...scope.contexts,
        'trace': {'traceId': tx.traceId, 'spanId': tx.spanId, 'op': tx.op},
      };
    final user = _user(scope);
    if (user != null) payload['user'] = user.toJson();
    final hook = options.beforeSendTransaction;
    if (hook != null) {
      try {
        payload = hook(payload);
      } catch (_) {
        // A throwing hook keeps the transaction as it was.
      }
    }
    if (payload != null) {
      _enqueue([EnvelopeItem(EnvelopeItemType.transaction, payload)]);
    }
  }

  /// Ends the session, uploads what is queued and stops.
  Future<void> close({Duration timeout = const Duration(seconds: 5)}) async {
    if (_disposed) return;
    _sessions?.end();
    await flush(timeout: timeout);
    await dispose();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (identical(current, this)) current = null;
    _flushTimer?.cancel();
    for (final tx in List.of(_open)) {
      tx.abandon();
    }
    _open.clear();
    final cb = _timingsCallback;
    if (cb != null) SchedulerBinding.instance.removeTimingsCallback(cb);
    final port = _isolatePort;
    if (port != null) {
      Isolate.current.removeErrorListener(port.sendPort);
      port.close();
    }
    await _writes;
    await _outbox?.close();
  }
}

/// An outgoing request's `http.client` span and the trace headers to add.
class HttpSpan {
  HttpSpan._(this._hub, this.span, this.headers, this._method, this._url)
    : _sw = Stopwatch()..start();

  final MonitoringHub _hub;
  final BugCapsuleSpan? span;

  /// Headers to add to the request (empty when the URL is not a
  /// propagation target or no span is active).
  final Map<String, String> headers;
  final String _method;
  final String _url;
  final Stopwatch _sw;
  bool _done = false;

  /// Ends the span. [breadcrumb]: also add an `http` breadcrumb (when the
  /// capsule recorder is not running; otherwise it derives one itself).
  void finish({
    int? statusCode,
    Object? error,
    bool cancelled = false,
    bool breadcrumb = false,
  }) {
    if (_done) return;
    _done = true;
    final s = span;
    if (s != null) {
      if (statusCode != null && statusCode > 0) {
        s.setData('http.response.status_code', statusCode);
      }
      s.finish(
        status: cancelled
            ? SpanStatus.cancelled
            : statusCode != null && statusCode > 0
            ? SpanStatus.fromHttp(statusCode)
            : SpanStatus.internalError,
      );
    }
    if (breadcrumb) {
      _hub.addBreadcrumb(
        BreadcrumbMapper.http(
          method: _method,
          url: _url,
          status: statusCode,
          durationMs: _sw.elapsedMilliseconds,
          error: error == null
              ? null
              : (cancelled ? 'cancel' : 'connectionError'),
        ),
      );
    }
  }
}

class _FrameCounter {
  int total = 0;
  int slow = 0;
  int frozen = 0;
  int delayUs = 0;

  void add(int us, int budgetUs) {
    total++;
    if (us > 700000) {
      frozen++;
      delayUs += us - budgetUs;
    } else if (us > budgetUs) {
      slow++;
      delayUs += us - budgetUs;
    }
  }

  void attach(TransactionImpl tx) {
    if (total == 0) return;
    tx
      ..setMeasurement('frames_total', total)
      ..setMeasurement('frames_slow', slow)
      ..setMeasurement('frames_frozen', frozen)
      ..setMeasurement('frames_delay', delayUs / 1000, unit: 'millisecond');
  }
}

/// An uncaught error of another isolate: only its text crosses over.
class _IsolateError {
  _IsolateError(this.message);
  final String message;

  @override
  String toString() => message;
}
