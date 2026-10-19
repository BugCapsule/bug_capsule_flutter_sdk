/// On-device redaction applied before anything is recorded.
class Redactor {
  Redactor({Iterable<String> extraKeys = const [], Iterable<String> extraHeaders = const []})
      : _extraKeys = {for (final k in extraKeys) _normalize(k)},
        _headers = {..._defaultHeaders, for (final h in extraHeaders) h.toLowerCase()};

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

  final Set<String> _extraKeys;
  final Set<String> _headers;

  static String _normalize(String key) =>
      key.toLowerCase().replaceAll(RegExp(r'[_\-\s.]'), '');

  bool isSensitiveKey(String key) {
    final n = _normalize(key);
    if (_exactKeys.contains(n) || _extraKeys.contains(n)) return true;
    for (final s in _substringKeys) {
      if (n.contains(s)) return true;
    }
    return false;
  }

  bool isSensitiveHeader(String name) => _headers.contains(name.toLowerCase());

  /// Deep copy of a JSON-like value with sensitive keys replaced.
  Object? redactJson(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          '${entry.key}': isSensitiveKey('${entry.key}') && entry.value != null
              ? placeholder
              : redactJson(entry.value),
      };
    }
    if (value is List) return [for (final v in value) redactJson(v)];
    return value;
  }

  /// Lowercases names, joins multi-value headers, redacts sensitive ones.
  Map<String, String> redactHeaders(Map<String, Object?> headers) => {
        for (final entry in headers.entries)
          entry.key.toLowerCase(): isSensitiveHeader(entry.key)
              ? placeholder
              : entry.value is List
                  ? (entry.value as List).join(', ')
                  : '${entry.value}',
      };

  Uri redactUri(Uri uri) {
    if (!uri.hasQuery) return uri;
    var changed = false;
    final params = <String, List<String>>{};
    uri.queryParametersAll.forEach((key, values) {
      if (isSensitiveKey(key)) {
        changed = true;
        params[key] = [placeholder];
      } else {
        params[key] = values;
      }
    });
    return changed ? uri.replace(queryParameters: params) : uri;
  }

  /// Redacts free text bound to a named field (tracked text inputs).
  String redactText(String fieldId, String value) =>
      isSensitiveKey(fieldId) ? placeholder : value;
}
