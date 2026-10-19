/// SharedPreferences integration for Repro: snapshots allowlisted keys into
/// every checkpoint and restores them before the app starts in replay.
library;

import 'package:repro_flutter/repro_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReproSharedPreferences extends ReproIntegration {
  /// [allowPrefixes] selects keys to capture (default: all keys).
  /// [denyPrefixes] wins over the allowlist.
  ReproSharedPreferences({
    this.allowPrefixes = const [''],
    this.denyPrefixes = const ['flutter.repro.'],
  });

  final List<String> allowPrefixes;
  final List<String> denyPrefixes;

  ReproSession? _session;
  final Set<String> _redacted = {};

  @override
  String get name => 'shared_preferences';

  bool _allowed(String key) =>
      allowPrefixes.any(key.startsWith) && !denyPrefixes.any(key.startsWith);

  @override
  Future<void> setUp(ReproSession session) async => _session = session;

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
      out[key] = {'type': _typeOf(value), 'value': value};
    }
    return out;
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
  Future<void> restore(Object? data, ReproSession session) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (_allowed(key)) await prefs.remove(key);
    }
    if (data is! Map) return;
    for (final entry in data.entries) {
      final key = entry.key as String;
      final item = (entry.value as Map).cast<String, Object?>();
      final value = item['value'];
      if (value == Redactor.placeholder) {
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
