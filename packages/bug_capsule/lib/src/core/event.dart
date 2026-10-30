/// Event types defined by capsule spec v1.
abstract final class EventTypes {
  static const lifecycle = 'lifecycle';
  static const pointer = 'pointer';
  static const action = 'action';
  static const text = 'text';
  static const route = 'route';
  static const blocCreate = 'bloc.create';
  static const blocClose = 'bloc.close';
  static const blocEvent = 'bloc.event';
  static const blocState = 'bloc.state';
  static const blocError = 'bloc.error';
  static const riverpodAdd = 'riverpod.add';
  static const riverpodUpdate = 'riverpod.update';
  static const riverpodError = 'riverpod.error';
  static const riverpodDispose = 'riverpod.dispose';
  static const notifierCreate = 'notifier.create';
  static const notifierChange = 'notifier.change';
  static const getxCreate = 'getx.create';
  static const getxChange = 'getx.change';
  static const mobxCreate = 'mobx.create';
  static const mobxChange = 'mobx.change';
  static const mobxObservable = 'mobx.observable';
  static const mobxAction = 'mobx.action';
  static const mobxError = 'mobx.error';
  static const http = 'http';
  static const emergencyDecision = 'emergency.decision';
  static const log = 'log';
  static const failure = 'failure';

  /// Event types the replay driver dispatches back into the app.
  static const replayable = {lifecycle, pointer, action, text};
}

/// One recorded event. [t] is milliseconds relative to the session anchor
/// once the capsule is written; inside the recorder it is milliseconds since
/// recording started.
class BugCapsuleEvent {
  const BugCapsuleEvent({
    required this.seq,
    required this.t,
    required this.type,
    this.data = const {},
  });

  factory BugCapsuleEvent.fromJson(Map<String, Object?> json) =>
      BugCapsuleEvent(
        seq: json['seq'] as int,
        t: json['t'] as int,
        type: json['type'] as String,
        data: (json['data'] as Map?)?.cast<String, Object?>() ?? const {},
      );

  final int seq;
  final int t;
  final String type;
  final Map<String, Object?> data;

  /// [t] and a screenshot's `capturedAtT` are on the same clock, so both move.
  BugCapsuleEvent shift(int offsetMs) {
    final capturedAt = data['capturedAtT'];
    return BugCapsuleEvent(
      seq: seq,
      t: t - offsetMs,
      type: type,
      data: capturedAt is int
          ? {...data, 'capturedAtT': capturedAt - offsetMs}
          : data,
    );
  }

  Map<String, Object?> toJson() => {
    'seq': seq,
    't': t,
    'type': type,
    'data': data,
  };

  @override
  String toString() => 'BugCapsuleEvent($seq, ${t}ms, $type)';
}
