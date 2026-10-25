import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:bug_capsule/bug_capsule.dart';

class Session extends Notifier<Map<String, Object?>> {
  @override
  Map<String, Object?> build() => const {
    'accessToken': 'synthRiverpodToken1',
    'count': 0,
  };
  void bump() => state = {...state, 'count': (state['count'] as int) + 1};
}

final sessionProvider = NotifierProvider<Session, Map<String, Object?>>(
  Session.new,
  name: 'session',
);

class Profile extends AsyncNotifier<Map<String, Object?>> {
  @override
  Future<Map<String, Object?>> build() async => const {'name': 'fresh'};
}

final profileProvider = AsyncNotifierProvider<Profile, Map<String, Object?>>(
  Profile.new,
  name: 'profile',
);

class Todo extends Notifier<int> {
  Todo(this.id);
  final int id;
  @override
  int build() => id * 10;
}

final todoProvider = NotifierProvider.family<Todo, int, int>(
  Todo.new,
  name: 'todo',
);

class Unregistered extends Notifier<int> {
  @override
  int build() => 1;
}

final unregisteredProvider = NotifierProvider<Unregistered, int>(
  Unregistered.new,
  name: 'unregistered',
);

final failingProvider = Provider<int>(
  (ref) => throw StateError('boom'),
  name: 'failing',
);

class FakeSession implements BugCapsuleSession {
  FakeSession({this.replay});
  final List<BugCapsuleEvent> events = [];
  final List<Object> errors = [];
  @override
  final ReplayContext? replay;
  @override
  BugCapsuleConfig get config =>
      const BugCapsuleConfig(appVersion: '1', appBuild: '1');
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
      events.add(
        BugCapsuleEvent(
          seq: events.length + 1,
          t: now(),
          type: type,
          data: data,
        ),
      );
  @override
  void reportError(Object error, StackTrace? stack) => errors.add(error);

