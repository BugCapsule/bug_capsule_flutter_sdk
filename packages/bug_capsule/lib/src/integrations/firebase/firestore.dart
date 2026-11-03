import 'package:bug_capsule/bug_capsule.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'adapter_support.dart';
import 'firestore_client.dart';
import 'firestore_types.dart';

/// Cloud Firestore adapter (`bug_capsule.cloud_firestore`, capsule-v2
/// `native`).
///
/// Records what the app saw of document reads, document and query
/// listeners, and the outcome of `set` / `update` / `delete`: data with
/// metadata (`isFromCache`, `hasPendingWrites`), so cached results and
/// optimistic local updates replay as they happened. Replay hands back the
/// recorded results without contacting Firestore; an operation the capsule
/// does not contain fails with `bugcapsule.unrecorded`.
///
/// ```dart
/// final firestore = BugCapsuleFirestore();
/// await BugCapsule.init(integrations: [firestore, ...]);
///
/// final order = await firestore.getDocument('orders/42');
/// firestore.documentSnapshots('orders/42').listen(render);
/// await firestore.updateDocument('orders/42', {
///   'status': 'paid',
///   'paidAt': FirestoreFieldValue.serverTimestamp(),
/// });
/// ```
///
/// Not supported (no API is offered): transactions, batched writes,
/// aggregate queries, query cursors, OR filters, bundles and persistence
/// controls. Use `cloud_firestore` directly for those; they are neither
/// recorded nor replayed.
class BugCapsuleFirestore extends NativeAdapter with FirebaseAdapterSupport {
  /// Uses [client] when given, else a [CloudFirestoreClient] over
  /// [firestore] (by default `FirebaseFirestore.instance`, created on first
  /// use while capturing; never during replay).
  BugCapsuleFirestore({
    FirebaseFirestore? firestore,
    FirestoreClient? client,
    super.captureBinary,
    super.redactedReplayable,
  }) : _firestore = firestore,
       _client = client;

  final FirebaseFirestore? _firestore;
  FirestoreClient? _client;

  /// The client operations run against while capturing (or when BugCapsule
  /// is not recording).
  FirestoreClient get client => _client ??= CloudFirestoreClient(
    _firestore ?? FirebaseFirestore.instance,
  );

  @override
  String get name => 'cloud_firestore';

  @override
  String get adapter => 'bug_capsule.cloud_firestore';

  @override
  String get plugin => 'cloud_firestore';

  static const supportedOperations = [
    'document.get',
    'document.snapshots',
    'query.get',
    'query.snapshots',
    'document.set',
    'document.update',
    'document.delete',
  ];

  @override
  List<String> get operations => supportedOperations;

  @override
  Map<String, String> get tested => const {
    'cloud_firestore': '7.1.0',
    'cloud_firestore_platform_interface': '8.1.0',
    'firebase_core': '5.1.0',
  };

  /// Reads the document at [path] from [source].
  Future<FirestoreDocument> getDocument(
    String path, {
    Source source = Source.serverAndCache,
  }) => guardedCall(
    'document.get',
    args: {'path': path, 'source': source.name},
    invoke: () => client.getDocument(path, source),
    encode: FirestoreJson.document,
    decode: FirestoreJson.readDocument,
  );

  /// Listens to the document at [path]. With [includeMetadataChanges],
  /// snapshots that only change metadata (a cached result confirmed by the
  /// server, a local write acknowledged) are delivered too.
  Stream<FirestoreDocument> documentSnapshots(
    String path, {
    bool includeMetadataChanges = false,
  }) => guardedSubscribe(
    'document.snapshots',
    args: {'path': path, 'metadataChanges': includeMetadataChanges},
    open: () => client.documentSnapshots(
      path,
      includeMetadataChanges: includeMetadataChanges,
    ),
    encode: FirestoreJson.document,
    decode: FirestoreJson.readDocument,
  );

  Future<FirestoreQueryResult> getQuery(
    FirestoreQuery query, {
    Source source = Source.serverAndCache,
  }) => guardedCall(
    'query.get',
    args: {'query': query.toJson(), 'source': source.name},
    invoke: () => client.getQuery(query, source),
    encode: FirestoreJson.query,
    decode: FirestoreJson.readQuery,
  );

  Stream<FirestoreQueryResult> querySnapshots(
    FirestoreQuery query, {
    bool includeMetadataChanges = false,
  }) => guardedSubscribe(
    'query.snapshots',
    args: {'query': query.toJson(), 'metadataChanges': includeMetadataChanges},
    open: () => client.querySnapshots(
      query,
      includeMetadataChanges: includeMetadataChanges,
    ),
    encode: FirestoreJson.query,
    decode: FirestoreJson.readQuery,
  );

  /// Writes [data] to [path] (merging with [merge]). Completes when the
  /// server confirmed the write, or fails with the recorded
  /// [FirebaseException] (e.g. `permission-denied`).
  Future<void> setDocument(
    String path,
    Map<String, Object?> data, {
    bool merge = false,
  }) => _write('document.set', {
    'path': path,
    'data': FirestoreValues.encode(data),
    'merge': merge,
  }, () => client.setDocument(path, data, merge: merge));

  /// Updates fields of [path]; keys are field paths (`address.city`).
  Future<void> updateDocument(String path, Map<String, Object?> data) => _write(
    'document.update',
    {'path': path, 'data': FirestoreValues.encode(data)},
    () => client.updateDocument(path, data),
  );

  Future<void> deleteDocument(String path) => _write('document.delete', {
    'path': path,
  }, () => client.deleteDocument(path));

  Future<void> _write(
    String operation,
    Map<String, Object?> args,
    Future<void> Function() invoke,
  ) => guardedCall<void>(
    operation,
    args: args,
    invoke: invoke,
    encode: (_) => null,
    decode: (_) {},
  );
}
