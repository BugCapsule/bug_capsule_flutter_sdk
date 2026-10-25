// Inputs of the conformance fixtures. Expected outputs are computed by
// generate_conformance.dart from the reference implementation.
//
// Keep inputs portable: ASCII text, integer or short decimal numbers (each
// runtime parses and re-encodes bodies with its own JSON library; only
// integers and shortest-round-trip decimals print the same everywhere).

final requestKeyCases = <Map<String, Object?>>[
  {
    'name': 'get without query',
    'method': 'GET',
    'url': 'https://api.example.com/api/cart',
    'body': null,
  },
  {
    'name': 'method is upper-cased',
    'method': 'get',
    'url': 'https://api.example.com/api/cart',
    'body': null,
  },
  {
    'name': 'empty path becomes /',
    'method': 'GET',
    'url': 'https://api.example.com',
    'body': null,
  },
  {
    'name': 'host only, no scheme or port',
    'method': 'GET',
    'url': 'http://API.example.com:8080/x',
    'body': null,
  },
  {
    'name': 'query sorted by name, values keep order',
    'method': 'GET',
    'url': 'https://api.example.com/search?z=1&a=2&m=3&a=1',
    'body': null,
  },
  {
    'name': 'default ignored query parameters',
    'method': 'GET',
    'url':
        'https://api.example.com/feed?_=123&ts=9&timestamp=1&nonce=x&cachebust=7&page=2',
    'body': null,
  },
  {
    'name': 'query values are decoded',
    'method': 'GET',
    'url': 'https://api.example.com/search?q=red%20shoes&tag=a+b&e=%C3%A9',
    'body': null,
  },
  {
    'name': 'parameter without value',
    'method': 'GET',
    'url': 'https://api.example.com/x?flag&b=1',
    'body': null,
  },
  {
    'name': 'json body hashed canonically',
    'method': 'POST',
    'url': 'https://api.example.com/api/checkout',
    'body': {
      'b': 2,
      'a': 1,
      'items': [
        {'sku': 'A1', 'qty': 2},
        {'qty': 1, 'sku': 'B2'},
      ],
      'note': 'hi "there"',
    },
  },
  {
    'name': 'same body, different key order, same key',
    'method': 'POST',
    'url': 'https://api.example.com/api/checkout',
    'body': {
      'note': 'hi "there"',
      'items': [
        {'qty': 2, 'sku': 'A1'},
        {'sku': 'B2', 'qty': 1},
      ],
      'a': 1,
      'b': 2,
    },
  },
  {
    'name': 'json body given as text',
    'method': 'POST',
    'url': 'https://api.example.com/api/login',
    'body': '{"user":"qa","remember":true,"n":null}',
  },
  {
    'name': 'text body that is not json',
    'method': 'POST',
    'url': 'https://api.example.com/log',
    'body': 'plain text line',
  },
  {
    'name': 'empty text body is no body',
    'method': 'POST',
    'url': 'https://api.example.com/ping',
    'body': '',
  },
  {
    'name': 'scalars, decimals, unicode and escapes',
    'method': 'PUT',
    'url': 'https://api.example.com/v1/profile',
    'body': {
      'n': -12,
      'f': 1.5,
      'ok': false,
      'none': null,
      's': 'tab\there\nline',
      'u': 'café 中',
    },
  },
  {
    'name': 'endpoint rule ignores body fields at any depth',
    'method': 'POST',
    'url': 'https://api.example.com/api/checkout',
    'rules': [
      {
        'method': 'POST',
        'path': '/api/checkout',
        'ignoreBodyFields': ['timestamp', 'nonce'],
      },
    ],
    'body': {
      'cartId': 'c1',
      'timestamp': 1760000000000,
      'meta': {'nonce': 'abc', 'v': 1},
    },
  },
  {
    'name': 'dotted ignore removes only that path',
    'method': 'POST',
    'url': 'https://api.example.com/api/events',
    'rules': [
      {
        'method': '*',
        'path': '/api/events',
        'ignoreBodyFields': ['meta.ts'],
      },
    ],
    'body': {
      'ts': 1,
      'meta': {'ts': 2, 'kind': 'x'},
    },
  },
  {
    'name': 'matchBodyFields keeps only listed top-level fields',
    'method': 'POST',
    'url': 'https://api.example.com/payments',
    'rules': [
      {
        'method': 'POST',
        'path': '/payments',
        'matchBodyFields': ['cart_id', 'amount'],
      },
    ],
    'body': {
      'cart_id': 'k',
      'amount': 10,
      'request_id': 'r-1',
      'currency': 'EUR',
    },
  },
  {
    'name': 'rule with :param and ignored query',
    'method': 'GET',
    'url': 'https://api.example.com/users/42/orders?page=1&session_ts=5',
    'rules': [
      {
        'method': 'GET',
        'path': '/users/:id/orders',
        'ignoreQuery': ['session_ts'],
      },
    ],
    'body': null,
  },
  {
    'name': 'rule with trailing wildcard',
    'method': 'GET',
    'url': 'https://cdn.example.com/assets/img/a.png?v=3',
    'rules': [
      {
        'method': 'GET',
        'path': '/assets/*',
        'ignoreQuery': ['v'],
      },
    ],
    'body': null,
  },
  {
    'name': 'first matching rule wins',
    'method': 'GET',
    'url': 'https://api.example.com/a/b?x=1&y=2',
    'rules': [
      {
        'method': 'GET',
        'path': '/a/*',
        'ignoreQuery': ['x'],
      },
      {
        'method': 'GET',
        'path': '/a/b',
        'ignoreQuery': ['y'],
      },
    ],
    'body': null,
  },
  {
    'name': 'rule method mismatch does not apply',
    'method': 'POST',
    'url': 'https://api.example.com/a/b?x=1',
    'rules': [
      {
        'method': 'GET',
        'path': '/a/b',
        'ignoreQuery': ['x'],
      },
    ],
    'body': null,
  },
  {
    'name': 'trailing slash matches rule',
    'method': 'GET',
    'url': 'https://api.example.com/items/?x=1',
    'rules': [
      {
        'method': 'GET',
        'path': '/items',
        'ignoreQuery': ['x'],
      },
    ],
    'body': null,
  },
  {
    'name': 'custom global ignores',
    'method': 'POST',
    'url': 'https://api.example.com/q?_=1&t=2',
    'globalIgnoreQuery': ['t'],
    'globalIgnoreBodyFields': ['requestId'],
    'body': {'requestId': 'x', 'q': 'shoes'},
  },
  {
    'name': 'array body',
    'method': 'POST',
    'url': 'https://api.example.com/batch',
    'body': [
      3,
      1,
      {
        'z': true,
        'a': [1, 2],
      },
    ],
  },
  {
    'name': 'redacted url and body (capture pipeline)',
    'method': 'POST',
    'url':
        'https://user:pw@api.example.com/oauth/token?code=abc123&state=ok&signature=zz',
    'redact': true,
    'body': {
      'grant_type': 'authorization_code',
      'client_secret': 's3cr3t',
      'device': {'pushToken': 'abc'},
    },
  },
  {
    'name': 'redaction with app keys',
    'method': 'POST',
    'url': 'https://api.example.com/loyalty?loyaltyId=L-77',
    'redact': true,
    'redactKeys': ['loyaltyId'],
    'body': {'loyaltyId': 'L-77', 'points': 5},
  },
  {
    'name': 'very long url is shortened deterministically',
    'method': 'GET',
    'url': 'https://api.example.com/long?q=${'abcdefghij' * 820}',
    'body': null,
  },
];

