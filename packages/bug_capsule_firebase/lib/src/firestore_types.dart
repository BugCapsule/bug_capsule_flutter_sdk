import 'dart:convert';
import 'dart:typed_data';

import 'package:bug_capsule/bug_capsule.dart' show TypedValue, canonicalJson;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show immutable, listEquals;

/// A document reference inside Firestore data, by path.
///
/// Snapshot data hands the app this type instead of a [DocumentReference]
/// (capture and replay alike), because replay has no Firestore instance to
/// build a reference with. Write data may use either.
@immutable
class FirestoreReference {
  const FirestoreReference(this.path);

  /// Slash-separated document path, e.g. `users/alice`.
  final String path;

  String get id => path.substring(path.lastIndexOf('/') + 1);

  @override
  bool operator ==(Object other) =>
      other is FirestoreReference && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'FirestoreReference($path)';
}

/// Snapshot metadata: whether the result came from the local cache and
/// whether it includes local writes the server has not confirmed yet.
@immutable
class FirestoreMetadata {
  const FirestoreMetadata({
    this.isFromCache = false,
    this.hasPendingWrites = false,
  });

  final bool isFromCache;
  final bool hasPendingWrites;

  @override
  bool operator ==(Object other) =>
      other is FirestoreMetadata &&
      other.isFromCache == isFromCache &&
      other.hasPendingWrites == hasPendingWrites;

  @override
  int get hashCode => Object.hash(isFromCache, hasPendingWrites);

  @override
  String toString() =>
      'FirestoreMetadata(fromCache: $isFromCache, pendingWrites: $hasPendingWrites)';
}

/// What the app saw of one document: its data (null when it does not
/// exist) and the snapshot metadata.
@immutable
class FirestoreDocument {
  const FirestoreDocument({
    required this.path,
    this.data,
    this.metadata = const FirestoreMetadata(),
  });

  final String path;

  /// Field values: `null`, `bool`, `int`, `double`, `String`, [Timestamp],
  /// [GeoPoint], [Blob], [VectorValue], [FirestoreReference], lists and
  /// maps of those. Null when the document does not exist.
  final Map<String, Object?>? data;
  final FirestoreMetadata metadata;

  String get id => path.substring(path.lastIndexOf('/') + 1);
  bool get exists => data != null;

  Object? operator [](String field) => data?[field];

  @override
  String toString() => 'FirestoreDocument($path, exists: $exists, $metadata)';
}

/// How a query result changed since the previous snapshot of a listener.
@immutable
class FirestoreDocumentChange {
  const FirestoreDocumentChange({
    required this.type,
    required this.document,
    required this.oldIndex,
    required this.newIndex,
  });

  final DocumentChangeType type;
  final FirestoreDocument document;

  /// -1 for [DocumentChangeType.added].
  final int oldIndex;

  /// -1 for [DocumentChangeType.removed].
  final int newIndex;
}

/// What the app saw of a query: the matching documents, the changes since
/// the previous snapshot (listeners) and the metadata.
@immutable
class FirestoreQueryResult {
  const FirestoreQueryResult({
    required this.docs,
    this.changes = const [],
    this.metadata = const FirestoreMetadata(),
  });

  final List<FirestoreDocument> docs;
  final List<FirestoreDocumentChange> changes;
  final FirestoreMetadata metadata;

  int get size => docs.length;
  bool get isEmpty => docs.isEmpty;
}

/// Comparison of a [FirestoreFilter].
enum FirestoreFilterOp {
  isEqualTo,
  isNotEqualTo,
  isLessThan,
  isLessThanOrEqualTo,
  isGreaterThan,
  isGreaterThanOrEqualTo,
  arrayContains,
  arrayContainsAny,
  whereIn,
  whereNotIn,
  isNull,
}

/// One `where` clause of a [FirestoreQuery]. `value` is a list for
/// [FirestoreFilterOp.arrayContainsAny], [FirestoreFilterOp.whereIn] and
/// [FirestoreFilterOp.whereNotIn], a bool for [FirestoreFilterOp.isNull].
@immutable
class FirestoreFilter {
  const FirestoreFilter(this.field, this.op, this.value);

  /// Dot-separated field path.
  final String field;
  final FirestoreFilterOp op;
  final Object? value;
}

@immutable
class FirestoreOrder {
  const FirestoreOrder(this.field, {this.descending = false});

  final String field;
  final bool descending;
}

