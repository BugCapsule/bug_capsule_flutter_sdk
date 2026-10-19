import 'dart:convert';

import 'event.dart';

/// Per-endpoint normalization applied before a request key is computed.
///
/// ```dart
/// EndpointRule('POST', '/payments',
///     ignoreBodyFields: {'timestamp', 'request_id', 'nonce'},
///     matchBodyFields: {'cart_id', 'amount', 'currency'})
/// ```
///
/// [path] matches the URL path exactly, with `:name` matching one segment and
/// a trailing `*` matching any remainder. [method] may be `*`.
class EndpointRule {
  EndpointRule(
    String method,
    this.path, {
    this.ignoreQuery = const {},
    this.ignoreBodyFields = const {},
    this.matchBodyFields,
  })  : method = method.toUpperCase(),
        _pattern = _compile(path);

  final String method;
  final String path;
  final Set<String> ignoreQuery;

  /// A plain name is removed at any depth; a dotted path (`meta.ts`) is
  /// removed only at that path.
  final Set<String> ignoreBodyFields;

  /// When set, only these top-level body fields take part in the key.
  final Set<String>? matchBodyFields;

  final RegExp _pattern;

  bool matches(String requestMethod, String requestPath) =>
      (method == '*' || method == requestMethod.toUpperCase()) && _pattern.hasMatch(requestPath);

  static RegExp _compile(String path) {
    final wildcard = path.endsWith('*');
    final body = wildcard ? path.substring(0, path.length - 1) : path;
    final segments = [
      for (final segment in body.split('/'))
        segment.startsWith(':') ? '[^/]+' : RegExp.escape(segment),
    ];
    return RegExp('^${segments.join('/')}${wildcard ? '.*' : r'/?$'}');
  }
}

/// Builds the stable key used to match a replayed request to a recording.
class RequestKeyBuilder {
  RequestKeyBuilder({
    this.rules = const [],
    this.globalIgnoreQuery = const {'_', 'ts', 'timestamp', 'nonce', 'cachebust'},
    this.globalIgnoreBodyFields = const {},
  });

  final List<EndpointRule> rules;
  final Set<String> globalIgnoreQuery;
  final Set<String> globalIgnoreBodyFields;

  EndpointRule? ruleFor(String method, Uri uri) {
    for (final rule in rules) {
      if (rule.matches(method, uri.path)) return rule;
    }
    return null;
  }

  /// `METHOD host/path?sortedQuery#bodyHash`. [body] should already be
  /// redacted so capture and replay compute the same key.
  String keyFor(String method, Uri uri, Object? body) {
    final m = method.toUpperCase();
    final rule = ruleFor(m, uri);
    final ignoreQuery = {...globalIgnoreQuery, ...?rule?.ignoreQuery};
    final query = <String>[];
    final params = uri.queryParametersAll;
    for (final name in params.keys.toList()..sort()) {
      if (ignoreQuery.contains(name)) continue;
      for (final v in params[name]!) {
        query.add('$name=$v');
      }
    }
    final buffer = StringBuffer('$m ${uri.host}${uri.path.isEmpty ? '/' : uri.path}');
    if (query.isNotEmpty) buffer.write('?${query.join('&')}');
    final normalizedBody = _normalizeBody(body, rule);
    if (normalizedBody != null) buffer.write('#${_hash(_canonicalJson(normalizedBody))}');
    return buffer.toString();
  }

  Object? _normalizeBody(Object? body, EndpointRule? rule) {
    if (body == null) return null;
    Object? value = body;
    if (value is String) {
      if (value.isEmpty) return null;
      try {
        value = jsonDecode(value);
      } on FormatException {
        return value;
      }
    }
    final ignore = {...globalIgnoreBodyFields, ...?rule?.ignoreBodyFields};
    final match = rule?.matchBodyFields;
    if (match != null && value is Map) {
      value = {for (final k in match) if (value.containsKey(k)) k: value[k]};
    }
    return ignore.isEmpty ? value : _strip(value, ignore, '');
  }

  Object? _strip(Object? value, Set<String> ignore, String path) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (!ignore.contains('${entry.key}') &&
              !ignore.contains(path.isEmpty ? '${entry.key}' : '$path.${entry.key}'))
            '${entry.key}': _strip(
                entry.value, ignore, path.isEmpty ? '${entry.key}' : '$path.${entry.key}'),
      };
    }
    if (value is List) return [for (final v in value) _strip(v, ignore, path)];
    return value;
  }

  static String _canonicalJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalJson(value[k])}').join(',')}}';
    }
    if (value is List) return '[${value.map(_canonicalJson).join(',')}]';
    return jsonEncode(value);
  }

  /// Two 32-bit FNV-1a passes with different offsets; 16 hex chars.
  static String _hash(String input) {
    final bytes = utf8.encode(input);
    int fnv(int offset) {
      var h = offset;
      for (final b in bytes) {
        h ^= b;
        h = (h * 0x01000193) & 0xFFFFFFFF;
      }
      return h;
    }

    String hex(int v) => v.toRadixString(16).padLeft(8, '0');
    return '${hex(fnv(0x811C9DC5))}${hex(fnv(0x050C5D1F))}';
  }
}

/// One recorded HTTP exchange, as stored in an `http` event.
class HttpFixture {
  HttpFixture(this.event);

  final ReproEvent event;

  Map<String, Object?> get data => event.data;
  String get key => data['key'] as String;
  int get occurrence => data['occurrence'] as int? ?? 0;
  int get status => data['status'] as int? ?? 0;
  int get durationMs => data['durationMs'] as int? ?? 0;
  Object? get responseBody => data['responseBody'];
  String get bodyEncoding => data['bodyEncoding'] as String? ?? 'omitted';
  Map<String, String> get responseHeaders =>
      (data['responseHeaders'] as Map?)?.cast<String, String>() ?? const {};
  Map<String, Object?>? get error => (data['error'] as Map?)?.cast<String, Object?>();
  bool get hasBody => bodyEncoding != 'omitted' && bodyEncoding != 'truncated';
}

class FixtureLookup {
  const FixtureLookup(this.fixture, {this.reused = false});
  final HttpFixture fixture;

  /// True when the request happened more often in replay than in the
  /// recording and the last recorded response was served again.
  final bool reused;
}

/// Serves recorded responses in occurrence order per request key.
class FixtureStore {
  FixtureStore(Iterable<ReproEvent> events) {
    for (final e in events) {
      if (e.type != EventTypes.http) continue;
      final f = HttpFixture(e);
      (_byKey[f.key] ??= []).add(f);
    }
    for (final list in _byKey.values) {
      list.sort((a, b) => a.occurrence.compareTo(b.occurrence));
    }
  }

  final Map<String, List<HttpFixture>> _byKey = {};
  final Map<String, int> _served = {};

  int get keyCount => _byKey.length;

  FixtureLookup? take(String key) {
    final list = _byKey[key];
    if (list == null || list.isEmpty) return null;
    final n = _served[key] ?? 0;
    _served[key] = n + 1;
    return n < list.length
        ? FixtureLookup(list[n])
        : FixtureLookup(list.last, reused: true);
  }

  /// Keys that were recorded but never requested during replay.
  List<String> unusedKeys() =>
      [for (final key in _byKey.keys) if (!_served.containsKey(key)) key];
}
