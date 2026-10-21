import 'dart:convert';

/// On-device redaction applied before anything is recorded.
///
/// Three layers, all best effort (the capsule spec's "Redaction" section
/// lists what they do not catch):
/// * **by name**: JSON keys, header names, query/fragment parameter names
///   and tracked-text ids that look sensitive;
/// * **by shape**: [scrubText] finds credentials inside free text (bearer
///   tokens, JWTs, `key=value` / `key: value` / `"key": "value"` pairs with a
///   sensitive key, well-known API key prefixes, card numbers);
/// * **by app rules**: [extraKeys] and [patterns] from the app's config.
class Redactor {
  Redactor({
    Iterable<String> extraKeys = const [],
    Iterable<String> extraHeaders = const [],
    Iterable<RegExp> patterns = const [],
  })  : extraKeys = List.unmodifiable(extraKeys),
        extraHeaders = List.unmodifiable(extraHeaders),
        _extraKeys = {for (final k in extraKeys) _normalize(k)},
        _headers = {..._defaultHeaders, for (final h in extraHeaders) h.toLowerCase()},
        _patterns = List.unmodifiable(patterns);

  static const placeholder = '[REDACTED]';

  static const _defaultHeaders = {
    'authorization',
    'cookie',
    'set-cookie',
    'proxy-authorization',
    'x-api-key',
    'x-auth-token',
  };

  /// Matched exactly: short names that would cause false positives as
  /// substrings (`pin` in `shipping`).
  static const _exactKeys = {
    'pin', 'pan', 'otp', 'ssn', 'cvv', 'cvc', 'passcode', 'iban',
  };

  /// Matched as substrings: `fcmToken`, `user_password`, `clientSecret`.
  static const _substringKeys = {
    'password', 'passwd', 'token', 'secret', 'apikey', 'authorization',
    'cookie', 'cardnumber', 'creditcard', 'privatekey', 'sessionid',
  };

  /// Only sensitive as URL query/fragment parameters (OAuth codes, presigned
  /// URL signatures); as JSON keys these names are too common to redact.
  static const _exactQueryKeys = {'code', 'sig', 'key', 'auth', 'sid', 'session'};
  static const _substringQueryKeys = {'signature', 'credential'};

  /// Keys the app added (config and remote config), as given.
  final List<String> extraKeys;

  /// Headers the app added, as given.
  final List<String> extraHeaders;

  final Set<String> _extraKeys;
  final Set<String> _headers;
  final List<RegExp> _patterns;

  static final _normalizeChars = RegExp(r'[_\-\s.]');
  static String _normalize(String key) => key.toLowerCase().replaceAll(_normalizeChars, '');

  /// A redactor with this one's rules plus [keys], [headers] and [patterns].
  Redactor extend({
    Iterable<String> keys = const [],
    Iterable<String> headers = const [],
    Iterable<RegExp> patterns = const [],
  }) =>
      Redactor(
        extraKeys: {...extraKeys, ...keys},
        extraHeaders: {...extraHeaders, ...headers},
        patterns: [..._patterns, ...patterns],
      );

  bool isSensitiveKey(String key) {
    final n = _normalize(key);
    if (_exactKeys.contains(n) || _extraKeys.contains(n)) return true;
    for (final s in _substringKeys) {
      if (n.contains(s)) return true;
    }
    return false;
  }

  /// Like [isSensitiveKey], plus names that are only secret inside URLs.
  bool isSensitiveQueryKey(String key) {
    if (isSensitiveKey(key)) return true;
    final n = _normalize(key);
    if (_exactQueryKeys.contains(n)) return true;
    for (final s in _substringQueryKeys) {
      if (n.contains(s)) return true;
    }
    return false;
  }

  bool isSensitiveHeader(String name) =>
      _headers.contains(name.toLowerCase()) || isSensitiveKey(name);

  // ------------------------------------------------------------------ JSON

  /// Deep copy of a JSON-like value: values under sensitive keys are
  /// replaced, strings are [scrubText]-ed, and strings holding a JSON object
  /// or array are redacted recursively (re-encoded only if that changed
  /// them). Nesting beyond [_maxDepth] is replaced, not walked.
  Object? redactJson(Object? value) => _redact(value, 0).$1;

