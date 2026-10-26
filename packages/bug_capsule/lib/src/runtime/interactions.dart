import 'dart:async';

import 'package:flutter/foundation.dart' show mustCallSuper;

import '../core/core.dart';
import '../version.dart';
import 'integration.dart';

/// Implemented by the runtime (and by test sessions): what interaction
/// integrations need beyond [BugCapsuleSession].
abstract interface class InteractionSession implements BugCapsuleSession {
  InteractionHost get interactions;
}

/// Session-wide state shared by every interaction adapter: the payload
/// budget and active-connection limit when capturing, the scheduler when
/// replaying, and the remote kill switch.
class InteractionHost {
  InteractionHost({InteractionLimits limits = const InteractionLimits()})
    : budget = PayloadBudget(limits);

  final PayloadBudget budget;

  /// Adapter ids remote config turned off (`disabledAdapters`).
  Set<String> disabledAdapters = const {};
  int _active = 0;

  /// Non-null in replay mode.
  ReplayInteractions? replay;

  InteractionLimits get limits => budget.limits;
  set limits(InteractionLimits value) => budget.limits = value;

  /// Claims one of the [InteractionLimits.maxActive] capture slots.
  bool acquire() {
    if (_active >= limits.maxActive) return false;
    _active++;
    return true;
  }

  void release() {
    if (_active > 0) _active--;
  }
}

/// Base class of integrations that record replay dependencies
/// (capsule-v2): WebSockets, platform channels and native SDK adapters.
///
/// Subclasses describe their adapter ([adapter], [kind], [schema],
/// [operations]) and use [encoder], [recordInteraction] and
/// [replayInteractions]. The runtime adds a `manifest.dependencies` entry
/// for every adapter that recorded events in the capsule window, which
/// makes the capsule spec v2.
abstract class InteractionIntegration extends BugCapsuleIntegration {
  InteractionIntegration({
    this.captureBinary = false,
    this.redactedReplayable = false,
  });

  /// Adapter identity, e.g. `bug_capsule.web_socket_channel`.
  String get adapter;

  /// `websocket`, `platform.channel` or `native` (see [DependencyKinds]).
  String get kind;

  /// Version of this adapter's event payloads.
  int get schema => 1;

  /// Payload schemas this adapter can replay.
  bool supportsSchema(int schema) => schema == this.schema;

  String get adapterVersion => bugCapsuleVersion;

  /// `manifest.dependencies[].id`; one per adapter instance in a session.
  String get dependencyId => name;

  /// False for capture-only (diagnostic) adapters: their events are never
  /// served during replay and never block preflight.
  bool get replayable => true;

  /// Operations this adapter records, for the manifest.
  List<String> get operations;

  /// Package -> version this adapter was qualified against.
  Map<String, String> get tested => const {};

  /// Keep binary payloads (bytes, typed arrays) instead of metadata only.
  final bool captureBinary;

  /// Values changed by redaction can still be replayed (the app does not
  /// branch on the redacted fields).
  final bool redactedReplayable;

  BugCapsuleSession? _session;
  InteractionHost? _host;
  final DependencyStats stats = DependencyStats();
  PayloadEncoder? _encoder;

  BugCapsuleSession? get session => _session;
  InteractionHost? get host => _host;

  @override
  @mustCallSuper
  Future<void> setUp(BugCapsuleSession session) async {
    _session = session;
    final host = _host = session is InteractionSession
        ? session.interactions
        : null;
    if (host == null) return;
    _encoder = PayloadEncoder(
      redactor: () => session.redactor,
      budget: host.budget,
      stats: stats,
      now: session.now,
      captureBinary: captureBinary,
      redactedReplayable: redactedReplayable,
    );
  }

  /// Whether this adapter records now: the session records, setup ran
  /// and remote config did not disable the adapter.
  bool get capturing {
    final s = _session;
    final h = _host;
    return s != null &&
        h != null &&
        s.isRecording &&
        s.replay == null &&
        !h.disabledAdapters.contains(adapter);
  }

