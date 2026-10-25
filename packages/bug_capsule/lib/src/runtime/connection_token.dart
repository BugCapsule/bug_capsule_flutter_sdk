import 'dart:convert';

import 'config.dart';

/// Why a connection token can't be used (spec/connection-token-v1.md).
enum ConnectionTokenError {
  /// Empty, wrong prefix, a key pasted instead of a token, a damaged
  /// payload, or a missing/invalid `api` or `key`.
  invalidToken('invalid_token'),

  /// `bcsdk.v<N>.` with a version this SDK does not understand.
  unsupportedTokenVersion('unsupported_token_version');

  const ConnectionTokenError(this.code);

  /// The contract's error code, e.g. `invalid_token`.
  final String code;
}

/// Result of [parseConnectionToken].
sealed class ParsedConnectionToken {
  const ParsedConnectionToken();
}

/// A usable token: [backend] is what `BugCapsuleConfig.backend` would be.
final class ValidConnectionToken extends ParsedConnectionToken {
  const ValidConnectionToken(this.backend);
  final BugCapsuleBackendConfig backend;
}

/// An unusable token, with an actionable [message].
final class InvalidConnectionToken extends ParsedConnectionToken {
  const InvalidConnectionToken(this.error, this.message);
  final ConnectionTokenError error;
  final String message;
}

const _supportedVersion = 1;
final _key = RegExp(r'^(bct|bci)_[A-Za-z0-9_-]{16,200}$');
final _token = RegExp(r'^bcsdk\.v(\d+)\.(.*)$', dotAll: true);
final _base64Url = RegExp(r'^[A-Za-z0-9_-]+={0,2}$');

/// Parses an SDK connection token (`bcsdk.v1.<base64url JSON {api, key}>`)
/// offline. Never throws.
///
/// The token is copied from the BugCapsule dashboard. It is client-visible
/// and grants exactly what an ingest key grants: fetching the project's SDK
/// config and uploading Capsules and monitoring envelopes.
ParsedConnectionToken parseConnectionToken(String raw) {
  InvalidConnectionToken bad(String message) => InvalidConnectionToken(ConnectionTokenError.invalidToken, message);
  final token = raw.trim();
  if (token.isEmpty) {
    return bad('the token is empty; copy it from the BugCapsule dashboard (Project settings → Keys → SDK tokens)');
  }
  if (token.startsWith('bci_') || token.startsWith('bct_')) {
    return bad('this is an ingest key, not a connection token: pass it as '
        'backend: BugCapsuleBackendConfig(url: ..., ingestKey: ...), or generate an SDK token in the dashboard');
  }
  if (token.startsWith('bcs_')) {
    return bad('this is a secret key: never ship it in an app. Rotate it and generate an SDK token in the dashboard');
  }
  final m = _token.firstMatch(token);
  if (m == null) return bad('a connection token starts with "bcsdk.v1."; copy the whole token from the dashboard');
  if (int.tryParse(m[1]!) != _supportedVersion) {
    return InvalidConnectionToken(ConnectionTokenError.unsupportedTokenVersion,
        'token version ${m[1]} needs a newer bug_capsule package (this one understands v$_supportedVersion)');
  }
  final json = _decodeBase64Url(m[2]!);
  if (json == null) return bad('the token is damaged or incomplete; copy it again from the dashboard');
  Object? payload;
  try {
    payload = jsonDecode(json);
  } on FormatException {
    return bad('the token is damaged or incomplete; copy it again from the dashboard');
  }
  if (payload is! Map) return bad('the token is damaged; copy it again from the dashboard');
  final key = payload['key'];
  if (key is! String || !_key.hasMatch(key)) {
    return bad('the token has no valid ingest credential; generate a new token');
  }
  final url = _apiUrl(payload['api']);
  if (url == null) return bad('the token has no valid API URL; generate a new token');
  return ValidConnectionToken(BugCapsuleBackendConfig(url: url, ingestKey: key));
}

/// base64url (padding optional) of UTF-8 text, or null.
String? _decodeBase64Url(String s) {
  if (!_base64Url.hasMatch(s)) return null;
  final unpadded = s.replaceAll('=', '');
  if (unpadded.length % 4 == 1) return null;
  try {
    final padded = unpadded.padRight(unpadded.length + (4 - unpadded.length % 4) % 4, '=');
    return utf8.decode(base64Url.decode(padded));
  } on FormatException {
    return null;
  }
}

/// An absolute http(s) URL without user info, query or fragment, with
/// trailing slashes removed; else null.
String? _apiUrl(Object? api) {
  if (api is! String || api.isEmpty || api.length > 2000) return null;
  final uri = Uri.tryParse(api);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (!uri.hasAuthority || uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
  return api.replaceAll(RegExp(r'/+$'), '');
}
