/// Structural validation of a decoded capsule document (spec v1).
///
/// The backend (`src/capsule.ts`) applies the same rules, so whatever the
/// backend accepts this SDK can decode, and the shared fixtures in
/// `spec/fixtures/` hold both to it. Unknown fields and unknown event types
/// are allowed (forward compatibility); known fields must have the right
/// types, and resource bounds keep hostile documents from exhausting a
/// reader.
abstract final class CapsuleLimits {
  static const maxEvents = 200000;
  static const maxDepth = 100;
  static const maxLabels = 100;
  static const maxIntegrations = 100;
  static const maxMissing = 500;
  static const maxRedactionKeys = 500;
  static const maxCapabilities = 200;
  static const maxFrameworks = 20;

  /// JSON values in the whole document, counted before parsing.
  static const maxJsonValues = 4000000;
}

/// Returns null when [doc] is a valid v1 document, otherwise
/// `<json path> <reason>`. Does not check `specVersion` against the reader's
/// version (the codec does that, with its own message).
String? validateCapsuleDocument(Object? doc) {
  try {
    _validate(doc);
    return null;
  } on _Invalid catch (e) {
    return e.message;
  }
}

class _Invalid implements Exception {
  _Invalid(this.message);
  final String message;
}

Never _fail(String path, String reason) => throw _Invalid('$path $reason');

final _isoDateTime = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:?\d{2})$',
  caseSensitive: false,
);

const _maxSafeInt = 9007199254740991;

Map<String, Object?> _object(Object? v, String path) {
  if (v is! Map) _fail(path, 'must be an object');
  return v.cast<String, Object?>();
}

Map<String, Object?>? _optObject(Map<String, Object?> o, String key, String path) {
  final v = o[key];
  if (v == null) return null;
  return _object(v, '$path.$key');
}

List<Object?> _array(Object? v, String path, int max) {
  if (v is! List) _fail(path, 'must be an array');
  if (v.length > max) _fail(path, 'must have at most $max items');
  return v;
}

String _string(Map<String, Object?> o, String key, String path, {int max = 1000, int min = 1}) {
  final v = o[key];
  if (v is! String) _fail('$path.$key', 'must be a string');
  if (v.length < min) _fail('$path.$key', 'must not be empty');
  if (v.length > max) _fail('$path.$key', 'must be at most $max characters');
  return v;
}

String? _optString(Map<String, Object?> o, String key, String path, {int max = 1000}) {
  final v = o[key];
  if (v == null) return null;
  if (v is! String) _fail('$path.$key', 'must be a string or null');
  if (v.length > max) _fail('$path.$key', 'must be at most $max characters');
  return v;
}

int _int(Map<String, Object?> o, String key, String path, {int? min}) {
  final v = o[key];
  if (v is! int || v.abs() > _maxSafeInt) _fail('$path.$key', 'must be an integer');
  if (min != null && v < min) _fail('$path.$key', 'must be >= $min');
  return v;
}

int? _optInt(Map<String, Object?> o, String key, String path, {int? min}) {
  if (o[key] == null) return null;
  return _int(o, key, path, min: min);
}

void _optNum(Map<String, Object?> o, String key, String path) {
  final v = o[key];
  if (v != null && (v is! num || !v.isFinite)) _fail('$path.$key', 'must be a number or null');
}

void _optBool(Map<String, Object?> o, String key, String path) {
  final v = o[key];
  if (v != null && v is! bool) _fail('$path.$key', 'must be a boolean or null');
}

void _enum(Map<String, Object?> o, String key, String path, List<String> values) {
  final v = o[key];
  if (v is! String || !values.contains(v)) {
    _fail('$path.$key', 'must be one of ${values.join(', ')}');
  }
}

void _isoDate(Map<String, Object?> o, String key, String path) {
  final v = o[key];
  if (v is! String || !_isoDateTime.hasMatch(v) || DateTime.tryParse(v) == null) {
    _fail('$path.$key', 'must be an ISO-8601 date-time with a time zone');
  }
}

void _stringMap(Map<String, Object?> m, String path, {int maxEntries = 1000, int max = 10000}) {
  if (m.length > maxEntries) _fail(path, 'must have at most $maxEntries entries');
  for (final e in m.entries) {
    final v = e.value;
    if (v is! String) _fail('$path.${e.key}', 'must be a string');
    if (v.length > max) _fail('$path.${e.key}', 'must be at most $max characters');
  }
}

void _depth(Object? root) {
  final stack = <(Object?, int)>[(root, 0)];
  while (stack.isNotEmpty) {
    final (value, depth) = stack.removeLast();
    if (depth > CapsuleLimits.maxDepth) {
      _fail(r'$', 'nests deeper than ${CapsuleLimits.maxDepth} levels');
    }
    if (value is Map) {
      for (final v in value.values) {
        if (v is Map || v is List) stack.add((v, depth + 1));
      }
    } else if (value is List) {
      for (final v in value) {
        if (v is Map || v is List) stack.add((v, depth + 1));
      }
    }
  }
}

