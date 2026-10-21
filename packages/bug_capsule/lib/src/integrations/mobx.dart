/// MobX integration for BugCapsule.
///
/// Records, through MobX's spy, every observable write and action of the
/// app, and reaction errors as failures. Stores the app hands to
/// [BugCapsuleMobx.track] also record their serialized state on every
/// change, are snapshotted into periodic checkpoints, and are restored (in
/// an action) in replay as soon as they are tracked again.
///
/// ```dart
/// final bugCapsuleMobx = BugCapsuleMobx();
///
/// Provider(
///   create: (_) => bugCapsuleMobx.track(CartStore(), id: 'cart',
///       toJson: (s) => s.toJson(), restore: (s, json) => s.replaceWith(json)),
///   child: ...,
/// );
/// ```
///
/// Setting up enables the spy on the context (`mainContext` by default) for
/// sessions that record or replay. An app that later assigns a new
/// `ReactiveConfig` must keep `isSpyEnabled: true`, or observable and
/// action events stop.
library;

import 'package:mobx/mobx.dart';
import '../runtime/runtime.dart';

class BugCapsuleMobx extends TrackedStateIntegration {
  BugCapsuleMobx({
    super.recordStateData,
    super.maxStateBytes,
    ReactiveContext? context,
    this.recordObservables = true,
    this.treatReactionErrorsAsFailures = true,
  }) : _context = context ?? mainContext;

  final ReactiveContext _context;

  /// Record a `mobx.observable` event for every observable write. Turn off
  /// for apps that write observables at frame rate; actions, tracked stores
  /// and errors are still recorded.
  final bool recordObservables;

  /// Report errors thrown inside reactions (autorun, reaction, Observer
  /// builders) as failures, deduplicated with uncaught errors.
  final bool treatReactionErrorsAsFailures;

  bool _hooked = false;

  /// Names of the reactions and actions BugCapsule runs itself; they are not
  /// app activity.
  static const _ownPrefix = 'BugCapsule.';

  @override
  String get name => 'mobx';

  @override
  Future<void> setUp(BugCapsuleSession session) async {
    await super.setUp(session);
    if (_hooked || !(session.isRecording || session.isReplaying)) return;
    _hooked = true;
    _context.config = _context.config.clone(isSpyEnabled: true);
    _context.spy(_onSpy);
    _context.onReactionError(_onReactionError);
  }

  /// Records [store] as `<id>#<n>` (the n-th store tracked with this [id]
  /// in the session) and returns it.
  ///
  /// [toJson] (which must read the store's observables) makes its state part
  /// of change events and periodic checkpoints; [restore] puts checkpoint
  /// state back in replay, inside an action. Without them, periodic
  /// checkpoints that include this store make the capsule partial.
  S track<S extends Object>(
    S store, {
    required String id,
    Object? Function(S store)? toJson,
    void Function(S store, Map<String, Object?> json)? restore,
  }) =>
      trackObject(
        store,
        id: id,
        toJson: toJson,
        restore: restore,
        subscribe: (s, onChange) => toJson == null
            ? null
            : reaction<Object?>((_) => toJson(s), (_) => onChange(), name: '$_ownPrefix$id', context: _context),
      );

  @override
  void runRestore(void Function() body) => runInAction(body, name: '${_ownPrefix}restore', context: _context);

  @override
  void unsubscribe(Object object, Object subscription) => (subscription as ReactionDisposer)();

  void _onSpy(SpyEvent event) {
    try {
      final session = this.session;
      if (session == null) return;
      switch (event) {
        // Creation reports the initial value as a finished (`isEnd`) event.
        case ObservableValueSpyEvent(:final name, :final newValue, isEnd: false):
          session.replay?.activity();
          if (recordObservables && session.isRecording) {
            session.record(EventTypes.mobxObservable, _describeWrite(session, name, newValue));
          }
        case ActionSpyEvent(:final name) when !name.startsWith(_ownPrefix):
          session.replay?.activity();
          if (session.isRecording) session.record(EventTypes.mobxAction, {'name': name});
        default:
          break;
      }
    } catch (_) {
      // Recording bugs must never reach the app through MobX.
    }
  }

  /// `{name, type, value?}`. Only primitive values are kept (collections
  /// and objects are described by tracked stores), redacted by the
  /// observable's field name: `_LoginStore.password` is a password.
  Map<String, Object?> _describeWrite(BugCapsuleSession session, String name, Object? value) {
    final keep = (recordStateData ?? session.mode != CaptureMode.production) &&
        (value == null || value is num || value is bool || value is String);
    final field = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1) : name;
    return {
      'name': name,
      'type': value.runtimeType.toString(),
      if (keep) 'value': (session.redactor.redactJson({field: value}) as Map)[field],
    };
  }

  void _onReactionError(Object caught, Reaction reaction) {
    try {
      final session = this.session;
      if (session == null) return;
      // MobX wraps what the reaction threw; the failure is the original.
      final (error, stack) = caught is MobXCaughtException ? (caught.exception, caught.stackTrace) : (caught, null);
      session.replay?.activity();
      session.record(EventTypes.mobxError, {
        'reaction': reaction.name,
        'error': session.redactor.scrubText('$error'),
      });
      if (treatReactionErrorsAsFailures) session.reportError(error, stack);
    } catch (_) {}
  }
}
