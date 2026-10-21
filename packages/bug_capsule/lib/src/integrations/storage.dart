/// SharedPreferences integration for BugCapsule: snapshots allowlisted keys into
/// every checkpoint and restores them before the app starts in replay.
library;

import '../runtime/runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BugCapsuleSharedPreferences extends BugCapsuleIntegration {
  /// [allowPrefixes] selects keys to capture (default: all keys).
  /// [denyPrefixes] wins over the allowlist.
  BugCapsuleSharedPreferences({
    this.allowPrefixes = const [''],
    this.denyPrefixes = const ['flutter.bugcapsule.'],
  });

  final List<String> allowPrefixes;
  final List<String> denyPrefixes;

  BugCapsuleSession? _session;
  final Set<String> _redacted = {};

  @override
  String get name => 'shared_preferences';

  bool _allowed(String key) =>
      allowPrefixes.any(key.startsWith) && !denyPrefixes.any(key.startsWith);

  @override
  Future<void> setUp(BugCapsuleSession session) async => _session = session;

  @override
  Future<Object?> snapshot(CheckpointKind kind) async {
    final session = _session;
    if (session == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final out = <String, Object?>{};
    for (final key in prefs.getKeys()) {
      if (!_allowed(key)) continue;
      final value = prefs.get(key);
      if (session.redactor.isSensitiveKey(key)) {
        _redacted.add(key);
        out[key] = {'type': _typeOf(value), 'value': Redactor.placeholder};
        continue;
      }
      // Values are redacted too: a JSON string under an innocent key
      // (`auth_state`) can hold a token.
      final redacted = switch (value) {
        String() => session.redactor.redactJson(value),
        List() => [for (final v in value) session.redactor.redactJson('$v')],
        _ => value,
      };
      if (redacted is String && redacted != value ||
          redacted is List && value is List && !_sameList(redacted, value)) {
        _redacted.add(key);
      }
      out[key] = {'type': _typeOf(value), 'value': redacted};
    }
    return out;
  }

  static bool _sameList(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ('${a[i]}' != '${b[i]}') return false;
    }
    return true;
  }

  static String _typeOf(Object? value) => switch (value) {
        bool() => 'bool',
        int() => 'int',
        double() => 'double',
        String() => 'string',
        List() => 'stringList',
        _ => 'unknown',
      };

  @override
  Future<void> restore(Object? data, BugCapsuleSession session) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (_allowed(key)) await prefs.remove(key);
    }
    if (data is! Map) return;
    for (final entry in data.entries) {
      final key = entry.key as String;
      if (entry.value is! Map) {
        // The whole entry was redacted (sensitive key): nothing to restore.
        session.replay?.diverge('storage.redacted', key);
        continue;
      }
      final item = (entry.value as Map).cast<String, Object?>();
      final value = item['value'];
      if (value == Redactor.placeholder ||
          (value is String && value.contains(Redactor.placeholder))) {
        session.replay?.diverge('storage.redacted', key);
      }
      switch (item['type']) {
        case 'bool':
          await prefs.setBool(key, value as bool);
        case 'int':
          await prefs.setInt(key, value as int);
        case 'double':
          await prefs.setDouble(key, (value as num).toDouble());
        case 'string':
          await prefs.setString(key, value as String);
        case 'stringList':
          await prefs.setStringList(key, [for (final v in value as List) '$v']);
        default:
          session.replay?.diverge('storage.unknownType', key);
      }
    }
  }

  @override
  void describeEligibility(EligibilityBuilder eligibility, RecordedWindow window) {
    for (final key in _redacted) {
      eligibility.missing('storage.$key', 'value redacted on device; replay restores a placeholder');
    }
  }
}
