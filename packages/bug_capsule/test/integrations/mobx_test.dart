import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';
import 'package:bug_capsule/bug_capsule.dart';

/// What `mobx_codegen` generates, written by hand.
class LoginStore {
  LoginStore(this.context);

  final ReactiveContext context;
  late final password = Observable('', name: '_LoginStore.password', context: context);
  late final attempts = Observable(0, name: '_LoginStore.attempts', context: context);
  late final _submit = Action(() {
    password.value = 'synthMobxSecret1';
    attempts.value++;
  }, name: '_LoginStore.submit', context: context);

  void submit() => _submit();

  Map<String, Object?> toJson() => {'password': password.value, 'attempts': attempts.value};
}

class FakeSession implements BugCapsuleSession {
  FakeSession({this.replay, this.recording = true});
  final List<BugCapsuleEvent> events = [];
  final List<Object> errors = [];
  final bool recording;
  @override
  final ReplayContext? replay;
  @override
  BugCapsuleConfig get config => const BugCapsuleConfig(appVersion: '1', appBuild: '1');
  @override
  CaptureMode get mode => CaptureMode.qa;
  @override
  bool get isRecording => replay == null && recording;
  @override
  bool get isReplaying => replay != null;
  @override
  final Redactor redactor = Redactor();
  @override
  bool get captureNetworkBodies => true;
  @override
  int get maxBodyBytes => 1024;
  @override
  int now() => events.length;
  @override
  void record(String type, [Map<String, Object?> data = const {}]) {
    if (isRecording) events.add(BugCapsuleEvent(seq: events.length + 1, t: now(), type: type, data: data));
  }

  @override
  void reportError(Object error, StackTrace? stack) => errors.add(error);

  List<Map<String, Object?>> of(String type) => [for (final e in events) if (e.type == type) e.data];
}

class FakeReplay implements ReplayContext {
  final List<String> divergences = [];
  int activities = 0;
  @override
  void diverge(String type, String detail) => divergences.add('$type $detail');
  @override
  void activity() => activities++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(BugCapsuleMobx, ReactiveContext)> setUpWith(FakeSession session, {Object? restore}) async {
  final context = ReactiveContext();
  final mobx = BugCapsuleMobx(context: context);
  await mobx.setUp(session);
  await mobx.restore(restore, session);
  return (mobx, context);
}

LoginStore trackLogin(BugCapsuleMobx mobx, LoginStore store) => mobx.track(
      store,
      id: 'login',
      toJson: (s) => s.toJson(),
      restore: (s, json) => s.attempts.value = json['attempts'] as int,
    );

void main() {
  test('records observable writes, actions and tracked stores, redacted', () async {
    final session = FakeSession();
    final (mobx, context) = await setUpWith(session);
    final store = trackLogin(mobx, LoginStore(context))..submit();

    expect(session.of(EventTypes.mobxAction).single, {'name': '_LoginStore.submit'});
    final writes = session.of(EventTypes.mobxObservable);
    expect(writes, [
      {'name': '_LoginStore.password', 'type': 'String', 'value': Redactor.placeholder},
      {'name': '_LoginStore.attempts', 'type': 'int', 'value': 1},
    ]);
    // One change for the whole action, with the store's state.
    final change = session.of(EventTypes.mobxChange).single;
    expect(change['key'], 'login#0');
    expect(change['data'], containsPair('attempts', 1));
    expect([for (final e in session.events) e.data].toString(), isNot(contains('synthMobxSecret1')));

    final snapshot = mobx.snapshot(CheckpointKind.periodic)! as Map;
    expect((snapshot['login#0'] as Map)['state'], containsPair('attempts', 1));
    expect(snapshot.toString(), isNot(contains('synthMobxSecret1')));
    mobx.untrack(store);
  });

  test('replay restores observed stores inside an action', () async {
    final replay = FakeReplay();
    final (mobx, context) = await setUpWith(FakeSession(replay: replay), restore: {
      'login#0': {'state': {'attempts': 3}},
    });
    final store = LoginStore(context);
    // An observer makes writes outside actions an error under the default
    // write policy.
    final seen = <int>[];
    final dispose = autorun((_) => seen.add(store.attempts.value), context: context);
    addTearDown(dispose.call);
    trackLogin(mobx, store);

    expect(store.attempts.value, 3);
    expect(seen, [0, 3]);
    expect(replay.divergences, isEmpty);
    store.submit();
    expect(replay.activities, greaterThan(0));
  });

  test('reaction errors are recorded and reported as failures', () async {
    final session = FakeSession();
    final (_, context) = await setUpWith(session);
    final store = LoginStore(context);
    final dispose = reaction<int>((_) => store.attempts.value, (attempts) => throw StateError('attempt $attempts'),
        name: 'loginWatcher', context: context);
    addTearDown(dispose.call);
    store.submit();
    expect(session.of(EventTypes.mobxError).single, {'reaction': 'loginWatcher', 'error': 'Bad state: attempt 1'});
    expect(session.errors.single, isA<StateError>());
  });

  test('stores without toJson make periodic checkpoints partial', () async {
    final (mobx, context) = await setUpWith(FakeSession());
    mobx.track(LoginStore(context), id: 'plain');
    mobx.snapshot(CheckpointKind.periodic);
    final eligibility = EligibilityBuilder();
    mobx.describeEligibility(
      eligibility,
      const RecordedWindow(
        checkpoint: Checkpoint(kind: CheckpointKind.periodic, t: 0, wallClockMs: 0, afterSeq: 0),
        events: [],
        droppedEvents: 0,
        hasGap: false,
      ),
    );
    expect(eligibility.build().missing.single.reason, 'plain#0 is tracked without a JSON serializer');
  });

  test('sessions that neither record nor replay leave the spy off', () async {
    final (_, context) = await setUpWith(FakeSession(recording: false));
    expect(context.config.isSpyEnabled, isFalse);
  });
}