final signatureCases = <Map<String, Object?>>[
  {
    'kind': 'exception',
    'type': 'StateError',
    'message': 'Bad state: Cart total is negative (-3)',
  },
  {
    'kind': 'exception',
    'type': 'IllegalStateException',
    'message': 'Cart total is negative: -300 cents',
  },
  {
    'kind': 'exception',
    'type': 'TypeError',
    'message': "Cannot read properties of null (reading 'price')",
  },
  {'kind': 'exception', 'type': 'NullPointerException', 'message': ''},
  {
    'kind': 'exception',
    'type': 'Err',
    'message': 'object 0x7f3a9c00d1e8 freed twice; id deadbeefcafe12 ok',
  },
  {
    'kind': 'exception',
    'type': 'E',
    'message': 'first line 12\nsecond line 34',
  },
  {
    'kind': 'exception',
    'type': 'E',
    'message': '  lots   of\t white   space  ',
  },
  {
    'kind': 'exception',
    'type': 'E',
    'message': 'order 2026-10-19 at 10:42:07.123 failed',
  },
  {
    'kind': 'exception',
    'type': 'E',
    'message': 'short hex abc1234 stays, longer abcdef12 goes',
  },
  {'kind': 'exception', 'type': 'E', 'message': 'x' * 260},
  {'kind': 'assertion', 'type': 'cart_total_non_negative', 'message': ''},
  {'kind': 'manual', 'type': 'manual', 'message': 'QA capture 3'},
];