  List<Map<String, Object?>> of(String type) => [
    for (final e in events)
      if (e.type == type) e.data,
  ];
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

final sessionState = BugCapsuleRiverpodState<Map<String, Object?>>(
  sessionProvider,
  toJson: (s) => s,
  fromJson: (j) => j,
);
final profileState = BugCapsuleRiverpodState<Map<String, Object?>>(
  profileProvider,
  toJson: (s) => s,
  fromJson: (j) => j,
);
final todoState = BugCapsuleRiverpodState<int>(
  todoProvider,
  toJson: (v) => {'value': v},
  fromJson: (j) => j['value'] as int,
);

Future<(BugCapsuleRiverpod, ProviderContainer)> setUpWith(
  FakeSession session, {
  Object? restore,
  List<BugCapsuleRiverpodState<Object?>> states = const [],
}) async {
  final integration = BugCapsuleRiverpod(states: states);
  await integration.setUp(session);
  await integration.restore(restore, session);
  final container = ProviderContainer(observers: [integration.observer]);
  addTearDown(container.dispose);
  return (integration, container);
}

RecordedWindow periodicWindow() => const RecordedWindow(
  checkpoint: Checkpoint(
    kind: CheckpointKind.periodic,
    t: 0,
    wallClockMs: 0,
    afterSeq: 0,
  ),
  events: [],
  droppedEvents: 0,
  hasGap: false,
);

void main() {
  test(
    'records provider activity; state in events and snapshots is redacted',
    () async {
      final session = FakeSession();
      final (integration, container) = await setUpWith(
        session,
        states: [sessionState],
      );
      container.read(sessionProvider.notifier).bump();

      final add = session.of(EventTypes.riverpodAdd).single;
      expect(add['key'], 'session#0');
      expect(
        session.of(EventTypes.riverpodUpdate).single['data'],
        containsPair('count', 1),
      );
      expect(
        [for (final e in session.events) e.data].toString(),
        isNot(contains('synthRiverpodToken1')),
      );

      final snapshot = integration.snapshot(CheckpointKind.periodic)! as Map;
      expect((snapshot['session#0'] as Map)['state'], containsPair('count', 1));
      expect(snapshot.toString(), isNot(contains('synthRiverpodToken1')));
      expect(integration.snapshot(CheckpointKind.launch), isNull);
    },
  );

  test(
    'replay restores a Notifier, an AsyncNotifier and a family member',
    () async {
      final replay = FakeReplay();
      final session = FakeSession(replay: replay);
      final (_, container) = await setUpWith(
        session,
        states: [sessionState, profileState, todoState],
        restore: {
          'session#0': {
            'provider': 'session',
            'state': {'count': 7},
          },
          'profile#0': {
            'provider': 'profile',
            'state': {'name': 'restored'},
          },
          'todo(2)#0': {
            'provider': 'todo(2)',
            'state': {'value': 99},
          },
        },
      );
      container.read(sessionProvider);
      container.read(todoProvider(2));
      container.read(todoProvider(3));
      await container.read(profileProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(sessionProvider), {'count': 7});
      expect(container.read(todoProvider(2)), 99);
      expect(container.read(todoProvider(3)), 30);
      expect(container.read(profileProvider).value, {'name': 'restored'});
      expect(replay.divergences, isEmpty);
    },
  );

  test('a custom restore callback is used when given', () async {
    final replay = FakeReplay();
    final restored = <int>[];
    final (_, container) = await setUpWith(
      FakeSession(replay: replay),
      states: [
        BugCapsuleRiverpodState<int>(
          unregisteredProvider,
          toJson: (v) => {'v': v},
          fromJson: (j) => j['v'] as int,
          restore: (container, provider, value) => restored.add(value),
        ),
      ],
      restore: {
        'unregistered#0': {
          'state': {'v': 5},
        },
      },
    );
    container.read(unregisteredProvider);
    await Future<void>.delayed(Duration.zero);
    expect(restored, [5]);
  });

  test(
    'a checkpoint entry without restorable state is reported, not skipped',
    () async {
      final replay = FakeReplay();
      final (_, container) = await setUpWith(
        FakeSession(replay: replay),
        states: [sessionState],
        restore: {'session#0': '[REDACTED]'},
      );
      container.read(sessionProvider);
      expect(replay.divergences, [
        'riverpod.unrestored session#0: state was not captured',
      ]);
    },
  );

  test('unregistered notifiers make periodic checkpoints partial', () async {
    final session = FakeSession();
    final (integration, container) = await setUpWith(
      session,
      states: [sessionState],
    );
    container
      ..read(sessionProvider)
      ..read(unregisteredProvider);
    integration.snapshot(CheckpointKind.periodic);
    final eligibility = EligibilityBuilder();
    integration.describeEligibility(eligibility, periodicWindow());
    expect(
      eligibility.build().missing.single.reason,
      'unregistered has no BugCapsuleRiverpodState serializer',
    );
  });

  test('provider errors are recorded and reported as failures', () async {
    final session = FakeSession();
    final (_, container) = await setUpWith(session);
    expect(() => container.read(failingProvider), throwsA(anything));
    final error = session.of(EventTypes.riverpodError).single;
    expect(error['key'], 'failing#0');
    expect(error['error'], contains('boom'));
    expect(session.errors.single, isA<StateError>());
    // The failed initialization still counts as one, not two.
    expect(session.of(EventTypes.riverpodAdd).single['key'], 'failing#0');
  });

  test(
    'an invalidated provider keeps its key and stays in snapshots',
    () async {
      final session = FakeSession();
      final (integration, container) = await setUpWith(
        session,
        states: [sessionState],
      );
      container.read(sessionProvider);
      container.invalidate(sessionProvider);
      container.read(sessionProvider);
      expect(session.of(EventTypes.riverpodDispose).first['key'], 'session#0');
      expect(
        [for (final e in session.of(EventTypes.riverpodAdd)) e['key']],
        ['session#0'],
      );
      expect((integration.snapshot(CheckpointKind.periodic)! as Map).keys, [
        'session#0',
      ]);
    },
  );

  test(
    'an unmounted provider leaves snapshots; a remount gets the next key',
    () async {
      final session = FakeSession();
      final counter = NotifierProvider.autoDispose<Unregistered, int>(
        Unregistered.new,
        name: 'counter',
      );
      final (integration, container) = await setUpWith(
        session,
        states: [
          BugCapsuleRiverpodState<int>(
            counter,
            toJson: (v) => {'v': v},
            fromJson: (j) => j['v'] as int,
          ),
        ],
      );
      container.listen(counter, (_, _) {}).close();
      await container.pump();
      expect((integration.snapshot(CheckpointKind.periodic)! as Map), isEmpty);

      final sub = container.listen(counter, (_, _) {});
      addTearDown(sub.close);
      expect(
        [for (final e in session.of(EventTypes.riverpodAdd)) e['key']],
        ['counter#0', 'counter#1'],
      );
      expect((integration.snapshot(CheckpointKind.periodic)! as Map).keys, [
        'counter#1',
      ]);
    },
  );

  test('a registration needs a provider name or an id', () {
    final anonymous = NotifierProvider<Unregistered, int>(Unregistered.new);
    expect(
      () => BugCapsuleRiverpodState<int>(
        anonymous,
        toJson: (v) => v,
        fromJson: (j) => 0,
      ),
      throwsArgumentError,
    );
    expect(
      BugCapsuleRiverpodState<int>(
        anonymous,
        id: 'counter',
        toJson: (v) => v,
        fromJson: (j) => 0,
      ).id,
      'counter',
    );
  });
}
