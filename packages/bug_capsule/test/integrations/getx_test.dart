import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:bug_capsule/bug_capsule.dart';

class ProfileController extends GetxController {
  String accessToken = 'synthGetxToken1';
  int visits = 0;

  void visit() {
    visits++;
    update();
  }

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'visits': visits,
  };
}

class Coupon {
  Coupon(this.code);
  final String code;
}

class FakeSession implements BugCapsuleSession {
  FakeSession({this.replay});
  final List<BugCapsuleEvent> events = [];
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
  void reportError(Object error, StackTrace? stack) {}

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

Future<BugCapsuleGetx> setUpWith(FakeSession session, {Object? restore}) async {
  final getx = BugCapsuleGetx();
  await getx.setUp(session);
  await getx.restore(restore, session);
  return getx;
}

const periodic = RecordedWindow(
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
  test('records Rx changes and controller updates, redacted', () async {
    final session = FakeSession();
    final getx = await setUpWith(session);
    final RxInt count = getx.trackRx(0.obs, id: 'count');
    final RxMap<String, String> auth = getx.trackRx(
      <String, String>{'token': 'synthGetxToken2'}.obs,
      id: 'auth',
    );
    final profile = getx.track(
      ProfileController(),
      id: 'profile',
      toJson: (c) => c.toJson(),
    );

    count.value = 3;
    auth['refreshToken'] = 'synthGetxToken3';
    profile.visit();
    await Future<void>.delayed(Duration.zero);

    expect(
      [for (final e in session.of(EventTypes.getxCreate)) e['key']],
      ['count#0', 'auth#0', 'profile#0'],
    );
    final changes = session.of(EventTypes.getxChange);
    expect(
      [for (final e in changes) e['key']],
      ['count#0', 'auth#0', 'profile#0'],
    );
    expect(changes[0]['data'], {'value': 3});
    expect(changes[2]['data'], containsPair('visits', 1));
    expect(
      [for (final e in session.events) e.data].toString(),
      isNot(contains('synthGetxToken')),
    );

    final snapshot = getx.snapshot(CheckpointKind.periodic)! as Map;
    expect((snapshot['count#0'] as Map)['state'], {'value': 3});
    expect(snapshot.toString(), isNot(contains('synthGetxToken')));
    expect(getx.snapshot(CheckpointKind.launch), isNull);
  });

  test('replay restores Rx values and controllers in tracking order', () async {
    final replay = FakeReplay();
    final session = FakeSession(replay: replay);
    final getx = await setUpWith(
      session,
      restore: {
        'count#1': {
          'state': {'value': 8},
        },
        'coupon#0': {
          'state': {'code': 'SAVE100'},
        },
        'profile#0': {
          'state': {'visits': 4},
        },
      },
    );
    final first = getx.trackRx(0.obs, id: 'count');
    final second = getx.trackRx(0.obs, id: 'count');
    final coupon = getx.trackRx(
      Coupon('').obs,
      id: 'coupon',
      toJson: (c) => {'code': c.code},
      fromJson: (j) => Coupon(j['code'] as String),
    );
    final profile = getx.track(
      ProfileController(),
      id: 'profile',
      toJson: (c) => c.toJson(),
      restore: (c, json) => c.visits = json['visits'] as int,
    );

    expect(first.value, 0);
    expect(second.value, 8);
    expect(coupon.value.code, 'SAVE100');
    expect(profile.visits, 4);
    expect(replay.divergences, isEmpty);
  });

  test('restore failures and missing serializers are reported', () async {
    final replay = FakeReplay();
    final getx = await setUpWith(
      FakeSession(replay: replay),
      restore: {
        'coupon#0': {
          'state': {'value': 'not a coupon'},
        },
        'profile#0': {
          'state': {'visits': 1},
        },
      },
    );
    getx.trackRx(Coupon('').obs, id: 'coupon');
    getx.track(ProfileController(), id: 'profile');
    expect(replay.divergences, [
      startsWith('getx.unrestored coupon#0: '),
      'getx.unrestored profile#0 has no restore callback',
    ]);
  });

  test('values that are not JSON make periodic checkpoints partial', () async {
    final getx = await setUpWith(FakeSession());
    getx.trackRx(Coupon('x').obs, id: 'coupon');
    getx.track(ProfileController(), id: 'profile');
    expect(getx.snapshot(CheckpointKind.periodic), isEmpty);
    final eligibility = EligibilityBuilder();
    getx.describeEligibility(eligibility, periodic);
    expect(
      [for (final m in eligibility.build().missing) m.reason],
      [
        'coupon#0 is tracked without a JSON serializer',
        'profile#0 is tracked without a JSON serializer',
      ],
    );
  });

  test('untracked state is no longer recorded', () async {
    final session = FakeSession();
    final getx = await setUpWith(session);
    final count = getx.trackRx(0.obs, id: 'count');
    final profile = getx.track(ProfileController(), id: 'profile');
    getx
      ..untrack(count)
      ..untrack(profile);
    count.value = 1;
    profile.visit();
    await Future<void>.delayed(Duration.zero);
    expect(session.of(EventTypes.getxChange), isEmpty);
  });
}