  /// The replay scheduler, when replaying with this adapter's dependency
  /// in the capsule.
  ReplayInteractions? get replayInteractions {
    final r = _host?.replay;
    if (r == null || _session?.replay == null) return null;
    return r.serves(dependencyId) ? r : null;
  }

  /// True while replaying a capsule that has no recording for this
  /// adapter: every operation is then unrecorded and must fail, never reach
  /// the real dependency.
  bool get replayingWithoutRecording =>
      _session?.replay != null && replayInteractions == null;

  /// Encodes payloads with the session's redaction and limits.
  PayloadEncoder get encoder {
    final e = _encoder;
    if (e == null) throw StateError('$name is not set up');
    return e;
  }

  /// Records an interaction event for this dependency.
  void recordInteraction(String type, Map<String, Object?> data) {
    final s = _session;
    if (s == null) return;
    stats.events++;
    s.record(type, {'dep': dependencyId, ...data});
  }

  /// Records a divergence during replay.
  void diverge(String type, String detail) =>
      _session?.replay?.diverge(type, detail);

  /// Connections or subscriptions logically open now, for periodic
  /// checkpoints (`checkpoint.data.interactions.open`). Entries are
  /// `{type, id}` plus `restorable: true` only when this adapter can
  /// restore them from its own checkpoint data.
  List<Map<String, Object?>> openInteractions() => const [];

  /// The `manifest.dependencies` entry for [window], or null when this
  /// adapter recorded nothing in it.
  CapsuleDependency? dependency(RecordedWindow window) {
    var events = 0;
    for (final e in window.events) {
      if (e.data['dep'] == dependencyId &&
          InteractionTypes.isInteraction(e.type)) {
        events++;
      }
    }
    if (events == 0) return null;
    final gaps = stats.gaps;
    return CapsuleDependency(
      id: dependencyId,
      kind: kind,
      adapter: adapter,
      adapterVersion: adapterVersion,
      schema: schema,
      required: replayable,
      coverage: !replayable
          ? DependencyCoverage.diagnostic
          : gaps.isEmpty
          ? DependencyCoverage.complete
          : DependencyCoverage.partial,
      operations: operations,
      tested: tested,
      gaps: gaps,
      stats: {...stats.toJson(), 'events': events},
    );
  }

  @override
  @mustCallSuper
  void describeEligibility(
    EligibilityBuilder eligibility,
    RecordedWindow window,
  ) {
    final dependency = this.dependency(window);
    if (dependency == null || dependency.gaps.isEmpty || !replayable) return;
    eligibility.missing(
      'dependency.$dependencyId',
      '$adapter: ${[for (final g in dependency.gaps) g.count == null ? g.code : '${g.code}×${g.count}'].join(', ')}',
    );
  }
}

/// Replay of recorded interactions with timers: wraps an
/// [InteractionScript], arms a timer for the next due delivery and reports
/// the script's divergences.
class ReplayInteractions {
  ReplayInteractions(
    this.script, {
    required this.dependencies,
    required this.diverge,
    required this.activity,
  });

  final InteractionScript script;

  /// Dependency ids this replay serves.
  final Set<String> dependencies;
  final void Function(String type, String detail) diverge;

  /// Tells idle compression the app is doing something.
  final void Function() activity;

  Timer? _timer;
  bool _finished = false;

  bool serves(String dependencyId) => dependencies.contains(dependencyId);

  int get now => script.clock();

  /// Earliest due delivery; idle compression must not skip past it.
  int? get nextDueAt => script.nextDueAt;

  RecordedInteraction? take(String dep, String type, String key) =>
      _after(script.take(dep, type, key));

  RecordedInteraction? takeNext(String scope, Set<String> types) =>
      _after(script.takeNext(scope, types));

  bool hasUnconsumed(String dep, String type, String prefix) =>
      script.hasUnconsumed(dep, type, prefix);

  void bind(String scope, void Function(RecordedInteraction) handler) {
    script.bind(scope, handler);
    _arm();
  }

  void unbind(String scope) => script.unbind(scope);

  bool isBound(String scope) => script.isBound(scope);

  int scheduledIn(String scope) => script.scheduledIn(scope);

