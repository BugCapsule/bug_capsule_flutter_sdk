# BugCapsule for Firebase

Native SDK adapters for [BugCapsule](https://docs.bugcapsule.com/flutter.html):
Firebase Auth identity state and Cloud Firestore reads, listeners and write
outcomes. While capturing, the adapters record what your app saw. During
replay they hand it back offline, without contacting Firebase, so a bug that
depends on a cached snapshot, an optimistic local write or a
`permission-denied` error comes back as it happened.

These adapters are dependency simulations. They reproduce your app's
behaviour, not Firebase's: security rules, offline persistence and conflict
resolution are not simulated.

## Install

```yaml
dependencies:
  bug_capsule: ^0.4.1-beta.6
  bug_capsule_firebase: ^0.1.0-dev.1
```

```dart
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_firebase/bug_capsule_firebase.dart';

final auth = BugCapsuleFirebaseAuth();
final firestore = BugCapsuleFirestore();

Future<void> main() async {
  await Firebase.initializeApp();
  await BugCapsule.init(integrations: [auth, firestore /*, ... */]);
  runApp(const MyApp());
}
```

Then read identity state and Firestore data through the adapters:

```dart
auth.authStateChanges().listen((user) => router.refresh(user));

final order = await firestore.getDocument('orders/42');
firestore
    .documentSnapshots('orders/42', includeMetadataChanges: true)
    .listen((doc) => render(doc.data, pending: doc.metadata.hasPendingWrites));

final open = await firestore.getQuery(const FirestoreQuery(
  'orders',
  where: [FirestoreFilter('status', FirestoreFilterOp.isEqualTo, 'open')],
  orderBy: [FirestoreOrder('createdAt', descending: true)],
  limit: 20,
));

await firestore.updateDocument('orders/42', {
  'status': 'paid',
  'paidAt': FirestoreFieldValue.serverTimestamp(),
});
```

Calls made before `BugCapsule.init`, or while BugCapsule is not recording,
go straight to Firebase.

## Supported operations

| Adapter | Operation | Recorded |
|---|---|---|
| `bug_capsule.firebase_auth` | `currentUser()` | `AuthUser` snapshot or `null` |
| | `authStateChanges()` | every `AuthUser?` the stream delivered, its errors and cancellation |
| | `userChanges()` | same |
| `bug_capsule.cloud_firestore` | `getDocument(path, source:)` | `FirestoreDocument` (data, `isFromCache`, `hasPendingWrites`) or the `FirebaseException` |
| | `documentSnapshots(path, includeMetadataChanges:)` | every snapshot, errors and listener teardown |
| | `getQuery(query, source:)` | `FirestoreQueryResult` (documents, changes, metadata) |
| | `querySnapshots(query, includeMetadataChanges:)` | every query snapshot with its document changes |
| | `setDocument`, `updateDocument`, `deleteDocument` | success, or the `FirebaseException` code (`permission-denied`, `not-found`, ...) |

**`AuthUser`** carries `uid`, `isAnonymous`, `emailVerified`, `email`,
`displayName`, `phoneNumber`, `providerIds`, `tenantId`, `creationTime` and
`lastSignInTime`. Tokens, refresh tokens and credentials are never read, so
they are never recorded and replay never needs them. By default `email`,
`displayName` and `phoneNumber` are recorded as synthetic values
(`BugCapsuleFirebaseAuth.syntheticEmail`, ...): replay keeps whether they
were set, not what they were. Pass `recordProfile: true` to record the real
values (your redaction rules still apply).

**Firestore values** round-trip losslessly: `int` vs `double`, `Timestamp`
(seconds and nanoseconds), `GeoPoint`, `Blob`, `VectorValue` and document
references. Snapshot data hands the app references as `FirestoreReference`
(a path), in capture and replay alike. Write data may contain
`FirestoreReference`, `DocumentReference`, `FirestoreFieldValue` sentinels
(`serverTimestamp`, `delete`, `increment`, `arrayUnion`, `arrayRemove`) and
plain `FieldValue`s. Sentinels are recorded as tagged strings such as
`$FieldValue.increment(1)`. A plain `FieldValue` is recorded as `$FieldValue`
only, so use `FirestoreFieldValue` when the operand matters for matching.

**Replay rules.** Operations are matched by arguments and invocation order.
Two listeners on the same document are told apart by the order they were
opened in. An operation the capsule does not contain fails with a
`NativeAdapterException` (`bugcapsule.unrecorded`) and a `native.unrecorded`
divergence. Changed arguments produce `native.mismatch`. Recorded Firebase
errors are thrown again as `FirebaseException` with the same plugin, code and
message.

## Tested versions

| Package | Version |
|---|---|
| `firebase_auth` | 7.0.1 |
| `firebase_auth_platform_interface` | 9.1.2 |
| `cloud_firestore` | 7.1.0 |
| `cloud_firestore_platform_interface` | 8.1.0 |
| `firebase_core` | 5.1.0 |

Tested with Flutter 3.47.8 against `firebase_auth_mocks` 0.16.0,
`fake_cloud_firestore` 4.5.0 and hand-written fakes. Not yet tested on a
device against a live Firebase project.

## Limits

- **No API for transactions, batched writes, aggregate queries, query
  cursors, OR filters, bundles, persistence settings or Firebase Messaging**
  (including background messages). Calls you make on `cloud_firestore` or
  `firebase_messaging` directly are neither recorded nor replayed, and they
  reach Firebase during replay.
- **Sign-in, sign-out, token and account calls are not covered.** Call them on
  `FirebaseAuth` directly and keep them out of replayed flows
  (`BugCapsule.isReplaying`): replay serves identity state only.
- `currentUser()` returns a `Future`, unlike `FirebaseAuth.currentUser`.
- Only reads and listeners made through the adapter are recorded. Snapshot
  data your app reads from `cloud_firestore` directly is not.
- `Blob` and other binary fields are recorded as metadata unless the adapter
  is created with `captureBinary: true`. A snapshot with a binary field is
  then not replayable (`payload.binaryMetadata` gap).
- Fields your redaction rules treat as sensitive (`token`, `password`,
  `secret`, ...) make that snapshot not replayable unless the adapter is
  created with `redactedReplayable: true`.
- The usual capture bounds apply: 64 KiB per payload, 1 MiB of interaction
  payloads per capsule, 32 open listeners.
- The project's capture settings can turn off one adapter
  (`bug_capsule.firebase_auth`, `bug_capsule.cloud_firestore`) without
  touching other capture.

## License

MIT. See [LICENSE](LICENSE).
