import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter_test/flutter_test.dart';

/// Connection token v1 (spec/connection-token-v1.md): the shared vectors
/// every SDK passes, plus Dart-specific edges.
void main() {
  final vectors = jsonDecode(File('../../spec/fixtures/connection-token-v1/vectors.json').readAsStringSync()) as Map;
  final valid = (vectors['valid'] as List).cast<Map<String, Object?>>();
  final invalid = (vectors['invalid'] as List).cast<Map<String, Object?>>();

  test('the vector file has cases', () {
    expect(vectors['version'], 1);
    expect(valid, isNotEmpty);
    expect(invalid, isNotEmpty);
  });

  group('valid vectors', () {
    for (final v in valid) {
      test('parses: ${v['name']}', () {
        final r = parseConnectionToken(v['token'] as String);
        expect(r, isA<ValidConnectionToken>());
        final backend = (r as ValidConnectionToken).backend;
        expect(backend.url, v['url']);
        expect(backend.ingestKey, v['ingestKey']);
      });
    }
  });

  group('invalid vectors', () {
    for (final v in invalid) {
      test('refuses: ${v['name']}', () {
        final r = parseConnectionToken(v['token'] as String);
        expect(r, isA<InvalidConnectionToken>());
        final error = r as InvalidConnectionToken;
        expect(error.error.code, v['error']);
        expect(error.message, isNotEmpty);
      });
    }
  });

  String token(Object payload, {bool pad = false}) {
    final b64 = base64Url.encode(utf8.encode(jsonEncode(payload)));
    return 'bcsdk.v1.${pad ? b64 : b64.replaceAll('=', '')}';
  }

  const key = 'bct_Q2xpZW50VmlzaWJsZUluZ2VzdE9ubHlLZXlfMDEyMzQ';

  test('padding is accepted', () {
    final payload = {'api': 'https://api.bugcapsule.com', 'key': key};
    final padded = token(payload, pad: true);
    expect(padded, endsWith('='));
    expect((parseConnectionToken(padded) as ValidConnectionToken).backend.url, 'https://api.bugcapsule.com');
  });

  test('messages say what was pasted and what to do', () {
    String message(String t) => (parseConnectionToken(t) as InvalidConnectionToken).message;
    expect(message('bci_Q2xpZW50VmlzaWJsZUluZ2VzdE9ubHlLZXlfMDEyMzQ'), contains('ingest key'));
    expect(message('bct_Q2xpZW50VmlzaWJsZUluZ2VzdE9ubHlLZXlfMDEyMzQ'), contains('ingest key'));
    expect(message('bcs_Q2xpZW50VmlzaWJsZUluZ2VzdE9ubHlLZXlfMDEyMzQ'), contains('secret key'));
    expect(message('  '), contains('empty'));
    expect(message('bcsdk.v2.e30'), contains('newer bug_capsule'));
  });

  test('api edge cases: fragment, empty query, no host and odd types are refused', () {
    for (final api in ['https://api.bugcapsule.com/#x', 'https://api.bugcapsule.com/?', 'https:///v1', 42, null]) {
      expect(parseConnectionToken(token({'api': api, 'key': key})), isA<InvalidConnectionToken>(), reason: '$api');
    }
    expect(parseConnectionToken(token({'api': 'https://api.bugcapsule.com', 'key': 'bct_short'})),
        isA<InvalidConnectionToken>());
  });

  test('payload bytes that are not UTF-8 are refused', () {
    final b64 = base64Url.encode([0xff, 0xfe, 0x7b]).replaceAll('=', '');
    expect(parseConnectionToken('bcsdk.v1.$b64'), isA<InvalidConnectionToken>());
  });
}
