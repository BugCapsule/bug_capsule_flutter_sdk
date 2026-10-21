import 'package:bloc/bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule/bug_capsule.dart';

class TokenCubit extends Cubit<Map<String, Object?>> {
  TokenCubit() : super(const {'accessToken': 'synthBlocToken1', 'count': 0});
  void bump() => emit({...state, 'count': (state['count'] as int) + 1});
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

final registration = BugCapsuleState<TokenCubit, Map<String, Object?>>(
  toJson: (s) => s,
  fromJson: (j) => j,
);

void main() {
  test('state in events and snapshots is redacted', () async {
    final session = FakeSession();
    final bloc = BugCapsuleBloc(states: [registration]);
    await bloc.setUp(session);
    final cubit = TokenCubit()..bump();
    final snapshot = bloc.snapshot(CheckpointKind.periodic).toString();
    expect(snapshot, isNot(contains('synthBlocToken1')));
    expect([for (final e in session.events) e.data].toString(), isNot(contains('synthBlocToken1')));
    await cubit.close();
  });

  test('a checkpoint entry without restorable state is reported, not skipped', () async {
    final replay = FakeReplay();
    final session = FakeSession(replay: replay);
    final bloc = BugCapsuleBloc(states: [registration]);
    await bloc.setUp(session);
    await bloc.restore({'TokenCubit#0': '[REDACTED]'}, session);
    final cubit = TokenCubit();
    await Future<void>.delayed(Duration.zero);
    expect(replay.divergences, ['bloc.unrestored TokenCubit#0: state was not captured']);
    await cubit.close();
  });
}
