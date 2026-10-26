import 'dart:async';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_firebase/bug_capsule_firebase.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// A small Firestore stand-in with a server copy, a local cache, latency
/// and optimistic local writes: listeners see a write first with
/// `hasPendingWrites` and then the server's confirmation.
class FakeFirestoreClient implements FirestoreClient {
  FakeFirestoreClient({this.latency = const Duration(milliseconds: 15)});

  final Duration latency;
  final Map<String, Map<String, Object?>> server = {};
  final Map<String, Map<String, Object?>> cache = {};

  /// Writes to these paths fail with `permission-denied`.
  final Set<String> denied = {};
  final List<_Listener> _listeners = [];
  int calls = 0;

  FirestoreDocument _doc(
    String path,
    Map<String, Object?>? data, {
    bool fromCache = false,
    bool pending = false,
  }) => FirestoreDocument(
    path: path,
    data: data,
    metadata: FirestoreMetadata(
      isFromCache: fromCache,
      hasPendingWrites: pending,
    ),
  );

  @override
  Future<FirestoreDocument> getDocument(String path, Source source) async {
    calls++;
    if (source == Source.cache) {
      final cached = cache[path];
      if (cached == null) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'unavailable',
          message: 'document not in cache',
        );
      }
      return _doc(path, cached, fromCache: true);
    }
    await Future<void>.delayed(latency);
    return _doc(path, server[path]);
  }

  @override
  Stream<FirestoreDocument> documentSnapshots(
    String path, {
    required bool includeMetadataChanges,
  }) {
    calls++;
    late _Listener listener;
    final controller = StreamController<FirestoreDocument>(
      onCancel: () => _listeners.remove(listener),
    );
    listener = _Listener(path, includeMetadataChanges, controller);
    controller.onListen = () {
      _listeners.add(listener);
      final cached = cache[path];
      if (cached != null) {
        controller.add(_doc(path, cached, fromCache: true));
        Timer(latency, () {
          if (!controller.isClosed && _listeners.contains(listener)) {
            if (includeMetadataChanges || !_same(cached, server[path])) {
              controller.add(_doc(path, server[path]));
            }
          }
        });
      } else {
        scheduleMicrotask(() => controller.add(_doc(path, server[path])));
      }
    };
    return controller.stream;
  }

  @override
  Future<FirestoreQueryResult> getQuery(
    FirestoreQuery query,
    Source source,
  ) async {
    calls++;
    await Future<void>.delayed(latency);
    return _run(query);
  }

  @override
  Stream<FirestoreQueryResult> querySnapshots(
    FirestoreQuery query, {
    required bool includeMetadataChanges,
  }) {
    calls++;
    final controller = StreamController<FirestoreQueryResult>();
    controller.onListen = () {
      final first = _run(query);
      controller.add(
        FirestoreQueryResult(
          docs: first.docs,
          changes: [
            for (var i = 0; i < first.docs.length; i++)
              FirestoreDocumentChange(
                type: DocumentChangeType.added,
                document: first.docs[i],
                oldIndex: -1,
                newIndex: i,
              ),
          ],
          metadata: first.metadata,
        ),
      );
    };
    return controller.stream;
  }

  FirestoreQueryResult _run(FirestoreQuery q) {
    final prefix = '${q.collection}/';
    var docs = [
      for (final e in server.entries)
        if (e.key.startsWith(prefix) &&
            !e.key.substring(prefix.length).contains('/') &&
            q.where.every(
              (f) =>
                  f.op == FirestoreFilterOp.isEqualTo &&
                  e.value[f.field] == f.value,
            ))
          _doc(e.key, e.value),
    ];
    if (q.orderBy.isNotEmpty) {
      final o = q.orderBy.first;
      docs.sort((a, b) {
        final c = (a[o.field]! as Comparable<Object>).compareTo(b[o.field]!);
        return o.descending ? -c : c;
      });
    }
    if (q.limit case final n?) docs = docs.take(n).toList();
    return FirestoreQueryResult(docs: docs);
  }

  @override
  Future<void> setDocument(
    String path,
    Map<String, Object?> data, {
    required bool merge,
  }) => _write(path, (old) => {if (merge) ...?old, ...data});

  @override
  Future<void> updateDocument(String path, Map<String, Object?> data) =>
      _write(path, (old) {
        if (old == null) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'not-found',
            message: 'no document to update',
          );
        }
        return {...old, ...data};
      });

  @override
  Future<void> deleteDocument(String path) => _write(path, (_) => null);

  Future<void> _write(
    String path,
    Map<String, Object?>? Function(Map<String, Object?>? old) apply,
  ) async {
    calls++;
    if (denied.contains(path)) {
      await Future<void>.delayed(latency);
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
        message: 'Missing or insufficient permissions.',
      );
    }
    final next = apply(server[path]);
    // Optimistic local event, then the server's acknowledgement.
    for (final l in List.of(_listeners)) {
      if (l.path == path) l.controller.add(_doc(path, next, pending: true));
    }
    await Future<void>.delayed(latency);
    if (next == null) {
      server.remove(path);
    } else {
      server[path] = next;
    }
    for (final l in List.of(_listeners)) {
      if (l.path == path && l.includeMetadataChanges) {
        l.controller.add(_doc(path, next));
      }
    }
  }

  /// Pushes a server-side change to listeners of [path].
  void serverChange(String path, Map<String, Object?>? data) {
    if (data == null) {
      server.remove(path);
    } else {
      server[path] = data;
    }
    for (final l in List.of(_listeners)) {
      if (l.path == path) l.controller.add(_doc(path, data));
    }
  }

  static bool _same(Object? a, Object? b) =>
      canonicalJson(TypedValue.encode(FirestoreValues.encode(a))) ==
      canonicalJson(TypedValue.encode(FirestoreValues.encode(b)));
}

class _Listener {
  _Listener(this.path, this.includeMetadataChanges, this.controller);

  final String path;
  final bool includeMetadataChanges;
  final StreamController<FirestoreDocument> controller;
}

/// Fails the test if replay reaches Firestore.
class ThrowingFirestoreClient implements FirestoreClient {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('replay reached Firestore: ${invocation.memberName}');
  }
}

/// Fails the test if replay reaches Firebase Auth.
class ThrowingFirebaseAuth implements FirebaseAuth {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('replay reached FirebaseAuth: ${invocation.memberName}');
  }
}

/// Collects the first [n] events of [stream], then cancels it.
Future<List<T>> takeEvents<T>(
  Stream<T> stream,
  int n, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final out = <T>[];
  final done = Completer<void>();
  late StreamSubscription<T> sub;
  sub = stream.listen(
    (e) {
      out.add(e);
      if (out.length == n && !done.isCompleted) done.complete();
    },
    onError: (Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  try {
    await done.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
  return out;
}

/// JSON of what the app saw, for conformance comparisons.
Object? docJson(FirestoreDocument d) =>
    TypedValue.encode(FirestoreJson.document(d));

Object? queryJson(FirestoreQueryResult r) =>
    TypedValue.encode(FirestoreJson.query(r));