void _validate(Object? root) {
  final doc = _object(root, r'$');
  _depth(doc);
  if (doc['format'] != 'bugcapsule.capsule') _fail(r'$.format', 'must be "bugcapsule.capsule"');
  _int(doc, 'specVersion', r'$', min: 1);

  final m = _object(doc['manifest'], r'$.manifest');
  const mp = r'$.manifest';
  _string(m, 'capsuleId', mp, max: 100);
  _isoDate(m, 'createdAt', mp);
  _enum(m, 'mode', mp, const ['debug', 'qa', 'production']);

  final app = _object(m['app'], '$mp.app');
  _string(app, 'version', '$mp.app', max: 200);
  _string(app, 'build', '$mp.app', max: 200);
  for (final k in const ['id', 'name', 'flavor']) {
    _optString(app, k, '$mp.app', max: 200);
  }

  final source = _optObject(m, 'source', mp);
  if (source != null) {
    _optString(source, 'gitSha', '$mp.source', max: 200);
    _optBool(source, 'dirty', '$mp.source');
  }
  final sdk = _optObject(m, 'sdk', mp);
  if (sdk != null) {
    _optString(sdk, 'name', '$mp.sdk', max: 100);
    _optString(sdk, 'version', '$mp.sdk', max: 100);
  }
  _optInt(m, 'stateSchemaVersion', mp);

  final platform = _object(m['platform'], '$mp.platform');
  _string(platform, 'os', '$mp.platform', max: 100);
  _optString(platform, 'osVersion', '$mp.platform', max: 200);
  _optString(platform, 'locale', '$mp.platform', max: 100);
  _optString(platform, 'dartVersion', '$mp.platform', max: 200);
  final screen = _optObject(platform, 'screen', '$mp.platform');
  if (screen != null) {
    for (final k in const ['width', 'height', 'pixelRatio']) {
      _optNum(screen, k, '$mp.platform.screen');
    }
  }

  final session = _object(m['session'], '$mp.session');
  _string(session, 'id', '$mp.session', max: 200);
  _isoDate(session, 'startedAt', '$mp.session');
  _int(session, 'wallClockAtAnchorMs', '$mp.session');
  _int(session, 'seed', '$mp.session');
  _int(session, 'durationMs', '$mp.session');

  final failure = _optObject(m, 'failure', mp);
  if (failure != null) _validateFailure(failure, '$mp.failure');

  final eligibility = _object(m['eligibility'], '$mp.eligibility');
  _enum(eligibility, 'status', '$mp.eligibility', const ['eligible', 'partial', 'ineligible']);
  if (eligibility['missing'] != null) {
    final missing = _array(
      eligibility['missing'],
      '$mp.eligibility.missing',
      CapsuleLimits.maxMissing,
    );
    for (var i = 0; i < missing.length; i++) {
      final path = '$mp.eligibility.missing[$i]';
      final item = _object(missing[i], path);
      _string(item, 'dependency', path, max: 200);
      _string(item, 'reason', path, max: 2000, min: 0);
      _optBool(item, 'blocking', path);
    }
  }

  if (m['integrations'] != null) {
    final integrations = _array(
      m['integrations'],
      '$mp.integrations',
      CapsuleLimits.maxIntegrations,
    );
    for (var i = 0; i < integrations.length; i++) {
      final v = integrations[i];
      if (v is! String || v.isEmpty || v.length > 100) {
        _fail('$mp.integrations[$i]', 'must be a non-empty string of at most 100 characters');
      }
    }
  }

  final stats = _optObject(m, 'stats', mp);
  if (stats != null) {
    _optInt(stats, 'eventCount', '$mp.stats', min: 0);
    _optInt(stats, 'droppedEvents', '$mp.stats', min: 0);
    if (stats['checkpointKind'] != null) {
      _enum(stats, 'checkpointKind', '$mp.stats', const ['launch', 'periodic']);
    }
  }

  final labels = _optObject(m, 'labels', mp);
  if (labels != null) {
    _stringMap(labels, '$mp.labels', maxEntries: CapsuleLimits.maxLabels, max: 2000);
    for (final k in labels.keys) {
      if (k.length > 100) _fail('$mp.labels', 'keys must be at most 100 characters');
    }
  }

  final redaction = _optObject(m, 'redaction', mp);
  if (redaction != null) {
    for (final k in const ['extraKeys', 'extraHeaders']) {
      if (redaction[k] == null) continue;
      final list = _array(redaction[k], '$mp.redaction.$k', CapsuleLimits.maxRedactionKeys);
      for (var i = 0; i < list.length; i++) {
        final v = list[i];
        if (v is! String || v.length > 200) _fail('$mp.redaction.$k[$i]', 'must be a string');
      }
    }
  }

  // v1 extension (SDK 0.3): the capturing runtime and its capabilities.
  final runtime = _optObject(m, 'runtime', mp);
  if (runtime != null) {
    _string(runtime, 'name', '$mp.runtime', max: 50);
    _optString(runtime, 'version', '$mp.runtime', max: 200);
    _optString(runtime, 'language', '$mp.runtime', max: 50);
    if (runtime['frameworks'] != null) {
      final list = _array(runtime['frameworks'], '$mp.runtime.frameworks', CapsuleLimits.maxFrameworks);
      for (var i = 0; i < list.length; i++) {
        final v = list[i];
        if (v is! String || v.isEmpty || v.length > 50) {
          _fail('$mp.runtime.frameworks[$i]', 'must be a non-empty string of at most 50 characters');
        }
      }
    }
  }
  final capabilities = _optObject(m, 'capabilities', mp);
  if (capabilities != null) {
    _stringMap(capabilities, '$mp.capabilities', maxEntries: CapsuleLimits.maxCapabilities, max: 100);
    for (final k in capabilities.keys) {
      if (k.length > 100) _fail('$mp.capabilities', 'keys must be at most 100 characters');
    }
  }
  // v1 extension (monitoring-v1 §4.3): the linked monitoring event.
  final monitoring = _optObject(m, 'monitoring', mp);
  if (monitoring != null) {
    _string(monitoring, 'eventId', '$mp.monitoring', max: 100);
    _optString(monitoring, 'traceId', '$mp.monitoring', max: 32);
    _optString(monitoring, 'release', '$mp.monitoring', max: 200);
    _optString(monitoring, 'environment', '$mp.monitoring', max: 64);
  }

  const cp = r'$.checkpoint';
  final checkpoint = _object(doc['checkpoint'], cp);
  _enum(checkpoint, 'kind', cp, const ['launch', 'periodic']);
  _int(checkpoint, 't', cp);
  _int(checkpoint, 'wallClockMs', cp);
  _optInt(checkpoint, 'afterSeq', cp, min: 0);
  _optObject(checkpoint, 'data', cp);

  final events = _array(doc['events'], r'$.events', CapsuleLimits.maxEvents);
  int? lastSeq;
  for (var i = 0; i < events.length; i++) {
    final path = '\$.events[$i]';
    final e = _object(events[i], path);
    final seq = _int(e, 'seq', path);
    if (lastSeq != null && seq <= lastSeq) {
      _fail('$path.seq', 'must be greater than the previous seq');
    }
    lastSeq = seq;
    _int(e, 't', path);
    final type = _string(e, 'type', path, max: 100);
    final data = _optObject(e, 'data', path) ?? const <String, Object?>{};
    _validateEventData(type, data, '$path.data');
  }
}

