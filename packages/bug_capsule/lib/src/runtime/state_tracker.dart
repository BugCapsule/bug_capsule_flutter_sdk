import 'dart:convert';

import '../core/core.dart';
import 'package:flutter/foundation.dart';

import 'integration.dart';

/// Base for state-management integrations without a global observer
/// (ChangeNotifier, GetX, MobX stores): the app hands each state object to
/// [trackObject] where it creates it.
///
/// A tracked object is keyed `<id>#<n>` (the n-th object tracked with that
/// id in the session), records `<name>.create` and `<name>.change` events,
/// is snapshotted into periodic checkpoints when it has a `toJson`, and is
/// restored in replay as soon as it is tracked again. Objects are held
/// weakly: tracking never keeps one alive.
abstract class TrackedStateIntegration extends BugCapsuleIntegration {
  TrackedStateIntegration({this.recordStateData, this.maxStateBytes = 64 * 1024});

  /// Include serialized state in change events. Defaults to true except in
  /// production.
  final bool? recordStateData;
  final int maxStateBytes;

  BugCapsuleSession? _session;
  final Map<String, _Tracked> _live = {};
  final Map<String, int> _ordinals = {};
  final Expando<String> _keys = Expando('bugcapsule.trackedKey');

  /// What [trackObject]'s `subscribe` returned, for [untrack]. An Expando
  /// so a subscription that references its object does not keep it alive.
  final Expando<Object> _subscriptions = Expando('bugcapsule.trackedSubscription');
  Map<String, Object?> _restoreData = const {};
  final Set<String> _unserializable = {};
  final Set<String> _oversized = {};

  /// Non-null once set up.
  @protected
  BugCapsuleSession? get session => _session;

  bool get _withData => recordStateData ?? _session?.mode != CaptureMode.production;

  @override
  @mustCallSuper
  Future<void> setUp(BugCapsuleSession session) async => _session = session;

  /// Starts recording [object] and returns it.
  ///
  /// [subscribe] makes `onChange` run on every change of [object] and
  /// returns a subscription handle that [unsubscribe] cancels. [toJson]
  /// makes its state part of periodic checkpoints and events; [restore] puts
  /// checkpoint state back in replay (run through [runRestore]). Without
  /// them, periodic checkpoints that include this object make the capsule
  /// partial. Objects tracked before setup are returned untracked.
  @protected
  T trackObject<T extends Object>(
    T object, {
    required String id,
    required Object? Function(T object, void Function() onChange) subscribe,
    Object? Function(T object)? toJson,
    void Function(T object, Map<String, Object?> json)? restore,
  }) {
    final session = _session;
    if (session == null || _keys[object] != null) return object;
    final key = '$id#${_ordinals.update(id, (v) => v + 1, ifAbsent: () => 0)}';
    _keys[object] = key;
    final tracked = _Tracked(
      WeakReference(object),
      object.runtimeType.toString(),
      toJson == null ? null : (o) => toJson(o as T),
    );
    _live[key] = tracked;
    if (session.isRecording) {
      session.record('$name.create', {'type': tracked.type, 'key': key});
    }

    final replay = session.replay;
    final saved = _restoreData[key];
    if (replay != null && saved != null) {
      if (saved is! Map || saved['state'] is! Map) {
        // Redacted on device, or not serializable.
        replay.diverge('$name.unrestored', '$key: state was not captured');
      } else if (restore == null) {
        replay.diverge('$name.unrestored', '$key has no restore callback');
      } else {
        try {
          runRestore(() => restore(object, (saved['state'] as Map).cast<String, Object?>()));
        } catch (e) {
          replay.diverge('$name.unrestored', '$key: $e');
        }
      }
    }

    // Subscribed after restoring: putting state back is not a change.
    try {
      final subscription = subscribe(object, () => _onChange(key, tracked));
      if (subscription != null) _subscriptions[object] = subscription;
    } catch (_) {
      // Recording what changes is best effort; snapshots still work.
    }
    return object;
  }

  /// Runs an app `restore` callback, e.g. inside an action.
  @protected
  void runRestore(void Function() body) => body();

  /// Cancels a subscription returned by `subscribe`.
  @protected
  void unsubscribe(Object object, Object subscription);

  /// Stops recording [object] (e.g. before disposing it). Objects that are
  /// garbage collected are dropped without this.
  void untrack(Object object) {
    final key = _keys[object];
    if (key == null) return;
    _live.remove(key);
    final subscription = _subscriptions[object];
    _subscriptions[object] = null;
    if (subscription != null) {
      try {
        unsubscribe(object, subscription);
      } catch (_) {}
    }
  }

  void _onChange(String key, _Tracked tracked) {
    final session = _session;
    if (session == null) return;
    session.replay?.activity();
    if (!session.isRecording || !_live.containsKey(key)) return;
    Object? data;
    if (_withData) {
      data = _encode(session, tracked);
      if ((_jsonLength(data) ?? maxStateBytes + 1) > maxStateBytes) data = null;
    }
    session.record('$name.change', {'type': tracked.type, 'key': key, 'data': ?data});
  }

  /// Redacted JSON of the tracked object's state, or null when it has no
  /// serializer, is gone, or its serializer throws (e.g. after dispose).
  Object? _encode(BugCapsuleSession session, _Tracked tracked) {
    final object = tracked.ref.target;
    final toJson = tracked.toJson;
    if (object == null || toJson == null) return null;
    try {
      return session.redactor.redactJson(toJson(object));
    } catch (_) {
      return null;
    }
  }

  /// Encoded size, or null when [json] is not JSON (a serializer returned
  /// an object without `toJson`).
  static int? _jsonLength(Object? json) {
    try {
      return jsonEncode(json).length;
    } catch (_) {
      return null;
    }
  }

  @override
  Object? snapshot(CheckpointKind kind) {
    // A launch checkpoint is taken before the app creates its state;
    // replay re-executes the session instead of injecting state.
    if (kind == CheckpointKind.launch) return null;
    final session = _session;
    if (session == null) return null;
    _live.removeWhere((_, tracked) => tracked.ref.target == null);
    final data = <String, Object?>{};
    for (final MapEntry(:key, value: tracked) in _live.entries) {
      if (tracked.toJson == null) {
        _unserializable.add(key);
        continue;
      }
      final json = _encode(session, tracked);
      if (json == null) continue;
      final length = _jsonLength(json);
      if (length == null) {
        _unserializable.add(key);
        continue;
      }
      if (length > maxStateBytes) {
        _oversized.add(key);
        continue;
      }
      data[key] = {'type': tracked.type, 'state': json};
    }
    return data;
  }

  @override
  Future<void> restore(Object? data, BugCapsuleSession session) async {
    if (data is Map) _restoreData = data.cast<String, Object?>();
  }

  @override
  @mustCallSuper
  void describeEligibility(EligibilityBuilder eligibility, RecordedWindow window) {
    if (window.checkpoint.kind != CheckpointKind.periodic) return;
    for (final key in _unserializable) {
      eligibility.missing('$name.state', '$key is tracked without a JSON serializer');
    }
    for (final key in _oversized) {
      eligibility.missing('$name.state', '$key state exceeds $maxStateBytes bytes; add a projection');
    }
  }
}

class _Tracked {
  _Tracked(this.ref, this.type, this.toJson);

  final WeakReference<Object> ref;
  final String type;
  final Object? Function(Object object)? toJson;
}