  static const _maxDepth = 64;
  static const _maxEmbeddedJson = 64 * 1024;

  (Object?, bool) _redact(Object? value, int depth) {
    if (depth > _maxDepth) return (placeholder, true);
    if (value is String) return _redactString(value, depth);
    if (value is Map) {
      var changed = false;
      final out = <String, Object?>{};
      for (final entry in value.entries) {
        final key = '${entry.key}';
        if (entry.value != null && isSensitiveKey(key)) {
          out[key] = placeholder;
          changed = true;
        } else {
          final (v, c) = _redact(entry.value, depth + 1);
          out[key] = v;
          changed |= c;
        }
      }
      return (out, changed);
    }
    if (value is List) {
      var changed = false;
      final out = <Object?>[];
      for (final item in value) {
        final (v, c) = _redact(item, depth + 1);
        out.add(v);
        changed |= c;
      }
      return (out, changed);
    }
    return (value, false);
  }

  (Object?, bool) _redactString(String value, int depth) {
    final trimmed = value.trimLeft();
    if (trimmed.length >= 2 &&
        value.length <= _maxEmbeddedJson &&
        (trimmed.startsWith('{') || trimmed.startsWith('['))) {
      Object? decoded;
      try {
        decoded = jsonDecode(value);
      } on FormatException {
        decoded = null;
      }
      if (decoded is Map || decoded is List) {
        final (redacted, changed) = _redact(decoded, depth + 1);
        return changed ? (jsonEncode(redacted), true) : (value, false);
      }
    }
    final scrubbed = scrubText(value);
    return (scrubbed, !identical(scrubbed, value));
  }

  // ------------------------------------------------------------ free text

  static final _authScheme =
      RegExp(r'\b(Bearer|Basic|Token|Digest)\s+[A-Za-z0-9\-._~+/]{6,}=*', caseSensitive: false);
  static final _jwt = RegExp(r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*');
  static final _knownKeys = RegExp(
    r'\b(?:(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{8,}'
    r'|AKIA[0-9A-Z]{16}'
    r'|gh[pousr]_[A-Za-z0-9]{20,}'
    r'|xox[abprs]-[A-Za-z0-9-]{10,}'
    r'|AIza[0-9A-Za-z_-]{30,}'
    r'|rp[is]_[A-Za-z0-9_-]{20,})',
  );
  static final _quotedPair =
      RegExp(r'''(["'])([^"'\\]{1,100})\1(\s*[:=]\s*)(["'])((?:[^"'\\]|\\.)*)\4''');
  // The lookbehinds anchor each match at the start of a key, so a long run of
  // key characters is scanned once instead of once per position (linear on
  // 256 KB bodies rather than seconds on the UI isolate).
  static final _equalsPair =
      RegExp(r'''(?<![A-Za-z0-9_\-.\[\]])([A-Za-z0-9_\-.\[\]]{1,100})=([^&\s"'#;,)<>]+)''');
  static final _colonPair =
      RegExp(r'''(?<![A-Za-z0-9_\-.])([A-Za-z0-9_\-.]{2,100})(\s*:\s*)([^,\s}{\]\[]+)''');

  /// Card-number shaped: 13-19 digits (optionally grouped) starting with a
  /// card network prefix; confirmed with a Luhn check.
  static final _digits = RegExp(r'\b[2-6]\d(?:[ -]?\d){11,17}\b');

  /// Removes credentials from free text. Returns [text] itself (the same
  /// instance) when nothing matched.
  String scrubText(String text) {
    if (text.length < 5) return text;
    var out = text;
    out = out.replaceAllMapped(_authScheme, (m) => '${m[1]} $placeholder');
    out = out.replaceAll(_jwt, placeholder);
    out = out.replaceAll(_knownKeys, placeholder);
    out = out.replaceAllMapped(_quotedPair, (m) {
      if (!isSensitiveQueryKey(m[2]!) || m[5] == placeholder) return m[0]!;
      return '${m[1]}${m[2]}${m[1]}${m[3]}${m[4]}$placeholder${m[4]}';
    });
    out = out.replaceAllMapped(_equalsPair, (m) {
      if (!isSensitiveQueryKey(m[1]!) || m[2] == placeholder) return m[0]!;
      return '${m[1]}=$placeholder';
    });
    out = out.replaceAllMapped(_colonPair, (m) {
      final value = m[3]!;
      // `https://...` is a URL scheme, not a key.
      if (value.startsWith('//') || !isSensitiveKey(m[1]!) || value.contains(placeholder)) {
        return m[0]!;
      }
      return '${m[1]}${m[2]}$placeholder';
    });
    out = out.replaceAllMapped(_digits, (m) => _luhn(m[0]!) ? placeholder : m[0]!);
    for (final p in _patterns) {
      out = out.replaceAll(p, placeholder);
    }
    return out == text ? text : out;
  }

  static bool _luhn(String candidate) {
    final digits = candidate.replaceAll(RegExp(r'[ -]'), '');
    if (digits.length < 13 || digits.length > 19) return false;
    var sum = 0;
    var alt = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      var d = digits.codeUnitAt(i) - 48;
      if (alt) {
        d *= 2;
        if (d > 9) d -= 9;
      }
      sum += d;
      alt = !alt;
    }
    return sum % 10 == 0;
  }