void _validateFailure(Map<String, Object?> f, String path) {
  _enum(f, 'kind', path, const ['exception', 'assertion', 'manual']);
  _string(f, 'signature', path, max: 1000);
  _string(f, 'type', path, max: 1000, min: 0);
  _optString(f, 'message', path, max: 10000);
  _optString(f, 'stack', path, max: 20000);
  _optString(f, 'assertionId', path, max: 200);
  _optInt(f, 't', path);
}

/// Fields the replay engine and fixture store read from known event types.
void _validateEventData(String type, Map<String, Object?> d, String path) {
  switch (type) {
    case 'http':
      _string(d, 'key', path, max: 10000);
      _optInt(d, 'occurrence', path, min: 0);
      _optInt(d, 'status', path);
      _optInt(d, 'durationMs', path, min: 0);
      _optString(d, 'bodyEncoding', path, max: 20);
      _optString(d, 'statusMessage', path, max: 1000);
      final headers = _optObject(d, 'responseHeaders', path);
      if (headers != null) _stringMap(headers, '$path.responseHeaders');
      _optObject(d, 'error', path);
    case 'pointer':
      _string(d, 'phase', path, max: 20);
      _int(d, 'pointer', path);
      for (final k in const ['x', 'y']) {
        final v = d[k];
        if (v is! num || !v.isFinite) _fail('$path.$k', 'must be a number');
      }
      _optInt(d, 'buttons', path);
    case 'action':
      _string(d, 'id', path, max: 200);
      _optObject(d, 'payload', path);
    case 'text':
      _string(d, 'id', path, max: 200);
      _optString(d, 'value', path, max: 100000);
    case 'lifecycle':
      _string(d, 'state', path, max: 20);
  }
}
