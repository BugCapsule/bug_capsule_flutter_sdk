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

export 'src/integrations/firebase/auth.dart' show AuthUser, BugCapsuleFirebaseAuth;
export 'src/integrations/firebase/firestore.dart' show BugCapsuleFirestore;
export 'src/integrations/firebase/firestore_client.dart' show CloudFirestoreClient, FirestoreClient;
export 'src/integrations/firebase/firestore_types.dart';
export 'src/integrations/firebase/version.dart';