const redactionKeyCases = [
  'password',
  'user_password',
  'Pass-Word',
  'passwd',
  'fcmToken',
  'access.token',
  'clientSecret',
  'x-api-key',
  'apiKey',
  'API_KEY',
  'authorization',
  'Cookie',
  'cardNumber',
  'credit_card',
  'privateKey',
  'session_id',
  'sessionId',
  'pin',
  'PIN',
  'shipping',
  'pan',
  'span',
  'otp',
  'ssn',
  'cvv',
  'cvc',
  'passcode',
  'iban',
  'code',
  'sig',
  'key',
  'auth',
  'sid',
  'session',
  'x-amz-signature',
  'Credential',
  'loyaltyId',
  'loyalty_id',
  'email',
  'name',
  'total',
];

const redactionHeaderCases = [
  'Authorization',
  'cookie',
  'Set-Cookie',
  'proxy-authorization',
  'X-API-Key',
  'x-auth-token',
  'x-tenant',
  'X-Csrf-Token',
  'content-type',
  'accept',
  'location',
];

const scrubTextCases = [
  'nothing to see here',
  'abc',
  'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.sig_part-1',
  'retry with token abcdef123456 later',
  'Basic dXNlcjpwYXNzd29yZA==',
  'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abc in text',
  'keys sk_live_abcdefgh12345678 AKIAABCDEFGHIJKLMNOP ghp_abcdefghijklmnopqrstuvwxyz bci_abcdefghijklmnopqrstuv',
  'GET /login?password=hunter2&user=qa&loyaltyId=L1',
  '{"password": "hunter2", "user": "qa"}',
  "{'apiKey': 'abc', 'ok': 'yes'}",
  'password: hunter2, user: qa',
  'redirect to https://example.com/cb?code=xyz',
  'card 4111 1111 1111 1111 expires',
  'not a card 1234 5678 9012 3456',
  'card 4111-1111-1111-1111',
  'otp=123456 and pin=1234',
  'session_id=abc; Path=/',
  'value [REDACTED] already',
];

const redactUrlCases = [
  'https://api.example.com/cart?lang=en',
  'https://user:secret@api.example.com/x',
  'https://api.example.com/cb?code=abc&state=xyz',
  'https://bucket.s3.amazonaws.com/f?X-Amz-Signature=abc&X-Amz-Credential=k&X-Amz-Date=1',
  'https://api.example.com/x?token=t1&page=2&loyaltyId=L1',
  'https://example.com/cb#access_token=abc&token_type=bearer',
  'https://api.example.com/x?note=Bearer%20abcdefghijkl',
  'https://api.example.com/plain/path/only',
];

const redactHeadersCases = <Map<String, Object?>>[
  {
    'Authorization': 'Bearer abc',
    'Content-Type': 'application/json',
    'X-Tenant': 'acme',
  },
  {
    'cookie': 'a=b',
    'Set-Cookie': 'sid=1',
    'accept': 'text/html',
    'x-request-token': 'zzz',
  },
  {
    'Location': 'https://example.com/cb?code=abc',
    'X-Trace': 'password=hunter2',
    'Accept-Language': ['en', 'fr'],
  },
];

const redactJsonCases = <Object?>[
  {
    'user': 'qa',
    'password': 'hunter2',
    'nested': {
      'apiKey': 'k',
      'list': [
        {'token': 't'},
        'Bearer abcdefghij',
      ],
    },
  },
  {'loyaltyId': 'L-1', 'points': 3, 'pin': 1234, 'shipping': 'fast'},
  {'profile': '{"refreshToken":"abc","name":"x"}', 'raw': '[1, {"secret": 2}]'},
  {'password': null, 'cvv': '', 'ok': true},
  ['sk_test_abcdefgh12345678', 42, null],
  'just a string with otp=999999',
  12,
];

const redactTextCases = <Map<String, Object?>>[
  {'id': 'login.email', 'value': 'qa@example.com'},
  {'id': 'login.password', 'value': 'hunter2'},
  {'id': 'coupon', 'value': 'SAVE100'},
  {'id': 'notes', 'value': 'call me, token abcdefghijk1 ok'},
  {'id': 'card.holder', 'value': 'Jane', 'sensitive': true},
  {'id': 'otp', 'value': '123456'},
];

