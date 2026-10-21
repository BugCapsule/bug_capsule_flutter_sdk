import 'package:bug_capsule/src/core/core.dart';
import 'package:test/test.dart';

Checkpoint launch() => const Checkpoint(
    kind: CheckpointKind.launch, t: 0, wallClockMs: 1000, afterSeq: 0, data: {'k': 1});

Capsule sampleCapsule() => Capsule(
      manifest: CapsuleManifest(
        capsuleId: uuidV4(),
        createdAt: DateTime.utc(2026, 10, 19),
        mode: CaptureMode.qa,
        app: const AppInfo(version: '1.0.0', build: '7', id: 'com.example'),
        gitSha: 'abc123',
        sdkName: 'bug_capsule_flutter',
        sdkVersion: '0.1.0',
        stateSchemaVersion: 1,
        platform: const PlatformInfo(
            os: 'ios',
            osVersion: '27.0',
            locale: 'en_US',
            screenWidth: 402,
            screenHeight: 874,
            pixelRatio: 3,
            dartVersion: '3.13.5'),
        session: SessionInfo(
            id: 's1',
            startedAt: DateTime.utc(2026, 10, 19),
            wallClockAtAnchorMs: 1000,
            seed: 42,
            durationMs: 500),
        failure: FailureRecord.exception(StateError('Cart total is -3'), null, 400),
        eligibility: const Eligibility(EligibilityStatus.eligible, []),
        integrations: const ['dio'],
        eventCount: 1,
        droppedEvents: 0,
        checkpointKind: CheckpointKind.launch,
        labels: const {'note': 'tester'},
      ),
      checkpoint: launch(),
      events: const [BugCapsuleEvent(seq: 1, t: 10, type: EventTypes.action, data: {'id': 'buy'})],
    );