  T _after<T>(T value) {
    _arm();
    return value;
  }

  void runStarted() {
    script.runStarted(now);
    _arm();
  }

  /// The replay clock jumped (idle compression): re-arm for the new time.
  void clockJumped() => _arm();

  void _arm() {
    if (_finished) return;
    _timer?.cancel();
    _timer = null;
    final next = script.nextDueAt;
    final waiting = script.hasWaiting;
    if (next == null && !waiting) return;
    final ms = next == null ? 250 : (next - now).clamp(0, 1 << 30);
    // Waiting events are re-checked so a missing handler times out.
    final delay = waiting && ms > 250 ? 250 : ms;
    _timer = Timer(Duration(milliseconds: delay), _fire);
  }

  void _fire() {
    _timer = null;
    final delivered = script.pump();
    _flush();
    if (delivered > 0) activity();
    _arm();
  }

  void _flush() {
    for (final (type, detail) in script.takeDivergences()) {
      diverge(type, detail);
    }
  }

  /// Stops timers and reports unmatched interactions.
  void finish(int? failureT) {
    _finished = true;
    _timer?.cancel();
    _flush();
    for (final (type, detail) in script.unused(failureT)) {
      diverge(type, detail);
    }
  }
}

/// Failure of a native adapter operation, recorded as `native.error` and
/// rethrown during replay unless the adapter rebuilds its own exception.
class NativeAdapterException implements Exception {
  const NativeAdapterException(this.code, [this.message, this.details]);

  final String code;
  final String? message;
  final Object? details;

  @override
  String toString() =>
      'NativeAdapterException($code${message == null ? '' : ', $message'})';
}

/// Base class for adapters of third-party SDKs (Firebase, location, maps,
/// payments): records the app-visible results of selected operations and,
/// during replay, hands them back without calling the SDK (capsule-v2
/// §4.3). The real dependency is never contacted during replay, also not on
/// a fixture miss.
///
/// ```dart
/// class WeatherAdapter extends NativeAdapter {
///   @override String get name => 'weather';
///   @override String get adapter => 'example.weather';
///   @override List<String> get operations => ['forecast'];
///
///   Future<Forecast> forecast(String city) => call(
///     'forecast',
///     args: {'city': city},
///     invoke: () => api.forecast(city),
///     encode: (f) => f.toJson(),
///     decode: (json) => Forecast.fromJson(json as Map<String, Object?>),
///   );
/// }
/// ```
abstract class NativeAdapter extends InteractionIntegration {
  NativeAdapter({super.captureBinary, super.redactedReplayable});

  @override
  String get kind => DependencyKinds.native;

  final OccurrenceCounter _occurrences = OccurrenceCounter();
  int _nextOp = 0;
  int _nextSub = 0;

  /// The code, message and details recorded for [error] (override to read
  /// SDK exception types, e.g. `FirebaseException.code`).
  (String, String?, Object?) describeError(Object error) => switch (error) {
    final NativeAdapterException e => (e.code, e.message, e.details),
    _ => (error.runtimeType.toString(), '$error', null),
  };

  /// The exception thrown in replay for a recorded error (override to
  /// rebuild SDK exception types).
  Object rebuildError(String code, String? message, Object? details) =>
      NativeAdapterException(code, message, details);

  /// Calls are matched within their adapter instance (capsule-v2 §5).
  static String _scope(String operation, String? instance) =>
      instance == null ? operation : '$operation@$instance';

  String _key(String operation, Object? args, String? instance) =>
      interactionKey(_scope(operation, instance), null, encoder.keyInput(args));

  Object _unrecorded(String operation, {bool subscription = false}) {
    diverge('native.unrecorded', '$adapter $operation (not in the capsule)');
    return rebuildError(
      'bugcapsule.unrecorded',
      'no recorded $operation${subscription ? ' subscription' : ''} in this capsule',
      null,
    );
  }

