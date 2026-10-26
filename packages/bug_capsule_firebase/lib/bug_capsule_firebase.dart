/// BugCapsule native SDK adapters for Firebase (capsule-v2 `native`):
/// [BugCapsuleFirebaseAuth] for identity state and [BugCapsuleFirestore]
/// for Cloud Firestore reads, listeners and write outcomes.
///
/// ```dart
/// final auth = BugCapsuleFirebaseAuth();
/// final firestore = BugCapsuleFirestore();
/// await BugCapsule.init(integrations: [auth, firestore, ...]);
/// ```
///
/// The adapters are dependency simulations: they record what the app saw
/// and hand it back in replay without contacting Firebase. They never
/// reproduce Firebase's own behaviour (security rules, offline cache,
/// conflict resolution).
library;

export 'src/auth.dart' show AuthUser, BugCapsuleFirebaseAuth;
export 'src/firestore.dart' show BugCapsuleFirestore;
export 'src/firestore_client.dart' show CloudFirestoreClient, FirestoreClient;
export 'src/firestore_types.dart';
export 'src/version.dart';