void main() {
  group('CapsuleCodec', () {
    test('round-trips a capsule through gzip JSON', () {
      final original = sampleCapsule();
      final decoded = CapsuleCodec.decode(CapsuleCodec.encode(original));
      expect(decoded.manifest.capsuleId, original.manifest.capsuleId);
      expect(decoded.manifest.failure!.signature, original.manifest.failure!.signature);
      expect(decoded.manifest.labels['note'], 'tester');
      expect(decoded.checkpoint.data['k'], 1);
      expect(decoded.events.single.data['id'], 'buy');
    });

    test('rejects non-gzip, wrong format and newer spec', () {
      expect(() => CapsuleCodec.decode([1, 2, 3]), throwsA(isA<CapsuleFormatException>()));
      final json = CapsuleCodec.toJson(sampleCapsule());
      expect(() => CapsuleCodec.fromJson({...json, 'format': 'x'}),
          throwsA(isA<CapsuleFormatException>()));
      expect(() => CapsuleCodec.fromJson({...json, 'specVersion': 2}),
          throwsA(isA<CapsuleFormatException>()));
    });
  });

  group('FailureSignature', () {
    test('normalizes numbers and hex ids', () {
      final a = FailureRecord.exception(StateError('Order 123 failed for deadbeefcafe'), null, 0);
      final b = FailureRecord.exception(StateError('Order 98 failed for 0123456789ab'), null, 0);
      expect(a.signature, b.signature);
      expect(a.signature, 'exception:StateError:Bad state: Order # failed for #');
    });

    test('assertion identity is the assertion id', () {
      final a = FailureRecord.assertion('checkout_stuck', 'stuck 4s', 0);
      final b = FailureRecord.assertion('checkout_stuck', 'stuck 9s', 0);
      expect(a.signature, b.signature);
    });
  });

  group('FlightRecorder', () {
    test('keeps the launch checkpoint while nothing is evicted', () {
      final r = FlightRecorder(launch: launch(), maxEvents: 10);
      for (var i = 0; i < 5; i++) {
        r.add(i, 'log');
      }
      final w = r.window();
      expect(w.checkpoint.kind, CheckpointKind.launch);
      expect(w.events, hasLength(5));
      expect(w.hasGap, isFalse);
    });

    test('switches to the earliest periodic checkpoint covering the window', () {
      final r = FlightRecorder(launch: launch(), maxEvents: 6);
      for (var i = 0; i < 4; i++) {
        r.add(i, 'log');
      }
      r.addCheckpoint(r.checkpointNow(
          kind: CheckpointKind.periodic, t: 4, wallClockMs: 0, data: const {}));
      for (var i = 4; i < 8; i++) {
        r.add(i, 'log');
      }
      // 8 events, max 6 -> seq 1,2 evicted; checkpoint after seq 4 is valid.
      final w = r.window();
      expect(r.droppedEvents, 2);
      expect(w.checkpoint.kind, CheckpointKind.periodic);
      expect(w.events.map((e) => e.seq), [5, 6, 7, 8]);
      expect(w.hasGap, isFalse);
    });

    test('reports a gap when eviction passed every checkpoint', () {
      final r = FlightRecorder(launch: launch(), maxEvents: 2);
      r.addCheckpoint(r.checkpointNow(
          kind: CheckpointKind.periodic, t: 0, wallClockMs: 0, data: const {}));
      for (var i = 0; i < 5; i++) {
        r.add(i, 'log');
      }
      final w = r.window();
      expect(w.hasGap, isTrue);
      expect(w.events, hasLength(2));
    });

    test('evicts by time window', () {
      final r = FlightRecorder(launch: launch(), windowMs: 100);
      r.add(0, 'log');
      r.add(50, 'log');
      r.add(200, 'log');
      expect(r.eventCount, 1);
    });
  });

  group('Redactor', () {
    final r = Redactor(extraKeys: ['loyaltyId']);

    test('redacts sensitive keys at any depth without false positives', () {
      final out = r.redactJson({
        'user': {'password': 'x', 'fcmToken': 'y', 'shipping': 'z', 'pin': '1234'},
        'list': [
          {'loyalty_id': 'L1', 'name': 'a'}
        ],
      }) as Map;
      final user = out['user'] as Map;
      expect(user['password'], Redactor.placeholder);
      expect(user['fcmToken'], Redactor.placeholder);
      expect(user['shipping'], 'z');
      expect(user['pin'], Redactor.placeholder);
      expect(((out['list'] as List).first as Map)['loyalty_id'], Redactor.placeholder);
    });

    test('redacts headers and query parameters', () {
      expect(r.redactHeaders({'Authorization': 'Bearer t', 'Accept': ['a', 'b']}),
          {'authorization': Redactor.placeholder, 'accept': 'a, b'});
      final uri = r.redactUri(Uri.parse('https://x.io/a?access_token=1&q=2'));
      expect(uri.queryParameters['access_token'], Redactor.placeholder);
      expect(uri.queryParameters['q'], '2');
    });
  });

  group('RequestKeyBuilder', () {
    final keys = RequestKeyBuilder(rules: [
      EndpointRule('POST', '/payments',
          ignoreBodyFields: {'timestamp', 'nonce'}, matchBodyFields: {'cart_id', 'amount', 'nonce'}),
      EndpointRule('GET', '/orders/:id'),
    ]);

    test('ignores volatile query params and sorts the rest', () {
      final a = keys.keyFor('get', Uri.parse('https://api.x/a?b=2&a=1&_=99'), null);
      final b = keys.keyFor('GET', Uri.parse('https://api.x/a?a=1&b=2&_=12'), null);
      expect(a, b);
      expect(a, 'GET api.x/a?a=1&b=2');
    });

    test('ignores body fields and key order', () {
      final a = keys.keyFor('POST', Uri.parse('https://api.x/payments'),
          {'cart_id': 1, 'amount': 5, 'timestamp': 1, 'nonce': 'a', 'extra': 1});
      final b = keys.keyFor('POST', Uri.parse('https://api.x/payments'),
          '{"amount":5,"cart_id":1,"timestamp":2,"nonce":"b"}');
      final c = keys.keyFor('POST', Uri.parse('https://api.x/payments'), {'cart_id': 2, 'amount': 5});
      expect(a, b);
      expect(a, isNot(c));
    });

    test('path parameters match rules', () {
      expect(keys.ruleFor('GET', Uri.parse('https://api.x/orders/42')), isNotNull);
      expect(keys.ruleFor('GET', Uri.parse('https://api.x/orders/42/items')), isNull);
    });
  });

  group('FixtureStore', () {
    BugCapsuleEvent http(int seq, String key, int occurrence, int status) => BugCapsuleEvent(
        seq: seq,
        t: seq,
        type: EventTypes.http,
        data: {'key': key, 'occurrence': occurrence, 'status': status, 'bodyEncoding': 'json'});

    test('serves occurrences in order then reuses the last', () {
      final store = FixtureStore([http(1, 'GET a', 0, 200), http(2, 'GET a', 1, 500)]);
      expect(store.take('GET a')!.fixture.status, 200);
      expect(store.take('GET a')!.fixture.status, 500);
      final third = store.take('GET a')!;
      expect(third.reused, isTrue);
      expect(third.fixture.status, 500);
      expect(store.take('GET b'), isNull);
    });
  });

  test('EligibilityBuilder status', () {
    expect(EligibilityBuilder().build().status, EligibilityStatus.eligible);
    final partial = EligibilityBuilder()..missing('build.gitSha', 'not set');
    expect(partial.build().status, EligibilityStatus.partial);
    final blocked = EligibilityBuilder()..missing('x', 'y', blocking: true);
    expect(blocked.build().status, EligibilityStatus.ineligible);
  });

  test('uuidV4 format', () {
    expect(uuidV4(), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });
}
