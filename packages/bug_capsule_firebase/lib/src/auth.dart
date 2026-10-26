import 'package:bug_capsule/bug_capsule.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show immutable, listEquals;

import 'adapter_support.dart';

/// The identity state the app sees: who is signed in and how, without
/// tokens or credentials.
@immutable
class AuthUser {
  const AuthUser({
    required this.uid,
    this.isAnonymous = false,
    this.emailVerified = false,
    this.email,
    this.displayName,
    this.phoneNumber,
    this.providerIds = const [],
    this.tenantId,
    this.creationTime,
    this.lastSignInTime,
  });

  factory AuthUser.fromUser(User user) => AuthUser(
    uid: user.uid,
    isAnonymous: user.isAnonymous,
    emailVerified: user.emailVerified,
    email: user.email,
    displayName: user.displayName,
    phoneNumber: user.phoneNumber,
    providerIds: [for (final p in user.providerData) p.providerId],
    tenantId: user.tenantId,
    creationTime: user.metadata.creationTime,
    lastSignInTime: user.metadata.lastSignInTime,
  );

  final String uid;
  final bool isAnonymous;
  final bool emailVerified;
  final String? email;
  final String? displayName;
  final String? phoneNumber;

  /// `providerData[].providerId`, e.g. `password`, `google.com`.
  final List<String> providerIds;
  final String? tenantId;
  final DateTime? creationTime;
  final DateTime? lastSignInTime;

  @override
  bool operator ==(Object other) =>
      other is AuthUser &&
      other.uid == uid &&
      other.isAnonymous == isAnonymous &&
      other.emailVerified == emailVerified &&
      other.email == email &&
      other.displayName == displayName &&
      other.phoneNumber == phoneNumber &&
      listEquals(other.providerIds, providerIds) &&
      other.tenantId == tenantId &&
      other.creationTime == creationTime &&
      other.lastSignInTime == lastSignInTime;

  @override
  int get hashCode => Object.hash(
    uid,
    isAnonymous,
    emailVerified,
    email,
    displayName,
    phoneNumber,
    Object.hashAll(providerIds),
    tenantId,
    creationTime,
    lastSignInTime,
  );

  @override
  String toString() => 'AuthUser($uid, anonymous: $isAnonymous)';
}

/// Firebase Auth adapter (`bug_capsule.firebase_auth`, capsule-v2
/// `native`).
///
/// Records the identity state the app observed through
/// [authStateChanges], [userChanges] and [currentUser], as [AuthUser]
/// values. Tokens, refresh tokens and credentials are never read, so they
/// can never be recorded, and replay never needs them: replay hands the app
/// the recorded identity state without contacting Firebase.
///
/// By default the profile fields that identify a person (`email`,
/// `displayName`, `phoneNumber`) are replaced by synthetic values before
/// they are recorded ([syntheticEmail], [syntheticDisplayName],
/// [syntheticPhoneNumber]): replay keeps whether they were set, not what
/// they were. `uid`, provider ids and timestamps are recorded as they are,
/// since apps key their data by `uid`. Pass `recordProfile: true` to record
/// the real values (the session's redaction rules still apply).
///
/// ```dart
/// final auth = BugCapsuleFirebaseAuth();
/// await BugCapsule.init(integrations: [auth, ...]);
/// auth.authStateChanges().listen((user) => router.refresh(user));
/// ```
///
/// Sign-in, sign-out, token and account-management calls are not covered:
/// call them on `FirebaseAuth` directly, and keep them out of replayed
/// flows (`BugCapsule.isReplaying`), since replay serves identity state
/// only.
class BugCapsuleFirebaseAuth extends NativeAdapter with FirebaseAdapterSupport {
  BugCapsuleFirebaseAuth({FirebaseAuth? auth, this.recordProfile = false})
    : _auth = auth;

  static const syntheticEmail = 'redacted@redacted.invalid';
  static const syntheticDisplayName = 'Redacted User';
  static const syntheticPhoneNumber = '+10000000000';

  final FirebaseAuth? _auth;

  /// Record `email`, `displayName` and `phoneNumber` instead of synthetic
  /// values.
  final bool recordProfile;

  /// The [FirebaseAuth] read while capturing (by default
  /// `FirebaseAuth.instance`, first read on use; never during replay).
  FirebaseAuth get auth => _auth ?? FirebaseAuth.instance;

  @override
  String get name => 'firebase_auth';

  @override
  String get adapter => 'bug_capsule.firebase_auth';

  @override
  String get plugin => 'firebase_auth';

  static const supportedOperations = [
    'auth.currentUser',
    'auth.authStateChanges',
    'auth.userChanges',
  ];

  @override
  List<String> get operations => supportedOperations;

  @override
  Map<String, String> get tested => const {
    'firebase_auth': '7.0.1',
    'firebase_auth_platform_interface': '9.1.2',
    'firebase_core': '5.1.0',
  };

  /// A snapshot of `FirebaseAuth.currentUser`, null when signed out.
  Future<AuthUser?> currentUser() => guardedCall(
    'auth.currentUser',
    invoke: () async => _user(auth.currentUser),
    encode: _encode,
    decode: _decode,
  );

  /// Sign-in and sign-out (`FirebaseAuth.authStateChanges`).
  Stream<AuthUser?> authStateChanges() => guardedSubscribe(
    'auth.authStateChanges',
    open: () => auth.authStateChanges().map(_user),
    encode: _encode,
    decode: _decode,
  );

  /// Sign-in, sign-out and profile changes (`FirebaseAuth.userChanges`).
  Stream<AuthUser?> userChanges() => guardedSubscribe(
    'auth.userChanges',
    open: () => auth.userChanges().map(_user),
    encode: _encode,
    decode: _decode,
  );

  static AuthUser? _user(User? user) =>
      user == null ? null : AuthUser.fromUser(user);

  Object? _encode(AuthUser? u) {
    if (u == null) return null;
    String? profile(String? value, String synthetic) =>
        value == null || recordProfile ? value : synthetic;
    return {
      'uid': u.uid,
      'anonymous': u.isAnonymous,
      'emailVerified': u.emailVerified,
      'email': profile(u.email, syntheticEmail),
      'displayName': profile(u.displayName, syntheticDisplayName),
      'phoneNumber': profile(u.phoneNumber, syntheticPhoneNumber),
      'providers': u.providerIds,
      'tenantId': u.tenantId,
      'created': u.creationTime?.toUtc().microsecondsSinceEpoch,
      'lastSignIn': u.lastSignInTime?.toUtc().microsecondsSinceEpoch,
    };
  }

  static AuthUser? _decode(Object? json) {
    if (json == null) return null;
    final m = json as Map;
    DateTime? time(Object? us) => us == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch((us as num).toInt(), isUtc: true);
    return AuthUser(
      uid: m['uid'] as String,
      isAnonymous: m['anonymous'] == true,
      emailVerified: m['emailVerified'] == true,
      email: m['email'] as String?,
      displayName: m['displayName'] as String?,
      phoneNumber: m['phoneNumber'] as String?,
      providerIds: [
        for (final p in (m['providers'] as List?) ?? const []) '$p',
      ],
      tenantId: m['tenantId'] as String?,
      creationTime: time(m['created']),
      lastSignInTime: time(m['lastSignIn']),
    );
  }
}