/// A small, serializable query description: one collection (or collection
/// group), `where` filters joined by AND, `orderBy` clauses and a limit.
/// Cursors, OR filters and aggregate queries are not supported.
@immutable
class FirestoreQuery {
  const FirestoreQuery(
    this.collection, {
    this.collectionGroup = false,
    this.where = const [],
    this.orderBy = const [],
    this.limit,
    this.limitToLast,
  });

  /// Collection path (`users/alice/orders`) or, with [collectionGroup], the
  /// collection id.
  final String collection;
  final bool collectionGroup;
  final List<FirestoreFilter> where;
  final List<FirestoreOrder> orderBy;
  final int? limit;
  final int? limitToLast;

  /// The recorded (and matched) form of this query.
  Map<String, Object?> toJson() => {
    'collection': collection,
    if (collectionGroup) 'group': true,
    if (where.isNotEmpty)
      'where': [
        for (final f in where)
          [f.field, f.op.name, FirestoreValues.encode(f.value)],
      ],
    if (orderBy.isNotEmpty)
      'orderBy': [
        for (final o in orderBy) [o.field, o.descending],
      ],
    'limit': ?limit,
    'limitToLast': ?limitToLast,
  };
}

/// Write sentinels with a recordable description. They become the matching
/// [FieldValue] when written to Firestore, and a tagged string in the
/// capsule (`$FieldValue.serverTimestamp()`), so a write's arguments match
/// exactly in replay. Plain [FieldValue]s work too, but are recorded as an
/// opaque `$FieldValue` tag.
@immutable
class FirestoreFieldValue {
  const FirestoreFieldValue._(this.kind, [this.operand]);

  static const FirestoreFieldValue _serverTimestamp = FirestoreFieldValue._(
    'serverTimestamp',
  );
  static const FirestoreFieldValue _delete = FirestoreFieldValue._('delete');

  factory FirestoreFieldValue.serverTimestamp() => _serverTimestamp;
  factory FirestoreFieldValue.delete() => _delete;
  factory FirestoreFieldValue.increment(num by) =>
      FirestoreFieldValue._('increment', by);
  factory FirestoreFieldValue.arrayUnion(List<Object?> elements) =>
      FirestoreFieldValue._('arrayUnion', List.unmodifiable(elements));
  factory FirestoreFieldValue.arrayRemove(List<Object?> elements) =>
      FirestoreFieldValue._('arrayRemove', List.unmodifiable(elements));

  final String kind;
  final Object? operand;

  /// The tagged string recorded for this sentinel.
  String get tag => operand == null
      ? '\$FieldValue.$kind()'
      : '\$FieldValue.$kind(${canonicalJson(TypedValue.encode(FirestoreValues.encode(operand)))})';

  @override
  bool operator ==(Object other) =>
      other is FirestoreFieldValue &&
      other.kind == kind &&
      (operand is List
          ? other.operand is List &&
                listEquals(other.operand as List, operand as List)
          : other.operand == operand);

  @override
  int get hashCode => Object.hash(kind, operand);

  @override
  String toString() => tag;
}

/// Lossless adapter-level JSON for Firestore values (inside the capsule's
/// typed values): [Timestamp], [GeoPoint], [Blob], [VectorValue] and
/// references become objects tagged with `$fs`; a data map that has its
/// own `$fs` key is wrapped so it never reads as a tag.
abstract final class FirestoreValues {
  static const tag = r'$fs';

  static Object? encode(Object? value) {
    return switch (value) {
      null || bool() || num() || String() => value,
      Timestamp() => {
        tag: 'timestamp',
        's': value.seconds,
        'ns': value.nanoseconds,
      },
      DateTime() => {
        tag: 'datetime',
        'us': value.microsecondsSinceEpoch,
        'utc': value.isUtc,
      },
      GeoPoint() => {
        tag: 'geopoint',
        'lat': value.latitude,
        'lng': value.longitude,
      },
      Blob() => {tag: 'blob', 'bytes': value.bytes},
      VectorValue() => {tag: 'vector', 'v': List<double>.of(value.toArray())},
      FirestoreReference() => {tag: 'ref', 'path': value.path},
      DocumentReference() => {tag: 'ref', 'path': value.path},
      FirestoreFieldValue() => value.tag,
      FieldValue() => r'$FieldValue',
      Uint8List() => value,
      List() => [for (final v in value) encode(v)],
      Map() => _encodeMap(value),
      _ => value,
    };
  }

