import 'dart:async';
import 'dart:typed_data';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/testing.dart';
import 'package:bug_capsule_firebase/bug_capsule_firebase.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

FakeFirestoreClient seeded() => FakeFirestoreClient()
  ..server['orders/1'] = {'status': 'open', 'total': 12.5, 'items': 2}
  ..server['orders/2'] = {'status': 'open', 'total': 3.0, 'items': 1}
  ..server['orders/3'] = {'status': 'paid', 'total': 40, 'items': 4}
  ..cache['orders/1'] = {'status': 'draft', 'total': 12.5, 'items': 2};

Future<AdapterConformanceResult> conform(
  FutureOr<Object?> Function(BugCapsuleFirestore firestore) scenario, {
  FakeFirestoreClient Function()? fake,
  List<ThrowingFirestoreClient>? throwing,
}) => AdapterConformance.run(
  create: (replaying) {
    if (!replaying) {
      return BugCapsuleFirestore(client: (fake ?? seeded)());
    }
    final t = ThrowingFirestoreClient();
    throwing?.add(t);
    return BugCapsuleFirestore(client: t);
  },
  scenario: scenario,
);

/// Pushes a server change while capturing (replay has no server).
void serverChange(
  BugCapsuleFirestore f,
  String path,
  Map<String, Object?> data,
) {
  final client = f.client;
  if (client is FakeFirestoreClient) client.serverChange(path, data);
}

List<Map<String, Object?>> ofType(AdapterConformanceResult r, String type) => [
  for (final e in r.events)
    if (e.type == type) e.data,
];

