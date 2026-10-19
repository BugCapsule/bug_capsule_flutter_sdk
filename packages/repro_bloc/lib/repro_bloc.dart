/// BLoC / Cubit integration for Repro.
///
/// Records creations, events, state changes and errors, snapshots the state
/// of registered BLoCs into periodic checkpoints, and restores it in replay.
///
/// ```dart
/// Repro.init(
///   integrations: [
///     ReproBloc(states: [
///       ReproState<CartBloc, CartState>(
///         toJson: (s) => s.toJson(),
///         fromJson: CartState.fromJson,
///       ),
///     ]),
///   ],
///   ...
/// );
/// ```
library;

import 'dart:async';
import 'dart:convert';

import 'package:bloc/bloc.dart';
import 'package:repro_flutter/repro_flutter.dart';

/// Serializer for the state of one BLoC/Cubit type [B].
class ReproState<B extends BlocBase<S>, S> {
  const ReproState({required this.toJson, required this.fromJson, this.eventToJson});

  final Object? Function(S state) toJson;
  final S Function(Map<String, Object?> json) fromJson;

  /// Optional: serialize events for richer diagnostics.
  final Object? Function(Object event)? eventToJson;

  Type get blocType => B;

  Object? encode(Object? state) => toJson(state as S);

  void restore(BlocBase<Object?> bloc, Map<String, Object?> json) {
    final state = fromJson(json);
    // Restoring is the one place an outside party must set a BLoC's state.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    bloc.emit(state);
  }
}

class ReproBloc extends ReproIntegration {
  ReproBloc({
    this.states = const [],
    this.recordStateData,
    this.maxStateBytes = 64 * 1024,
    this.treatErrorsAsFailures = true,
  });

  final List<ReproState<BlocBase<Object?>, Object?>> states;

  /// Include serialized state in `bloc.state` events. Defaults to true
  /// except in production.
  final bool? recordStateData;
  final int maxStateBytes;

  /// Report `onError` as a failure (deduplicated with uncaught errors).
  final bool treatErrorsAsFailures;

  late ReproSession _session;
  late final _ReproBlocObserver _observer = _ReproBlocObserver(this);
  final Map<String, BlocBase<Object?>> _live = {};
  final Map<Type, int> _ordinals = {};
  final Expando<String> _keys = Expando('repro.blocKey');
  Map<String, Object?> _restoreData = const {};
  final Set<String> _unserializable = {};
  final Set<String> _oversized = {};

  @override
  String get name => 'bloc';

  bool get _withData => recordStateData ?? _session.mode != CaptureMode.production;

  ReproState<BlocBase<Object?>, Object?>? _registration(BlocBase<Object?> bloc) {
    for (final s in states) {
      if (s.blocType == bloc.runtimeType) return s;
    }
    return null;
  }

  @override
  Future<void> setUp(ReproSession session) async {
    _session = session;
    _observer.parent = Bloc.observer is _ReproBlocObserver ? null : Bloc.observer;
    Bloc.observer = _observer;
  }

  @override
  Object? snapshot(CheckpointKind kind) {
    // A launch checkpoint is taken before any BLoC exists; replay
    // re-executes the session instead of injecting state.
    if (kind == CheckpointKind.launch) return null;
    final data = <String, Object?>{};
    for (final entry in _live.entries) {
      final bloc = entry.value;
      final registration = _registration(bloc);
      if (registration == null) {
        _unserializable.add(bloc.runtimeType.toString());
        continue;
      }
      final json = _session.redactor.redactJson(registration.encode(bloc.state));
      if (jsonEncode(json).length > maxStateBytes) {
        _oversized.add(entry.key);
        continue;
      }
      data[entry.key] = {
        'bloc': bloc.runtimeType.toString(),
        'stateType': bloc.state.runtimeType.toString(),
        'state': json,
      };
    }
    return data;
  }

  @override
  Future<void> restore(Object? data, ReproSession session) async {
    if (data is Map) _restoreData = data.cast<String, Object?>();
  }

  @override
  void describeEligibility(EligibilityBuilder eligibility, RecordedWindow window) {
    if (window.checkpoint.kind != CheckpointKind.periodic) return;
    for (final type in _unserializable) {
      eligibility.missing('bloc.state', '$type has no ReproState serializer');
    }
    for (final key in _oversized) {
      eligibility.missing('bloc.state', '$key state exceeds $maxStateBytes bytes; add a projection');
    }
  }