  // ------------------------------------------------------ headers and URLs

  /// Lowercases names, joins multi-value headers, redacts sensitive ones and
  /// scrubs the values of the rest (e.g. a `location` URL with a token).
  Map<String, String> redactHeaders(Map<String, Object?> headers) => {
        for (final entry in headers.entries)
          entry.key.toLowerCase(): isSensitiveHeader(entry.key)
              ? placeholder
              : scrubText(entry.value is List
                  ? (entry.value as List).join(', ')
                  : '${entry.value}'),
      };

  /// Redacts user info (`user:pass@`), sensitive query parameters and
  /// sensitive `key=value` pairs in the fragment (OAuth implicit flow).
  /// The path is kept: secrets in path segments need an app rule.
  Uri redactUri(Uri uri) {
    try {
      return _redactUri(uri);
    } on Object {
      // Malformed escapes (`%FF`, `%zz`) make the query unreadable: drop
      // query and fragment rather than throw into the app's request.
      return Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
      );
    }
  }

  Uri _redactUri(Uri uri) {
    var result = uri;
    // Brackets are not allowed in user info.
    if (uri.userInfo.isNotEmpty) result = result.replace(userInfo: 'REDACTED');
    if (uri.hasQuery) {
      var changed = false;
      final params = <String, List<String>>{};
      uri.queryParametersAll.forEach((key, values) {
        if (isSensitiveQueryKey(key)) {
          changed = true;
          params[key] = [placeholder];
        } else {
          final scrubbed = [for (final v in values) scrubText(v)];
          for (var i = 0; i < values.length; i++) {
            if (!identical(scrubbed[i], values[i])) changed = true;
          }
          params[key] = scrubbed;
        }
      });
      if (changed) result = result.replace(queryParameters: params);
    }
    if (uri.hasFragment && uri.fragment.contains('=')) {
      final scrubbed = uri.fragment.replaceAllMapped(_equalsPair, (m) {
        return isSensitiveQueryKey(m[1]!) ? '${m[1]}=$placeholder' : m[0]!;
      });
      if (scrubbed != uri.fragment) result = result.replace(fragment: scrubbed);
    }
    return result;
  }

  /// [redactUri] for a string; falls back to [scrubText] when it does not
  /// parse as a URI.
  String redactUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return scrubText(url);
    final redacted = redactUri(uri);
    return identical(redacted, uri) ? url : redacted.toString();
  }

  /// Redacts free text bound to a named field (tracked text inputs): the
  /// whole value when the id looks sensitive or [sensitive] is set,
  /// otherwise credentials found inside it.
  String redactText(String fieldId, String value, {bool sensitive = false}) =>
      sensitive || isSensitiveKey(fieldId) ? placeholder : scrubText(value);
}