  static Object _encodeMap(Map<Object?, Object?> map) {
    final out = <String, Object?>{
      for (final e in map.entries) '${e.key}': encode(e.value),
    };
    return out.containsKey(tag) ? {tag: 'map', 'v': out} : out;
  }

  /// The inverse of [encode] for plain Dart values (typed values already
  /// decoded).
  static Object? decode(Object? json) {
    if (json is List) return [for (final v in json) decode(v)];
    if (json is! Map) return json;
    final t = json[tag];
    if (t == null) return decodeMap(json);
    switch (t) {
      case 'timestamp':
        return Timestamp(_int(json['s']), _int(json['ns']));
      case 'datetime':
        return DateTime.fromMicrosecondsSinceEpoch(
          _int(json['us']),
          isUtc: json['utc'] == true,
        );
      case 'geopoint':
        return GeoPoint(_double(json['lat']), _double(json['lng']));
      case 'blob':
        final bytes = json['bytes'];
        return Blob(
          bytes is Uint8List
              ? bytes
              : bytes is String
              ? base64Decode(bytes)
              : Uint8List.fromList([for (final b in bytes as List) b as int]),
        );
      case 'vector':
        return VectorValue([for (final v in json['v'] as List) _double(v)]);
      case 'ref':
        return FirestoreReference(json['path'] as String);
      case 'map':
        return decodeMap(json['v'] as Map);
    }
    throw FormatException('unknown Firestore value tag $t');
  }

  static Map<String, Object?> decodeMap(Map<Object?, Object?> json) => {
    for (final e in json.entries) '${e.key}': decode(e.value),
  };

  static int _int(Object? v) => (v as num).toInt();
  static double _double(Object? v) => (v as num).toDouble();
}

/// The recorded form of documents, query results and metadata.
abstract final class FirestoreJson {
  static Map<String, Object?> metadata(FirestoreMetadata m) => {
    'fromCache': m.isFromCache,
    'pendingWrites': m.hasPendingWrites,
  };

  static FirestoreMetadata readMetadata(Object? json) {
    final m = json is Map ? json : const {};
    return FirestoreMetadata(
      isFromCache: m['fromCache'] == true,
      hasPendingWrites: m['pendingWrites'] == true,
    );
  }

  static Map<String, Object?> document(FirestoreDocument d) => {
    'path': d.path,
    'data': d.data == null ? null : FirestoreValues.encode(d.data),
    'meta': metadata(d.metadata),
  };

  static FirestoreDocument readDocument(Object? json) {
    final m = json as Map;
    final data = m['data'];
    return FirestoreDocument(
      path: m['path'] as String,
      data: data == null
          ? null
          : (FirestoreValues.decode(data) as Map).cast<String, Object?>(),
      metadata: readMetadata(m['meta']),
    );
  }

  /// Changes of added and modified documents point into `docs` by
  /// `newIndex`; only removed documents are recorded in full.
  static Map<String, Object?> query(FirestoreQueryResult r) => {
    'docs': [for (final d in r.docs) document(d)],
    if (r.changes.isNotEmpty)
      'changes': [
        for (final c in r.changes)
          {
            'type': c.type.name,
            'old': c.oldIndex,
            'new': c.newIndex,
            if (c.type == DocumentChangeType.removed ||
                c.newIndex < 0 ||
                c.newIndex >= r.docs.length ||
                !identical(r.docs[c.newIndex], c.document))
              'doc': document(c.document),
          },
      ],
    'meta': metadata(r.metadata),
  };

  static FirestoreQueryResult readQuery(Object? json) {
    final m = json as Map;
    final docs = [for (final d in m['docs'] as List) readDocument(d)];
    return FirestoreQueryResult(
      docs: docs,
      changes: [
        for (final c in (m['changes'] as List?) ?? const [])
          _readChange(c as Map, docs),
      ],
      metadata: readMetadata(m['meta']),
    );
  }

  static FirestoreDocumentChange _readChange(
    Map<Object?, Object?> c,
    List<FirestoreDocument> docs,
  ) {
    final newIndex = (c['new'] as num).toInt();
    final doc = c['doc'];
    return FirestoreDocumentChange(
      type: DocumentChangeType.values.byName(c['type'] as String),
      document: doc != null ? readDocument(doc) : docs[newIndex],
      oldIndex: (c['old'] as num).toInt(),
      newIndex: newIndex,
    );
  }
}
