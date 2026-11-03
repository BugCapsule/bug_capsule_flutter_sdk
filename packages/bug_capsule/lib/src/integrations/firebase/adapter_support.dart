import 'dart:async';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;

import 'version.dart';

/// Shared behaviour of the Firebase adapters: version, [FirebaseException]
/// recording and rebuilding, and the replay guard.
mixin FirebaseAdapterSupport on NativeAdapter {
  /// `FirebaseException.plugin` used when a recorded error has none.
  String get plugin;

  @override
  String get adapterVersion => bugCapsuleFirebaseVersion;

  @override
  (String, String?, Object?) describeError(Object error) {
    if (error is FirebaseException) {
      return (error.code, _scrub(error.message), {'plugin': error.plugin});
    }
    final (code, message, details) = super.describeError(error);
    return (code, _scrub(message), details);
  }

  @override
  Object rebuildError(String code, String? message, Object? details) {
    if (code.startsWith('bugcapsule.')) {
      return super.rebuildError(code, message, details);
    }
    final p = details is Map ? details['plugin'] : null;
    return FirebaseException(
      plugin: p is String ? p : plugin,
      code: code,
      message: message,
    );
  }

  String? _scrub(String? message) {
    final s = session;
    return message == null || s == null
        ? message
        : s.redactor.scrubText(message);
  }

  /// Replaying a capsule that has no recording of this adapter: [call] and
  /// [subscribe] would reach Firebase, so the operation fails instead.
  bool get unserved => session?.replay != null && replayInteractions == null;

  Object unrecorded(String operation) {
    diverge(
      'native.unrecorded',
      '$adapter $operation: the capsule has no recording of this adapter',
    );
    return rebuildError(
      'bugcapsule.unrecorded',
      'no recorded $operation (the capsule has no $adapter recording)',
      null,
    );
  }

  Future<T> guardedCall<T>(
    String operation, {
    Object? args,
    required Future<T> Function() invoke,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) {
    if (unserved) return Future<T>.error(unrecorded(operation));
    return call(
      operation,
      args: args,
      invoke: invoke,
      encode: encode,
      decode: decode,
    );
  }

  Stream<T> guardedSubscribe<T>(
    String operation, {
    Object? args,
    required Stream<T> Function() open,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) {
    if (unserved) {
      return Stream<T>.multi((c) {
        c
          ..addError(unrecorded(operation))
          ..close();
      });
    }
    return subscribe(
      operation,
      args: args,
      open: open,
      encode: encode,
      decode: decode,
    );
  }
}