  /// `<Type>#<n>` — the n-th instance of this type created in the session.
  /// Deterministic as long as replay follows the same path.
  String _assignKey(BlocBase<Object?> bloc) {
    final n = _ordinals.update(bloc.runtimeType, (v) => v + 1, ifAbsent: () => 0);
    final key = '${bloc.runtimeType}#$n';
    _keys[bloc] = key;
    return key;
  }

  String _keyOf(BlocBase<Object?> bloc) => _keys[bloc] ?? _assignKey(bloc);

  void _onCreate(BlocBase<Object?> bloc) {
    final key = _assignKey(bloc);
    _live[key] = bloc;
    _session.record(EventTypes.blocCreate, {'bloc': bloc.runtimeType.toString(), 'key': key});

    final replay = _session.replay;
    final saved = _restoreData[key];
    if (replay == null || saved is! Map) return;
    final registration = _registration(bloc);
    if (registration == null) {
      replay.diverge('bloc.unrestored', '$key has no ReproState serializer');
      return;
    }
    // onCreate runs inside the BlocBase constructor, before the subclass
    // constructor body. Restore once construction has finished.
    scheduleMicrotask(() {
      if (bloc.isClosed) return;
      try {
        registration.restore(bloc, (saved['state'] as Map).cast<String, Object?>());
      } catch (e) {
        replay.diverge('bloc.unrestored', '$key: $e');
      }
    });
  }

  void _onEvent(Bloc<Object?, Object?> bloc, Object? event) {
    _session.replay?.activity();
    if (!_session.isRecording) return;
    final registration = _registration(bloc);
    final toJson = registration?.eventToJson;
    _session.record(EventTypes.blocEvent, {
      'bloc': bloc.runtimeType.toString(),
      'key': _keyOf(bloc),
      'event': event.runtimeType.toString(),
      if (_withData && toJson != null && event != null)
        'data': _session.redactor.redactJson(toJson(event)),
    });
  }

  void _onChange(BlocBase<Object?> bloc, Change<Object?> change) {
    _session.replay?.activity();
    if (!_session.isRecording) return;
    final registration = _registration(bloc);
    Object? data;
    if (_withData && registration != null) {
      try {
        data = _session.redactor.redactJson(registration.encode(change.nextState));
        if (jsonEncode(data).length > maxStateBytes) data = null;
      } catch (_) {
        data = null;
      }
    }
    _session.record(EventTypes.blocState, {
      'bloc': bloc.runtimeType.toString(),
      'key': _keyOf(bloc),
      'state': change.nextState.runtimeType.toString(),
      'data': ?data,
    });
  }

  void _onError(BlocBase<Object?> bloc, Object error, StackTrace stackTrace) {
    _session.replay?.activity();
    _session.record(EventTypes.blocError, {
      'bloc': bloc.runtimeType.toString(),
      'key': _keyOf(bloc),
      'error': '$error',
    });
    if (treatErrorsAsFailures) _session.reportError(error, stackTrace);
  }

  void _onClose(BlocBase<Object?> bloc) {
    final key = _keyOf(bloc);
    _live.remove(key);
    _session.record(EventTypes.blocClose, {'bloc': bloc.runtimeType.toString(), 'key': key});
  }
}

class _ReproBlocObserver extends BlocObserver {
  _ReproBlocObserver(this._integration);

  final ReproBloc _integration;
  BlocObserver? parent;

  @override
  void onCreate(BlocBase<dynamic> bloc) {
    super.onCreate(bloc);
    parent?.onCreate(bloc);
    _integration._onCreate(bloc);
  }

  @override
  void onEvent(Bloc<dynamic, dynamic> bloc, Object? event) {
    super.onEvent(bloc, event);
    parent?.onEvent(bloc, event);
    _integration._onEvent(bloc, event);
  }

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    parent?.onChange(bloc, change);
    _integration._onChange(bloc, change);
  }

  @override
  void onTransition(Bloc<dynamic, dynamic> bloc, Transition<dynamic, dynamic> transition) {
    super.onTransition(bloc, transition);
    parent?.onTransition(bloc, transition);
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    super.onError(bloc, error, stackTrace);
    parent?.onError(bloc, error, stackTrace);
    _integration._onError(bloc, error, stackTrace);
  }

  @override
  void onClose(BlocBase<dynamic> bloc) {
    super.onClose(bloc);
    parent?.onClose(bloc);
    _integration._onClose(bloc);
  }
}
