import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_types.dart';

/// The Firestore operations [BugCapsuleFirestore] records, in domain types.
///
/// [CloudFirestoreClient] implements it over `cloud_firestore`. Tests (and
/// apps that already hide Firestore behind their own repository layer) can
/// pass another implementation.
abstract interface class FirestoreClient {
  Future<FirestoreDocument> getDocument(String path, Source source);

  Stream<FirestoreDocument> documentSnapshots(
    String path, {
    required bool includeMetadataChanges,
  });

  Future<FirestoreQueryResult> getQuery(FirestoreQuery query, Source source);

  Stream<FirestoreQueryResult> querySnapshots(
    FirestoreQuery query, {
    required bool includeMetadataChanges,
  });

  Future<void> setDocument(
    String path,
    Map<String, Object?> data, {
    required bool merge,
  });

  Future<void> updateDocument(String path, Map<String, Object?> data);

  Future<void> deleteDocument(String path);
}

/// [FirestoreClient] over a `cloud_firestore` [FirebaseFirestore].
class CloudFirestoreClient implements FirestoreClient {
  CloudFirestoreClient(this.firestore);

  final FirebaseFirestore firestore;

  @override
  Future<FirestoreDocument> getDocument(String path, Source source) async =>
      document(await firestore.doc(path).get(GetOptions(source: source)));

  @override
  Stream<FirestoreDocument> documentSnapshots(
    String path, {
    required bool includeMetadataChanges,
  }) => firestore
      .doc(path)
      .snapshots(includeMetadataChanges: includeMetadataChanges)
      .map(document);

  @override
  Future<FirestoreQueryResult> getQuery(
    FirestoreQuery query,
    Source source,
  ) async => result(await build(query).get(GetOptions(source: source)));

  @override
  Stream<FirestoreQueryResult> querySnapshots(
    FirestoreQuery query, {
    required bool includeMetadataChanges,
  }) => build(
    query,
  ).snapshots(includeMetadataChanges: includeMetadataChanges).map(result);

  @override
  Future<void> setDocument(
    String path,
    Map<String, Object?> data, {
    required bool merge,
  }) => firestore
      .doc(path)
      .set(writeData(data), merge ? SetOptions(merge: true) : null);

  @override
  Future<void> updateDocument(String path, Map<String, Object?> data) =>
      firestore.doc(path).update(writeData(data));

  @override
  Future<void> deleteDocument(String path) => firestore.doc(path).delete();

  /// The `cloud_firestore` query for [q].
  Query<Map<String, dynamic>> build(FirestoreQuery q) {
    Query<Map<String, dynamic>> query = q.collectionGroup
        ? firestore.collectionGroup(q.collection)
        : firestore.collection(q.collection);
    for (final f in q.where) {
      final v = writeValue(f.value);
      final list = v is Iterable<Object?> ? v : null;
      query = switch (f.op) {
        FirestoreFilterOp.isEqualTo => query.where(f.field, isEqualTo: v),
        FirestoreFilterOp.isNotEqualTo => query.where(f.field, isNotEqualTo: v),
        FirestoreFilterOp.isLessThan => query.where(f.field, isLessThan: v),
        FirestoreFilterOp.isLessThanOrEqualTo => query.where(
          f.field,
          isLessThanOrEqualTo: v,
        ),
        FirestoreFilterOp.isGreaterThan => query.where(
          f.field,
          isGreaterThan: v,
        ),
        FirestoreFilterOp.isGreaterThanOrEqualTo => query.where(
          f.field,
          isGreaterThanOrEqualTo: v,
        ),
        FirestoreFilterOp.arrayContains => query.where(
          f.field,
          arrayContains: v,
        ),
        FirestoreFilterOp.arrayContainsAny => query.where(
          f.field,
          arrayContainsAny: list,
        ),
        FirestoreFilterOp.whereIn => query.where(f.field, whereIn: list),
        FirestoreFilterOp.whereNotIn => query.where(f.field, whereNotIn: list),
        FirestoreFilterOp.isNull => query.where(f.field, isNull: v as bool?),
      };
    }
    for (final o in q.orderBy) {
      query = query.orderBy(o.field, descending: o.descending);
    }
    if (q.limit case final limit?) query = query.limit(limit);
    if (q.limitToLast case final limit?) query = query.limitToLast(limit);
    return query;
  }

  /// Domain form of a snapshot: references become [FirestoreReference].
  static FirestoreDocument document(DocumentSnapshot<Object?> s) {
    final data = s.exists ? s.data() : null;
    return FirestoreDocument(
      path: s.reference.path,
      data: data is Map ? _readMap(data) : null,
      metadata: FirestoreMetadata(
        isFromCache: s.metadata.isFromCache,
        hasPendingWrites: s.metadata.hasPendingWrites,
      ),
    );
  }

  static FirestoreQueryResult result(QuerySnapshot<Object?> s) {
    final docs = [for (final d in s.docs) document(d)];
    return FirestoreQueryResult(
      docs: docs,
      changes: [
        for (final c in s.docChanges)
          FirestoreDocumentChange(
            type: c.type,
            document: c.newIndex >= 0 && c.newIndex < docs.length
                ? docs[c.newIndex]
                : document(c.doc),
            oldIndex: c.oldIndex,
            newIndex: c.newIndex,
          ),
      ],
      metadata: FirestoreMetadata(
        isFromCache: s.metadata.isFromCache,
        hasPendingWrites: s.metadata.hasPendingWrites,
      ),
    );
  }

  static Map<String, Object?> _readMap(Map<Object?, Object?> map) => {
    for (final e in map.entries) '${e.key}': _read(e.value),
  };

  static Object? _read(Object? v) => switch (v) {
    DocumentReference() => FirestoreReference(v.path),
    List() => [for (final x in v) _read(x)],
    Map() => _readMap(v),
    _ => v,
  };

  /// Write form of app data: [FirestoreFieldValue] and
  /// [FirestoreReference] become their `cloud_firestore` counterparts.
  Map<String, Object?> writeData(Map<String, Object?> data) => {
    for (final e in data.entries) e.key: writeValue(e.value),
  };

  Object? writeValue(Object? v) => switch (v) {
    FirestoreReference() => firestore.doc(v.path),
    FirestoreFieldValue() => _fieldValue(v),
    List() => [for (final x in v) writeValue(x)],
    Map() => {for (final e in v.entries) '${e.key}': writeValue(e.value)},
    _ => v,
  };

  FieldValue _fieldValue(FirestoreFieldValue v) {
    final operand = v.operand;
    return switch (v.kind) {
      'serverTimestamp' => FieldValue.serverTimestamp(),
      'delete' => FieldValue.delete(),
      'increment' => FieldValue.increment(operand! as num),
      'arrayUnion' => FieldValue.arrayUnion([
        for (final x in operand! as List) writeValue(x),
      ]),
      'arrayRemove' => FieldValue.arrayRemove([
        for (final x in operand! as List) writeValue(x),
      ]),
      _ => throw ArgumentError.value(v.kind, 'FirestoreFieldValue'),
    };
  }
}