  /// Runs a one-shot operation. Capture: calls [invoke] and records its
  /// result or error. Replay: returns the recorded result through [decode]
  /// (or throws the recorded error); [invoke] is not called. Unrecorded
  /// calls fail with `bugcapsule.unrecorded`, also when the capsule has no
  /// recording for this adapter at all.
  ///
  /// [encode] returns a value [TypedValue] can encode (JSON values, typed
  /// data, maps); [decode] receives that value back, decoded.
  Future<T> call<T>(
    String operation, {
    Object? args,
    required Future<T> Function() invoke,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
    String? instance,
    String? parent,
  }) async {
    final replay = replayInteractions;
    if (replay != null) {
      return _replayCall(replay, operation, args, decode, instance);
    }
    if (replayingWithoutRecording) return Future.error(_unrecorded(operation));
    if (!capturing) return invoke();
    final key = _key(operation, args, instance);
    final op = 'o${_nextOp++}';
    recordInteraction(InteractionTypes.nativeCall, {
      'op': op,
      'operation': operation,
      'instance': ?instance,
      'parent': ?parent,
      'args': encoder.encode(args).toJson(),
      'key': key,
      'occurrence': _occurrences.next(key),
    });
    try {
      final value = await invoke();
      _recordResult(op, () => encode(value));
      return value;
    } catch (error) {
      _recordError({'op': op}, error);
      rethrow;
    }
  }

  void _recordResult(String op, Object? Function() encode) {
    InteractionPayload payload;
    try {
      payload = encoder.encode(encode());
    } catch (e) {
      stats.gap(DependencyGaps.captureFailed, 'result not encodable: $e');
      payload = const InteractionPayload(
        mode: PayloadMode.omitted,
        replayable: false,
      );
    }
    recordInteraction(InteractionTypes.nativeResult, {
      'op': op,
      'value': payload.toJson(),
    });
  }

  void _recordError(Map<String, Object?> id, Object error) {
    final (code, message, details) = describeError(error);
    recordInteraction(InteractionTypes.nativeError, {
      ...id,
      'code': code,
      'message': ?message,
      if (details != null) 'details': encoder.encode(details).toJson(),
    });
  }

