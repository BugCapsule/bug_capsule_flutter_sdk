import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:bug_capsule/bug_capsule.dart';

class AuthModel extends ChangeNotifier {
  String accessToken = 'synthNotifierToken1';
  int count = 0;

  void bump() {
    count++;
    notifyListeners();
  }

  Map<String, Object?> toJson() => {'accessToken': accessToken, 'count': count};
  void restoreFrom(Map<String, Object?> json) => count = json['count'] as int;
}

class FakeSession implements BugCapsuleSession {
  FakeSession({this.replay});
  final List<BugCapsuleEvent> events = [];
  @override
  final ReplayContext? replay;
  @override
  BugCapsuleConfig get config => const BugCapsuleConfig(appVersion: '1', appBuild: '1');
  @override
  CaptureMode get mode => CaptureMode.qa;
  @override
  bool get isRecording => replay == null;
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
  void record(String type, [Map<String, Object?> data = const {}]) =>
      events.add(BugCapsuleEvent(seq: events.length + 1, t: now(), type: type, data: data));
  @override
  void reportError(Object error, StackTrace? stack) {}

  List<Map<String, Object?>> of(String type) => [for (final e in events) if (e.type == type) e.data];
}

class FakeReplay implements ReplayContext {
  final List<String> divergences = [];
  @override
  void diverge(String type, String detail) => divergences.add('$type $detail');
  @override
  void activity() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AuthModel trackAuth(BugCapsuleNotifiers notifiers, AuthModel model) => notifiers.track(
      model,
      id: 'auth',
      toJson: (m) => m.toJson(),
      restore: (m, json) => m.restoreFrom(json),
    );

Future<BugCapsuleNotifiers> setUpWith(FakeSession session, {Object? restore}) async {
  final notifiers = BugCapsuleNotifiers();
  await notifiers.setUp(session);
  await notifiers.restore(restore, session);
  return notifiers;
}

void main() {
  testWidgets('records changes of a ChangeNotifierProvider model, redacted', (tester) async {
    final session = FakeSession();
    final notifiers = await setUpWith(session);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => trackAuth(notifiers, AuthModel()),
      child: Builder(builder: (context) {
        final auth = context.watch<AuthModel>();
        return Text('${auth.count}', textDirection: TextDirection.ltr);
      }),
    ));
    tester.element(find.text('0')).read<AuthModel>().bump();
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    expect(session.of(EventTypes.notifierCreate).single, {'type': 'AuthModel', 'key': 'auth#0'});
    final change = session.of(EventTypes.notifierChange).single;
    expect(change['data'], containsPair('count', 1));
    expect([for (final e in session.events) e.data].toString(), isNot(contains('synthNotifierToken1')));

    final snapshot = notifiers.snapshot(CheckpointKind.periodic)! as Map;
    expect((snapshot['auth#0'] as Map)['state'], containsPair('count', 1));
    expect(snapshot.toString(), isNot(contains('synthNotifierToken1')));
    expect(notifiers.snapshot(CheckpointKind.launch), isNull);
  });

  test('replay restores tracked notifiers in tracking order', () async {
    final replay = FakeReplay();
    final notifiers = await setUpWith(FakeSession(replay: replay), restore: {
      'auth#1': {'state': {'count': 4}},
      'counter#0': {'state': {'value': 9}},
    });
    final first = trackAuth(notifiers, AuthModel());
    final second = trackAuth(notifiers, AuthModel());
    final counter = notifiers.track(ValueNotifier(0),
        id: 'counter', toJson: (n) => {'value': n.value}, restore: (n, json) => n.value = json['value'] as int);
    expect(first.count, 0);
    expect(second.count, 4);
    expect(counter.value, 9);
    expect(replay.divergences, isEmpty);
  });

  test('a checkpoint entry that cannot be restored is reported', () async {
    final replay = FakeReplay();
    final notifiers = await setUpWith(FakeSession(replay: replay), restore: {
      'auth#0': '[REDACTED]',
      'plain#0': {'state': {'count': 1}},
    });
    trackAuth(notifiers, AuthModel());
    notifiers.track(AuthModel(), id: 'plain');
    expect(replay.divergences, [
      'notifier.unrestored auth#0: state was not captured',
      'notifier.unrestored plain#0 has no restore callback',
    ]);
  });

  test('notifiers without toJson make periodic checkpoints partial', () async {
    final notifiers = await setUpWith(FakeSession());
    final model = notifiers.track(AuthModel(), id: 'plain');
    notifiers.snapshot(CheckpointKind.periodic);
    final eligibility = EligibilityBuilder();
    notifiers.describeEligibility(
      eligibility,
      const RecordedWindow(
        checkpoint: Checkpoint(kind: CheckpointKind.periodic, t: 0, wallClockMs: 0, afterSeq: 0),
        events: [],
        droppedEvents: 0,
        hasGap: false,
      ),
    );
    expect(eligibility.build().missing.single.reason, 'plain#0 is tracked without a JSON serializer');
    model.dispose();
  });

  test('untracked notifiers are no longer recorded or snapshotted', () async {
    final session = FakeSession();
    final notifiers = await setUpWith(session);
    final model = trackAuth(notifiers, AuthModel());
    // Tracking the same instance twice is a no-op.
    expect(trackAuth(notifiers, model), same(model));
    notifiers.untrack(model);
    model.bump();
    expect(session.of(EventTypes.notifierChange), isEmpty);
    expect(notifiers.snapshot(CheckpointKind.periodic), isEmpty);
    expect(session.of(EventTypes.notifierCreate), hasLength(1));
  });

  test('notifiers tracked before setup pass through', () {
    final model = AuthModel();
    expect(BugCapsuleNotifiers().track(model, id: 'auth'), same(model));
  });
}
