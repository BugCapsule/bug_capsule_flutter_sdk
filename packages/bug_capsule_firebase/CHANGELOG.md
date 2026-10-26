## 0.1.0-dev.1

- Pilot release. `BugCapsuleFirebaseAuth` (`bug_capsule.firebase_auth`) records `currentUser`, `authStateChanges` and `userChanges` as `AuthUser` identity state, never tokens or credentials. Profile fields are synthetic by default.
- `BugCapsuleFirestore` (`bug_capsule.cloud_firestore`) records document reads (with `Source`), document and query listeners (with `includeMetadataChanges`), and the outcome of `set` / `update` / `delete`. Results keep `isFromCache` and `hasPendingWrites`, so cached results and optimistic local writes replay. Firestore values round-trip losslessly.
- Transactions, batched writes and Firebase Messaging are not supported.
