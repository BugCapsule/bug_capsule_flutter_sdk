import 'dart:convert';

import 'package:bug_capsule/src/core/core.dart';
import 'package:test/test.dart';

// Synthetic secrets only. Each must disappear from redacted output.
const jwt =
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzeW50aGV0aWMifQ.c3ludGhldGljLXNpZw';
const bearer = 'synthBearerValue0123456789';
const queryToken = 'synthQueryToken42';
const card = '4242 4242 4242 4242';

void main() {
  final r = Redactor(
    extraKeys: ['loyaltyId'],
    patterns: [RegExp(r'EMP-\d{6}')],
  );

  group('scrubText', () {
    test('removes bearer tokens, JWTs and known key prefixes', () {
      final out = r.scrubText(
        'Authorization: Bearer $bearer; id=$jwt; key sk_live_abcdEFGH1234 bci_${'a' * 43}',
      );
      expect(out, isNot(contains(bearer)));
      expect(out, isNot(contains(jwt)));
      expect(out, isNot(contains('sk_live_abcdEFGH1234')));
      expect(out, isNot(contains('bci_aaaa')));
    });

    test('removes sensitive key=value, key: value and "key": "value" pairs', () {
      final out = r.scrubText(
        'GET https://api.test/a?access_token=$queryToken&page=2 failed {password: hunter2, user: bob} '
        '{"refresh_token": "synthRefresh", "name": "ok"} otp=123456',
      );
      expect(out, isNot(contains(queryToken)));
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('synthRefresh')));
      expect(out, isNot(contains('123456')));
      expect(out, contains('page=2'));
      expect(out, contains('user: bob'));
      expect(out, contains('"name": "ok"'));
    });

    test('removes Luhn-valid card numbers but keeps other numbers', () {
      final out = r.scrubText('card $card order 1234567890123 total 42');
      expect(out, isNot(contains(card)));
      expect(out, contains('1234567890123'));
      expect(out, contains('42'));
    });

    test('applies app patterns', () {
      expect(
        r.scrubText('employee EMP-123456 logged in'),
        'employee [REDACTED] logged in',
      );
    });

    test('leaves ordinary messages untouched (same instance)', () {
      const msg = 'Bad state: Cart total is negative (-3)';
      expect(identical(r.scrubText(msg), msg), isTrue);
      expect(
        r.scrubText('https://shop.test/cart?page=2'),
        'https://shop.test/cart?page=2',
      );
    });
  });

  group('redactJson', () {
    test('redacts by key at any depth and scrubs string values', () {
      final out =
          r.redactJson({
                'user': {
                  'password': 'x',
                  'fcmToken': 'y',
                  'shipping': 'z',
                  'pin': '1234',
                },
                'list': [
                  {'loyalty_id': 'L1', 'name': 'a'},
                ],
                'next': 'https://api.test/page?token=$queryToken',
                'header': 'Bearer $bearer',
              })
              as Map;
      final user = out['user'] as Map;
      expect(user['password'], Redactor.placeholder);
      expect(user['shipping'], 'z');
      expect(
        ((out['list'] as List).first as Map)['loyalty_id'],
        Redactor.placeholder,
      );
      expect(jsonEncode(out), isNot(contains(queryToken)));
      expect(jsonEncode(out), isNot(contains(bearer)));
    });

    test(
      'redacts JSON embedded in strings and keeps unchanged strings byte-identical',
      () {
        final embedded = jsonEncode({
          'accessToken': 'synthEmbedded',
          'theme': 'dark',
        });
        const untouched = '{ "theme":  "dark" }';
        final out =
            r.redactJson({'auth_state': embedded, 'prefs': untouched}) as Map;
        expect(out['auth_state'], isNot(contains('synthEmbedded')));
        expect(jsonDecode(out['auth_state'] as String), {
          'accessToken': Redactor.placeholder,
          'theme': 'dark',
        });
        expect(out['prefs'], untouched);
      },
    );

    test('does not treat a failure signature field as sensitive', () {
      final out =
          r.redactJson({
                'signature': 'exception:StateError:x',
                'key': 'GET a/b',
              })
              as Map;
      expect(out['signature'], 'exception:StateError:x');
      expect(out['key'], 'GET a/b');
    });

    test('caps nesting depth', () {
      Object? v = 'leaf';
      for (var i = 0; i < 100; i++) {
        v = {'a': v};
      }
      expect(jsonEncode(r.redactJson(v)), contains(Redactor.placeholder));
    });
  });

  group('URLs and headers', () {
    test('redacts query, fragment and user info', () {
      final uri = r.redactUri(
        Uri.parse(
          'https://user:pw@x.io/cb?access_token=1&code=synthCode&X-Amz-Signature=abc&q=2#id_token=$jwt&state=s',
        ),
      );
      final s = uri.toString();
      expect(uri.queryParameters['access_token'], Redactor.placeholder);
      expect(uri.queryParameters['code'], Redactor.placeholder);
      expect(uri.queryParameters['X-Amz-Signature'], Redactor.placeholder);
      expect(uri.queryParameters['q'], '2');
      expect(s, isNot(contains('pw@')));
      expect(s, isNot(contains(jwt)));
      expect(s, contains('state=s'));
    });

    test('keeps a URL without secrets as it is', () {
      const url = 'https://x.io/cart?page=2&sort=asc';
      expect(r.redactUrl(url), url);
    });

    test('redacts sensitive header names and scrubs other values', () {
      expect(
        r.redactHeaders({
          'Authorization': 'Bearer t',
          'X-CSRF-Token': 'abc',
          'Accept': ['a', 'b'],
          'Location': 'https://x.io/cb?token=$queryToken',
        }),
        {
          'authorization': Redactor.placeholder,
          'x-csrf-token': Redactor.placeholder,
          'accept': 'a, b',
          'location': 'https://x.io/cb?token=[REDACTED]',
        },
      );
    });
  });

  test(
    'redactText redacts sensitive ids, explicit sensitive fields and secrets in text',
    () {
      expect(r.redactText('login.password', 'hunter2'), Redactor.placeholder);
      expect(
        r.redactText('field1', 'hunter2', sensitive: true),
        Redactor.placeholder,
      );
      expect(
        r.redactText('notes', 'my token=$queryToken'),
        isNot(contains(queryToken)),
      );
      expect(r.redactText('notes', 'hello'), 'hello');
    },
  );

  test('scrubText stays fast on 256 KB bodies (no per-position rescans)', () {
    final inputs = [
      'a' * 256 * 1024,
      'a.' * 128 * 1024,
      '0123456789abcdef' * 16 * 1024,
      'key: value, ' * 21 * 1024,
      'x=y&' * 64 * 1024,
    ];
    for (final input in inputs) {
      final watch = Stopwatch()..start();
      r.scrubText(input);
      expect(
        watch.elapsedMilliseconds,
        lessThan(250),
        reason: input.substring(0, 12),
      );
    }
  });

  test('malformed URLs are redacted, never thrown', () {
    final uri = r.redactUri(
      Uri.parse('https://x.io/a?q=%FF&token=synthBad#frag'),
    );
    expect(uri.toString(), 'https://x.io/a');
  });

  test('very long request keys are shortened deterministically', () {
    final keys = RequestKeyBuilder();
    final uri = Uri.parse('https://x.io/a?q=${'v' * 20000}');
    final a = keys.keyFor('GET', uri, null);
    expect(a.length, lessThanOrEqualTo(RequestKeyBuilder.maxKeyLength));
    expect(keys.keyFor('GET', uri, null), a);
    expect(
      keys.keyFor('GET', Uri.parse('https://x.io/a?q=${'w' * 20000}'), null),
      isNot(a),
    );
  });

  test('extend adds rules', () {
    final extended = Redactor().extend(keys: ['tenantId']);
    expect(extended.isSensitiveKey('tenant_id'), isTrue);
    expect(extended.extraKeys, ['tenantId']);
  });

  test(
    'FailureRecord scrubs message and stack, and the signature uses the scrubbed message',
    () {
      final f = FailureRecord.exception(
        StateError('upload failed for https://api.test/x?token=$queryToken'),
        StackTrace.fromString('#0 send (package:a/a.dart:1:1) Bearer $bearer'),
        10,
        scrub: r.scrubText,
      );
      expect(f.message, isNot(contains(queryToken)));
      expect(f.stack, isNot(contains(bearer)));
      expect(f.signature, isNot(contains(queryToken)));
    },
  );
}