  Future<T> _replayCall<T>(
    ReplayInteractions replay,
    String operation,
    Object? args,
    T Function(Object? json) decode,
    String? instance,
  ) {
    final key = _key(operation, args, instance);
    final recorded = replay.take(
      dependencyId,
      InteractionTypes.nativeCall,
      key,
    );
    if (recorded == null) {
      final mismatch = replay.hasUnconsumed(
        dependencyId,
        InteractionTypes.nativeCall,
        '${_scope(operation, instance)}|',
      );
      diverge(
        mismatch ? 'native.mismatch' : 'native.unrecorded',
        '$adapter $operation${mismatch ? ': arguments differ from the recording' : ''}',
      );
      return Future.error(
        rebuildError(
          'bugcapsule.unrecorded',
          'no recorded $operation for these arguments',
          null,
        ),
      );
    }
    final completer = Completer<T>();
    final scope = recorded.scope;
    replay.bind(scope, (r) {
      replay.unbind(scope);
      if (r.type == InteractionTypes.nativeError) {
        completer.completeError(_errorOf(r));
        return;
      }
      final payload = r.payload('value');
      if (payload == null || !payload.replayable) {
        diverge('native.noPayload', '$adapter $operation');
        completer.completeError(
          rebuildError('bugcapsule.noPayload', 'result was not recorded', null),
        );
        return;
      }
      try {
        completer.complete(decode(payload.decoded));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Object _errorOf(RecordedInteraction r) => rebuildError(
    r.data['code'] as String? ?? 'unknown',
    r.data['message'] as String?,
    r.payload('details')?.decoded,
  );

  /// Wraps a stream-shaped operation (listeners, position updates, map
  /// events). Capture: subscribes to [open] and records events, errors,
  /// completion and cancellation. Replay: a stream of the recorded events,
  /// delivered after the app listens, with the recorded timing.
  Stream<T> subscribe<T>(
    String operation, {
    Object? args,
    required Stream<T> Function() open,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
    String? instance,
    String? parent,
  }) {
    final replay = replayInteractions;
    if (replay != null) {
      return _replaySubscribe(replay, operation, args, decode, instance);
    }
    if (replayingWithoutRecording) {
      return Stream.error(_unrecorded(operation, subscription: true));
    }
    if (!capturing) return open();
    late StreamController<T> controller;
    StreamSubscription<T>? inner;
    String? sub;
    var index = 0;
    var active = false;
    void stop({required bool cancelled}) {
      if (sub == null) return;
      if (cancelled) {
        recordInteraction(InteractionTypes.nativeCancel, {'sub': sub});
      }
      sub = null;
      if (active) host?.release();
      active = false;
    }

    controller = StreamController<T>(
      onListen: () {
        if (capturing && (active = host?.acquire() ?? false)) {
          final key = _key(operation, args, instance);
          sub = 'n${_nextSub++}';
          recordInteraction(InteractionTypes.nativeSubscribe, {
            'sub': sub,
            'operation': operation,
            'instance': ?instance,
            'parent': ?parent,
            'args': encoder.encode(args).toJson(),
            'key': key,
            'occurrence': _occurrences.next(key),
          });
        } else if (capturing) {
          stats.gap(DependencyGaps.connectionsLimit);
        }
        inner = open().listen(
          (value) {
            final s = sub;
            if (s != null) {
              InteractionPayload payload;
              try {
                payload = encoder.encode(encode(value));
              } catch (e) {
                stats.gap(DependencyGaps.captureFailed, 'event: $e');
                payload = const InteractionPayload(
                  mode: PayloadMode.omitted,
                  replayable: false,
                );
              }
              recordInteraction(InteractionTypes.nativeEvent, {
                'sub': s,
                'index': index++,
                'value': payload.toJson(),
              });
            }
            controller.add(value);
          },
          onError: (Object error, StackTrace st) {
            final s = sub;
            if (s != null) _recordError({'sub': s}, error);
            controller.addError(error, st);
          },
          onDone: () {
            final s = sub;
            if (s != null) {
              recordInteraction(InteractionTypes.nativeDone, {'sub': s});
            }
            stop(cancelled: false);
            controller.close();
          },
        );
      },
      onPause: () => inner?.pause(),
      onResume: () => inner?.resume(),
      onCancel: () {
        stop(cancelled: true);
        return inner?.cancel();
      },
    );
    return controller.stream;
  }

  Stream<T> _replaySubscribe<T>(
    ReplayInteractions replay,
    String operation,
    Object? args,
    T Function(Object? json) decode,
    String? instance,
  ) {
    late StreamController<T> controller;
    RecordedInteraction? recorded;
    controller = StreamController<T>(
      onListen: () {
        final key = _key(operation, args, instance);
        recorded = replay.take(
          dependencyId,
          InteractionTypes.nativeSubscribe,
          key,
        );
        final r = recorded;
        if (r == null) {
          final mismatch = replay.hasUnconsumed(
            dependencyId,
            InteractionTypes.nativeSubscribe,
            '${_scope(operation, instance)}|',
          );
          diverge(
            mismatch ? 'native.mismatch' : 'native.unrecorded',
            '$adapter $operation',
          );
          controller
            ..addError(
              rebuildError(
                'bugcapsule.unrecorded',
                'no recorded $operation subscription for these arguments',
                null,
              ),
            )
            ..close();
          return;
        }
        replay.bind(r.scope, (e) {
          switch (e.type) {
            case InteractionTypes.nativeEvent:
              final payload = e.payload('value');
              if (payload == null || !payload.replayable) {
                diverge('native.noPayload', '$adapter $operation event');
                return;
              }
              try {
                controller.add(decode(payload.decoded));
              } catch (err, st) {
                controller.addError(err, st);
              }
            case InteractionTypes.nativeError:
              controller.addError(_errorOf(e));
            case InteractionTypes.nativeDone:
              replay.unbind(r.scope);
              controller.close();
          }
        });
      },
      onCancel: () {
        final r = recorded;
        if (r == null) return;
        replay.takeNext(r.scope, const {InteractionTypes.nativeCancel});
        replay.unbind(r.scope);
      },
    );
    return controller.stream;
  }
}