void main() {
  group('conformance (isolated replay, throwing client)', () {
    test('document.get', () async {
      final throwing = <ThrowingFirestoreClient>[];
      final r = await conform(
        (f) async => [
          docJson(await f.getDocument('orders/1')),
          docJson(await f.getDocument('orders/missing')),
        ],
        throwing: throwing,
      );
      expect(r.problems, isEmpty);
      expect(throwing.single.calls, 0);
      expect(r.dependencies.single.adapter, 'bug_capsule.cloud_firestore');
      expect(r.dependencies.single.coverage, DependencyCoverage.complete);
    });

    test('document.snapshots', () async {
      final r = await conform((f) async {
        final events = takeEvents(f.documentSnapshots('orders/2'), 2);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        serverChange(f, 'orders/2', {'status': 'paid'});
        return [for (final d in await events) docJson(d)];
      });
      expect(r.problems, isEmpty);
    });

    test('query.get', () async {
      final r = await conform(
        (f) async => queryJson(
          await f.getQuery(
            const FirestoreQuery(
              'orders',
              where: [
                FirestoreFilter('status', FirestoreFilterOp.isEqualTo, 'open'),
              ],
              orderBy: [FirestoreOrder('total', descending: true)],
              limit: 10,
            ),
          ),
        ),
      );
      expect(r.problems, isEmpty);
      final args = ofType(r, 'native.call').single['args'] as Map;
      expect((args['value'] as Map)['query'], {
        'collection': 'orders',
        'where': [
          ['status', 'isEqualTo', 'open'],
        ],
        'orderBy': [
          ['total', true],
        ],
        'limit': 10,
      });
    });

    test('query.snapshots', () async {
      final r = await conform((f) async {
        final events = await takeEvents(
          f.querySnapshots(const FirestoreQuery('orders')),
          1,
        );
        return [
          for (final q in events)
            [
              queryJson(q),
              [for (final c in q.changes) '${c.type.name}:${c.document.id}'],
            ],
        ];
      });
      expect(r.problems, isEmpty);
    });

    test('document.set', () async {
      final r = await conform((f) async {
        await f.setDocument('orders/9', {'status': 'open'});
        await f.setDocument('orders/9', {'items': 1}, merge: true);
        return 'ok';
      });
      expect(r.problems, isEmpty);
    });

    test('document.update', () async {
      final r = await conform((f) async {
        await f.updateDocument('orders/1', {
          'status': 'paid',
          'paidAt': FirestoreFieldValue.serverTimestamp(),
          'items': FirestoreFieldValue.increment(1),
        });
        return 'ok';
      });
      expect(r.problems, isEmpty);
    });

    test('document.delete', () async {
      final r = await conform((f) async {
        await f.deleteDocument('orders/3');
        return 'ok';
      });
      expect(r.problems, isEmpty);
    });
  });

  test('cached results replay with fromCache', () async {
    final r = await conform((f) async {
      final cached = await f.getDocument('orders/1', source: Source.cache);
      final live = await takeEvents(
        f.documentSnapshots('orders/1', includeMetadataChanges: true),
        2,
      );
      return [
        cached.metadata.isFromCache,
        cached['status'],
        for (final d in live) [d.metadata.isFromCache, d['status']],
      ];
    });
    expect(r.problems, isEmpty);
    expect(r.replayed, [
      true,
      'draft',
      [true, 'draft'],
      [false, 'open'],
    ]);
  });

  test('a cache miss replays as the recorded FirebaseException', () async {
    final r = await conform((f) async {
      try {
        await f.getDocument('orders/2', source: Source.cache);
        return 'no error';
      } on FirebaseException catch (e) {
        return [e.plugin, e.code];
      }
    });
    expect(r.problems, isEmpty);
    expect(r.replayed, ['cloud_firestore', 'unavailable']);
  });

  test('listener teardown records native.cancel and replays it', () async {
    final r = await conform((f) async {
      final first = await takeEvents(f.documentSnapshots('orders/1'), 1);
      return docJson(first.single);
    });
    expect(r.problems, isEmpty);
    final sub = ofType(r, 'native.subscribe').single['sub'];
    expect(ofType(r, 'native.cancel').single['sub'], sub);
    expect(ofType(r, 'native.done'), isEmpty);
  });

  test(
    'repeated subscriptions to the same document match by occurrence',
    () async {
      final r = await conform((f) async {
        final a = await takeEvents(f.documentSnapshots('orders/2'), 1);
        final bEvents = takeEvents(f.documentSnapshots('orders/2'), 2);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        serverChange(f, 'orders/2', {'status': 'shipped'});
        final b = await bEvents;
        return [
          [for (final d in a) d['status']],
          [for (final d in b) d['status']],
        ];
      });
      expect(r.problems, isEmpty);
      expect(r.replayed, [
        ['open'],
        ['open', 'shipped'],
      ]);
      final subs = ofType(r, 'native.subscribe');
      expect(subs.map((s) => s['key']).toSet(), hasLength(1));
      expect([for (final s in subs) s['occurrence']], [0, 1]);
    },
  );

  test('optimistic local update then server confirmation', () async {
    final r = await conform((f) async {
      final seen = <List<Object?>>[];
      final sub = f
          .documentSnapshots('orders/2', includeMetadataChanges: true)
          .listen((d) => seen.add([d['status'], d.metadata.hasPendingWrites]));
      while (seen.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await f.updateDocument('orders/2', {'status': 'paid'});
      while (seen.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await sub.cancel();
      return seen;
    });
    expect(r.problems, isEmpty);
    expect(r.replayed, [
      ['open', false],
      ['paid', true],
      ['paid', false],
    ]);
  });

  test('permission-denied write is rebuilt as FirebaseException', () async {
    final r = await conform((f) async {
      try {
        await f.setDocument('admin/config', {'open': true});
        return 'written';
      } on FirebaseException catch (e) {
        return [e.runtimeType.toString(), e.plugin, e.code, e.message];
      }
    }, fake: () => seeded()..denied.add('admin/config'));
    expect(r.problems, isEmpty);
    expect(r.replayed, [
      'FirebaseException',
      'cloud_firestore',
      'permission-denied',
      'Missing or insufficient permissions.',
    ]);
    expect(ofType(r, 'native.error').single['code'], 'permission-denied');
  });

  group('divergences', () {
    Future<(InteractionHarness, BugCapsuleFirestore, ThrowingFirestoreClient)>
    replayOf(Future<void> Function(BugCapsuleFirestore) captureScenario) async {
      final capture = InteractionHarness.capture();
      final adapter = BugCapsuleFirestore(client: seeded());
      await capture.setUp([adapter]);
      await captureScenario(adapter);
      final replay = InteractionHarness.replay(
        capture.encodedEvents(),
        dependencies: capture.dependencies(),
      );
      final throwing = ThrowingFirestoreClient();
      final replayAdapter = BugCapsuleFirestore(client: throwing);
      await replay.setUp([replayAdapter]);
      return (replay, replayAdapter, throwing);
    }

    test('an unrecorded read fails with native.unrecorded', () async {
      final (replay, f, throwing) = await replayOf(
        (f) => f.getDocument('orders/1'),
      );
      await f.getDocument('orders/1');
      await expectLater(
        f.getDocument('users/alice'),
        throwsA(
          isA<NativeAdapterException>().having(
            (e) => e.code,
            'code',
            'bugcapsule.unrecorded',
          ),
        ),
      );
      expect(replay.finish().map((d) => d.type), ['native.unrecorded']);
      expect(throwing.calls, 0);
    });

    test('changed write arguments fail with native.mismatch', () async {
      final (replay, f, throwing) = await replayOf(
        (f) => f.updateDocument('orders/1', {'status': 'paid'}),
      );
      await expectLater(
        f.updateDocument('orders/1', {'status': 'refunded'}),
        throwsA(isA<NativeAdapterException>()),
      );
      final types = replay.finish().map((d) => d.type).toList();
      expect(types, contains('native.mismatch'));
      expect(types, contains('native.unused'));
      expect(throwing.calls, 0);
    });

    test(
      'replay without a Firestore recording never calls Firestore',
      () async {
        final replay = InteractionHarness.replay(
          const [],
          dependencies: const [],
        );
        final throwing = ThrowingFirestoreClient();
        final f = BugCapsuleFirestore(client: throwing);
        await replay.setUp([f]);
        await expectLater(
          f.getDocument('orders/1'),
          throwsA(isA<NativeAdapterException>()),
        );
        await expectLater(
          f.documentSnapshots('orders/1').first,
          throwsA(isA<NativeAdapterException>()),
        );
        await expectLater(
          f.deleteDocument('orders/1'),
          throwsA(isA<NativeAdapterException>()),
        );
        expect(throwing.calls, 0);
        expect(replay.finish().map((d) => d.type).toSet(), {
          'native.unrecorded',
        });
      },
    );
  });

  group('values', () {
    test(
      'Firestore values round-trip losslessly through cloud_firestore',
      () async {
        final r = await AdapterConformance.run(
          create: (replaying) {
            if (replaying) {
              return BugCapsuleFirestore(
                client: ThrowingFirestoreClient(),
                captureBinary: true,
              );
            }
            final db = FakeFirebaseFirestore();
            db.doc('places/home').set({
              'at': Timestamp(1700000000, 123456789),
              'where': const GeoPoint(59.9139, 10.7522),
              'owner': db.doc('users/alice'),
              'avatar': Blob(Uint8List.fromList([0, 1, 2, 254, 255])),
              'count': 3,
              'ratio': 2.0,
              'tags': ['a', 1, 1.5, null],
              'nested': {
                r'$fs': 'not a tag',
                'deep': {'n': -0.0},
              },
            });
            return BugCapsuleFirestore(firestore: db, captureBinary: true);
          },
          scenario: (f) async {
            final d = await f.getDocument('places/home');
            final data = d.data!;
            return [
              docJson(d),
              (data['at']! as Timestamp).nanoseconds,
              (data['where']! as GeoPoint).longitude,
              (data['owner']! as FirestoreReference).path,
              (data['avatar']! as Blob).bytes.toList(),
              data['count'].runtimeType.toString(),
              data['ratio'].runtimeType.toString(),
              (data['nested']! as Map)[r'$fs'],
            ];
          },
        );
        expect(r.problems, isEmpty);
        expect((r.replayed! as List).skip(1), [
          123456789,
          10.7522,
          'users/alice',
          [0, 1, 2, 254, 255],
          'int',
          'double',
          'not a tag',
        ]);
      },
    );

    test('binary fields are metadata unless captureBinary', () async {
      final capture = InteractionHarness.capture();
      final db = FakeFirebaseFirestore();
      await db.doc('files/1').set({
        'b': Blob(Uint8List.fromList([1, 2])),
      });
      final f = BugCapsuleFirestore(firestore: db);
      await capture.setUp([f]);
      await f.getDocument('files/1');
      final result = capture.events.firstWhere(
        (e) => e.type == 'native.result',
      );
      expect((result.data['value'] as Map)['mode'], 'metadata');
      expect(
        capture.dependencies().single.gaps.map((g) => g.code),
        contains(DependencyGaps.payloadBinaryMetadata),
      );
    });

    test('field value sentinels are recorded as tagged strings', () async {
      final capture = InteractionHarness.capture();
      final db = FakeFirebaseFirestore();
      await db.doc('carts/1').set({'n': 1, 'tags': <String>[]});
      final f = BugCapsuleFirestore(firestore: db);
      await capture.setUp([f]);
      await f.updateDocument('carts/1', {
        'n': FirestoreFieldValue.increment(2),
        'tags': FirestoreFieldValue.arrayUnion(['x']),
        'at': FirestoreFieldValue.serverTimestamp(),
        'gone': FirestoreFieldValue.delete(),
        'raw': FieldValue.serverTimestamp(),
      });
      final args = (capture.events.first.data['args'] as Map)['value'] as Map;
      expect(args['data'], {
        'n': r'$FieldValue.increment(2)',
        'tags': r'$FieldValue.arrayUnion(["x"])',
        'at': r'$FieldValue.serverTimestamp()',
        'gone': r'$FieldValue.delete()',
        'raw': r'$FieldValue',
      });
      final written = (await db.doc('carts/1').get()).data()!;
      expect(written['n'], 3);
      expect(written['tags'], ['x']);
      expect(written['at'], isA<Timestamp>());
    });

    test('queries run against cloud_firestore', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('orders/1').set({'status': 'open', 'total': 5});
      await db.doc('orders/2').set({'status': 'open', 'total': 9});
      await db.doc('orders/3').set({'status': 'paid', 'total': 7});
      final f = BugCapsuleFirestore(firestore: db);
      final result = await f.getQuery(
        const FirestoreQuery(
          'orders',
          where: [
            FirestoreFilter('status', FirestoreFilterOp.isEqualTo, 'open'),
          ],
          orderBy: [FirestoreOrder('total', descending: true)],
          limit: 1,
        ),
      );
      expect(result.docs.map((d) => d.id), ['2']);
    });
  });
}
