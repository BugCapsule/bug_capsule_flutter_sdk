import 'dart:convert';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/testing.dart';
import 'package:bug_capsule_firebase/bug_capsule_firebase.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// `MockUser` does not implement `tenantId`; the real `User` does.
// ignore: must_be_immutable
class TestUser extends MockUser {
  TestUser({
    super.uid,
    super.email,
    super.displayName,
    super.phoneNumber,
    super.refreshToken,
    super.isAnonymous,
    super.providerData,
    super.metadata,
  });

  @override
  String? get tenantId => null;
}

final alice = TestUser(
  uid: 'uid-alice',
  email: 'alice@example.com',
  displayName: 'Alice Example',
  phoneNumber: '+4712345678',
  refreshToken: 'refresh-token-value-123',
  providerData: [_Provider('password')],
  metadata: _Metadata(
    DateTime.utc(2023, 11, 14, 22, 13, 20),
    DateTime.utc(2023, 11, 14, 22, 21, 40),
  ),
);

class _Provider implements UserInfo {
  _Provider(this.providerId);

  @override
  final String providerId;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Metadata implements UserMetadata {
  _Metadata(this.creationTime, this.lastSignInTime);

  @override
  final DateTime creationTime;
  @override
  final DateTime lastSignInTime;
}

/// What app logic usually branches on: identity, not profile values.
Object? identity(AuthUser? u) => u == null
    ? null
    : [u.uid, u.isAnonymous, u.emailVerified, u.email != null, u.providerIds];

void main() {
  late MockFirebaseAuth mock;
  late List<ThrowingFirebaseAuth> throwing;

  BugCapsuleFirebaseAuth create(bool replaying, {bool recordProfile = false}) {
    if (!replaying) {
      return BugCapsuleFirebaseAuth(auth: mock, recordProfile: recordProfile);
    }
    final t = ThrowingFirebaseAuth();
    throwing.add(t);
    return BugCapsuleFirebaseAuth(auth: t, recordProfile: recordProfile);
  }

  /// Drives sign-in only while capturing; replay serves the recording.
  Future<void> whileCapturing(Future<void> Function() action) async {
    if (throwing.isEmpty) await action();
  }

  setUp(() {
    mock = MockFirebaseAuth(mockUser: alice);
    throwing = [];
  });

  group('conformance (isolated replay, throwing FirebaseAuth)', () {
    test('auth.currentUser', () async {
      final r = await AdapterConformance.run(
        create: create,
        scenario: (auth) async {
          final before = await auth.currentUser();
          await whileCapturing(
            () => mock.signInWithEmailAndPassword(
              email: 'alice@example.com',
              password: 'pw',
            ),
          );
          final after = await auth.currentUser();
          return [identity(before), identity(after)];
        },
      );
      expect(r.problems, isEmpty);
      expect(r.replayed, [
        null,
        [
          'uid-alice',
          false,
          true,
          true,
          ['password'],
        ],
      ]);
      expect(throwing.single.calls, 0);
    });

    test('auth.authStateChanges', () async {
      final r = await AdapterConformance.run(
        create: create,
        scenario: (auth) async {
          final events = takeEvents(auth.authStateChanges(), 4);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await whileCapturing(() async {
            await mock.signInWithEmailAndPassword(
              email: 'alice@example.com',
              password: 'pw',
            );
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await mock.signOut();
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await mock.signInWithEmailAndPassword(
              email: 'alice@example.com',
              password: 'pw',
            );
          });
          return [for (final u in await events) identity(u)];
        },
      );
      expect(r.problems, isEmpty);
      // Initial state on listen, sign-in, sign-out, sign-in.
      expect(
        [for (final u in r.replayed! as List) (u as List?)?.first],
        [null, 'uid-alice', null, 'uid-alice'],
      );
    });

    test('auth.userChanges', () async {
      final r = await AdapterConformance.run(
        create: create,
        scenario: (auth) async {
          final events = takeEvents(auth.userChanges(), 3);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await whileCapturing(() async {
            await mock.signInWithEmailAndPassword(
              email: 'alice@example.com',
              password: 'pw',
            );
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await mock.signOut();
          });
          return [for (final u in await events) identity(u)];
        },
      );
      expect(r.problems, isEmpty);
      expect(r.replayed, [
        null,
        [
          'uid-alice',
          false,
          true,
          true,
          ['password'],
        ],
        null,
      ]);
    });
  });

  test(
    'profile fields are synthetic by default and tokens never recorded',
    () async {
      final r = await AdapterConformance.run(
        create: create,
        scenario: (auth) async {
          await whileCapturing(
            () => mock.signInWithEmailAndPassword(
              email: 'alice@example.com',
              password: 'pw',
            ),
          );
          final u = (await auth.currentUser())!;
          return [u.uid, u.email != null, u.displayName != null];
        },
      );
      expect(r.problems, isEmpty);
      final recorded = jsonEncode([for (final e in r.events) e.toJson()]);
      expect(recorded, isNot(contains('alice@example.com')));
      expect(recorded, isNot(contains('Alice Example')));
      expect(recorded, isNot(contains('+4712345678')));
      expect(recorded, isNot(contains('refresh-token-value-123')));
      expect(recorded.toLowerCase(), isNot(contains('token')));
      expect(recorded, contains(BugCapsuleFirebaseAuth.syntheticEmail));

      // Replay hands the app safe synthetic identity state.
      final replay = InteractionHarness.replay([
        for (final e in r.events) e,
      ], dependencies: r.dependencies);
      final auth = create(true);
      await replay.setUp([auth]);
      final u = (await auth.currentUser())!;
      expect(u.uid, 'uid-alice');
      expect(u.email, BugCapsuleFirebaseAuth.syntheticEmail);
      expect(u.displayName, BugCapsuleFirebaseAuth.syntheticDisplayName);
      expect(u.phoneNumber, BugCapsuleFirebaseAuth.syntheticPhoneNumber);
      expect(replay.finish(), isEmpty);
    },
  );

  test('recordProfile keeps the real profile values', () async {
    final r = await AdapterConformance.run(
      create: (replaying) => create(replaying, recordProfile: true),
      scenario: (auth) async {
        await whileCapturing(
          () => mock.signInWithEmailAndPassword(
            email: 'alice@example.com',
            password: 'pw',
          ),
        );
        final u = (await auth.currentUser())!;
        return [u.email, u.displayName];
      },
    );
    expect(r.problems, isEmpty);
    expect(r.replayed, ['alice@example.com', 'Alice Example']);
  });

  test('replay without an auth recording never calls FirebaseAuth', () async {
    final replay = InteractionHarness.replay(const [], dependencies: const []);
    final auth = create(true);
    await replay.setUp([auth]);
    await expectLater(
      auth.currentUser(),
      throwsA(
        isA<NativeAdapterException>().having(
          (e) => e.code,
          'code',
          'bugcapsule.unrecorded',
        ),
      ),
    );
    await expectLater(
      auth.authStateChanges().first,
      throwsA(isA<NativeAdapterException>()),
    );
    expect(throwing.single.calls, 0);
    expect(replay.finish().map((d) => d.type).toSet(), {'native.unrecorded'});
  });

  test(
    'without BugCapsule set up, calls go straight to FirebaseAuth',
    () async {
      final anonymous = MockFirebaseAuth(
        signedIn: true,
        mockUser: TestUser(uid: 'anon', isAnonymous: true),
      );
      final auth = BugCapsuleFirebaseAuth(auth: anonymous);
      expect((await auth.currentUser())!.isAnonymous, isTrue);
    },
  );
}