const _sig = 'exception:StateError:Bad state: Cart total is negative (#)';

Map<String, Object?> _ok({
  List<String> divergences = const [],
  int dispatched = 3,
  int? expected = 3,
}) => {
  'outcome': 'not_reproduced',
  'expectedSignature': _sig,
  'eventsDispatched': dispatched,
  'eventsExpected': expected,
  'divergences': divergences,
};

const Map<String, Object?> _repro = {
  'outcome': 'reproduced',
  'expectedSignature': _sig,
};
const Map<String, Object?> _error = {
  'outcome': 'error',
  'expectedSignature': _sig,
  'message': 'timeout',
};
const Map<String, Object?> _incompatible = {
  'outcome': 'incompatible',
  'message': 'schema',
};
const Map<String, Object?> _noAssertion = {'outcome': 'no_assertion'};

final verdictCases = <Map<String, Object?>>[
  {
    'name': 'replay reproduced every time',
    'kind': 'replay',
    'requested': 3,
    'reports': [_repro, _repro, _repro],
  },
  {
    'name': 'replay never reproduced, all clean',
    'kind': 'replay',
    'requested': 2,
    'reports': [_ok(), _ok()],
  },
  {
    'name': 'replay flaky',
    'kind': 'replay',
    'requested': 3,
    'reports': [_repro, _ok(), _repro],
  },
  {
    'name': 'replay with an error is inconclusive',
    'kind': 'replay',
    'requested': 2,
    'reports': [_repro, _error],
  },
  {
    'name': 'replay missing attempt',
    'kind': 'replay',
    'requested': 3,
    'reports': [_repro, _repro],
  },
  {
    'name': 'verify fixed',
    'kind': 'verify',
    'requested': 3,
    'reports': [_ok(), _ok(), _ok()],
  },
  {
    'name': 'verify still failing',
    'kind': 'verify',
    'requested': 2,
    'reports': [_repro, _repro],
  },
  {
    'name': 'verify flaky',
    'kind': 'verify',
    'requested': 2,
    'reports': [_repro, _ok()],
  },
  {
    'name': 'verify one clean plus error is inconclusive',
    'kind': 'verify',
    'requested': 2,
    'reports': [_ok(), _error],
  },
  {
    'name': 'verify fewer attempts than requested',
    'kind': 'verify',
    'requested': 3,
    'reports': [_ok(), _ok()],
  },
  {
    'name': 'verify with material divergence is not fixed',
    'kind': 'verify',
    'requested': 2,
    'reports': [
      _ok(),
      _ok(divergences: ['network.unrecorded']),
    ],
  },
  {
    'name': 'expected divergences keep an attempt clean',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      _ok(divergences: ['build.gitSha', 'screen.size', 'network.unused']),
    ],
  },
  {
    'name': 'unknown divergence types are material',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      _ok(divergences: ['capability.unsupported']),
    ],
  },
  {
    'name': 'restore failure is material',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      _ok(divergences: ['restore.late']),
    ],
  },
  {
    'name': 'incomplete input dispatch is not clean',
    'kind': 'verify',
    'requested': 1,
    'reports': [_ok(dispatched: 2, expected: 3)],
  },
  {
    'name': 'unexpected failure is not clean',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      {
        ..._ok(),
        'otherFailures': ['exception:TypeError:x'],
      },
    ],
  },
  {
    'name': 'redacted text replay is material',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      _ok(divergences: ['text.redacted']),
    ],
  },
  {
    'name': 'incompatible wins',
    'kind': 'replay',
    'requested': 2,
    'reports': [_repro, _incompatible],
  },
  {
    'name': 'no assertion is inconclusive',
    'kind': 'replay',
    'requested': 1,
    'reports': [_noAssertion],
  },
  {
    'name': 'reproduction without expected signature is invalid',
    'kind': 'replay',
    'requested': 1,
    'reports': [
      {'outcome': 'reproduced'},
    ],
  },
  {
    'name': 'zero requested attempts',
    'kind': 'verify',
    'requested': 0,
    'reports': <Object?>[],
  },
  {
    'name': 'more reports than requested',
    'kind': 'verify',
    'requested': 1,
    'reports': [_ok(), _ok()],
  },
];
