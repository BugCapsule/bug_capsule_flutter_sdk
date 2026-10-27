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
    'name': 'crash capsule: the same crash in another in-app frame reproduces',
    'kind': 'replay',
    'requested': 1,
    'reports': [
      {
        'outcome': 'reproduced',
        'expectedSignature': 'crash:SIGSEGV',
        'divergences': ['failure.different_frame'],
      },
    ],
  },
  {
    'name': 'crash capsule: another crash type is inconclusive',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      {
        'outcome': 'not_reproduced',
        'expectedSignature': 'crash:SIGSEGV',
        'otherFailures': ['crash:SIGABRT'],
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
  {
    'name': 'interactions recorded after the failure may go unused',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      _ok(
        divergences: [
          'ws.unusedAfterFailure',
          'platform.unusedAfterFailure',
          'native.unusedAfterFailure',
        ],
      ),
    ],
  },
  {
    'name': 'a missing interaction prevents fixed',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      _ok(divergences: ['ws.unused']),
    ],
  },
  {
    'name': 'unexpected, mismatched and incomplete interactions are material',
    'kind': 'verify',
    'requested': 3,
    'reports': [
      _ok(divergences: ['platform.unrecorded']),
      _ok(divergences: ['native.mismatch']),
      _ok(divergences: ['ws.noPayload']),
    ],
  },
  {
    'name': 'a live dependency contact prevents fixed',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      _ok(divergences: ['dependency.live']),
    ],
  },
  {
    'name': 'an unsupported required dependency is incompatible',
    'kind': 'verify',
    'requested': 1,
    'reports': [
      {
        'outcome': 'incompatible',
        'expectedSignature': _sig,
        'message':
            'dependency.unsupported: bug_capsule.web_socket_channel schema 1',
      },
    ],
  },
];

// ------------------------------------------------------------ interactions

/// Typed values (capsule-v2 §3.1), given as their encoded JSON; readers
/// decode then re-encode them and must get the same JSON back.
const typedValueCases = <Map<String, Object?>>[
  {'name': 'null', 'encoded': null},
  {'name': 'string', 'encoded': 'héllo'},
  {'name': 'small int', 'encoded': 42},
  {
    'name': 'int beyond 2^53',
    'encoded': {r'$t': 'int', 'v': '9007199254740993'},
  },
  {'name': 'fractional double', 'encoded': 12.5},
  {
    'name': 'integral double',
    'encoded': {r'$t': 'double', 'v': '80.0'},
  },
  {
    'name': 'NaN',
    'encoded': {r'$t': 'double', 'v': 'NaN'},
  },
  {
    'name': 'negative zero',
    'encoded': {r'$t': 'double', 'v': '-0.0'},
  },
  {
    'name': 'bytes',
    'encoded': {r'$t': 'bytes', 'b64': 'AAEC/w=='},
  },
  {
    'name': 'int32 array',
    'encoded': {
      r'$t': 'i32',
      'v': [1, -2, 3],
    },
  },
  {
    'name': 'int64 array',
    'encoded': {
      r'$t': 'i64',
      'v': ['1', '-9223372036854775808'],
    },
  },
  {
    'name': 'float64 array with infinity',
    'encoded': {
      r'$t': 'f64',
      'v': [1.5, 'Infinity'],
    },
  },
  {
    'name': 'map with int keys',
    'encoded': {
      r'$t': 'map',
      'e': [
        [1, 'one'],
        ['two', 2],
      ],
    },
  },
  {
    'name': 'map with a \$t key',
    'encoded': {
      r'$t': 'map',
      'e': [
        [r'$t', 'x'],
      ],
    },
  },
  {
    'name': 'nested plain map',
    'encoded': {
      'b': [
        true,
        {r'$t': 'double', 'v': '2.0'},
      ],
      'a': {'c': null},
    },
  },
];

/// Interaction keys (capsule-v2 §5): scope, method and typed args.
const interactionKeyCases = <Map<String, Object?>>[
  {'scope': 'plugins.example.com/battery', 'method': 'getLevel', 'args': null},
  {
    'scope': 'plugins.example.com/battery',
    'method': 'getLevel',
    'args': <String, Object?>{},
  },
  {
    'scope': 'doc.get',
    'method': null,
    'args': {'path': 'carts/user-1'},
  },
  {
    'scope': 'doc.get',
    'method': null,
    'args': {
      'z': 1,
      'a': [
        {'y': 2, 'x': 1},
      ],
    },
  },
  {
    'scope': 'plugins.example.com/nfc',
    'method': 'start',
    'args': {
      r'$t': 'map',
      'e': [
        [
          1,
          {r'$t': 'bytes', 'b64': 'AAEC'},
        ],
      ],
    },
  },
  {
    'scope': 'wss://quotes.example.com/v1/stream?token=[REDACTED]',
    'method': null,
    'args': null,
  },
];

/// Payload encoding (capsule-v2 §3, §7) with the default redactor. `value`
/// is typed JSON; `kind` marks WebSocket frames.
const payloadCases = <Map<String, Object?>>[
  {'name': 'text frame', 'kind': 'text', 'value': '{"op":"subscribe"}'},
  {
    'name': 'text frame with a token',
    'kind': 'text',
    'value': '{"op":"auth","token":"abc123"}',
  },
  {
    'name': 'binary frame without a serializer',
    'kind': 'binary',
    'value': {r'$t': 'bytes', 'b64': 'AAECAwQ='},
  },
  {
    'name': 'binary frame with captureBinary',
    'kind': 'binary',
    'value': {r'$t': 'bytes', 'b64': 'AAECAwQ='},
    'captureBinary': true,
  },
  {
    'name': 'value with a sensitive key',
    'value': {'uid': 'u1', 'password': 'hunter2'},
  },
  {
    'name': 'redacted value declared replayable',
    'value': {'uid': 'u1', 'password': 'hunter2'},
    'redactedReplayable': true,
  },
  {
    'name': 'value over the payload limit',
    'value': {'blob': 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'},
    'maxPayloadBytes': 32,
  },
];

/// Delivery scheduling (capsule-v2 §5). The driver advances a replay clock
/// to each step's `at`, delivering due events on the way (bound scopes
/// only), then performs the step. Steps: `take` (dep, type, key),
/// `takeNext` (scope, types), `bind` (scope), `unbind` (scope), `runStarted`.
final scheduleCases = <Map<String, Object?>>[
  {
    'name': 'responses keep their recorded latency after a late connect',
    'deps': ['ws'],
    'base': 0,
    'events': [
      _ix(100, 'ws.connect', {'conn': 'ws1', 'key': 'K', 'occurrence': 0}),
      _ix(180, 'ws.open', {'conn': 'ws1'}),
      _ix(200, 'ws.send', {'conn': 'ws1', 'index': 0}),
      _ix(260, 'ws.message', {'conn': 'ws1', 'index': 0}),
      _ix(260, 'ws.message', {'conn': 'ws1', 'index': 1}),
      _ix(900, 'ws.message', {'conn': 'ws1', 'index': 2}),
    ],
    'steps': [
      {'at': 0, 'op': 'runStarted'},
      {'at': 1000, 'op': 'take', 'dep': 'ws', 'type': 'ws.connect', 'key': 'K'},
      {'at': 1000, 'op': 'bind', 'scope': 'ws:ws1'},
      {
        'at': 1500,
        'op': 'takeNext',
        'scope': 'ws:ws1',
        'types': ['ws.send'],
      },
    ],
  },
  {
    'name': 'concurrent identical connections are matched by order',
    'deps': ['ws'],
    'base': 0,
    'events': [
      _ix(100, 'ws.connect', {'conn': 'a', 'key': 'K', 'occurrence': 0}),
      _ix(100, 'ws.connect', {'conn': 'b', 'key': 'K', 'occurrence': 1}),
      _ix(150, 'ws.message', {'conn': 'b', 'index': 0}),
      _ix(170, 'ws.message', {'conn': 'a', 'index': 0}),
    ],
    'steps': [
      {'at': 0, 'op': 'runStarted'},
      {'at': 100, 'op': 'take', 'dep': 'ws', 'type': 'ws.connect', 'key': 'K'},
      {'at': 100, 'op': 'bind', 'scope': 'ws:a'},
      {'at': 100, 'op': 'take', 'dep': 'ws', 'type': 'ws.connect', 'key': 'K'},
      {'at': 100, 'op': 'bind', 'scope': 'ws:b'},
    ],
  },
  {
    'name': 'events wait for their subscription and are never early',
    'deps': ['ch'],
    'base': 0,
    'events': [
      _ix(30, 'platform.listen', {
        'channel': 'c',
        'sub': 's1',
        'key': 'L',
        'occurrence': 0,
      }),
      _ix(35, 'platform.event', {'channel': 'c', 'sub': 's1', 'index': 0}),
      _ix(36, 'platform.event', {'channel': 'c', 'sub': 's1', 'index': 1}),
      _ix(600, 'platform.cancel', {'channel': 'c', 'sub': 's1'}),
      _ix(700, 'platform.done', {'channel': 'c', 'sub': 's1'}),
    ],
    'steps': [
      {'at': 0, 'op': 'runStarted'},
      {
        'at': 400,
        'op': 'take',
        'dep': 'ch',
        'type': 'platform.listen',
        'key': 'L',
      },
      {'at': 402, 'op': 'bind', 'scope': 'platform.sub:s1'},
    ],
  },
  {
    'name': 'platform-to-app calls follow the replay clock once handled',
    'deps': ['ch'],
    'base': 0,
    'events': [
      _ix(-20, 'platform.call', {
        'channel': 'push',
        'call': 'c0',
        'dir': 'platform',
        'key': 'P',
        'occurrence': 0,
      }),
      _ix(500, 'platform.call', {
        'channel': 'push',
        'call': 'c1',
        'dir': 'platform',
        'key': 'P',
        'occurrence': 1,
      }),
      _ix(501, 'platform.result', {'channel': 'push', 'call': 'c1'}),
    ],
    'steps': [
      {'at': 10, 'op': 'bind', 'scope': 'platform.in:push'},
      {'at': 50, 'op': 'runStarted'},
      {
        'at': 560,
        'op': 'takeNext',
        'scope': 'platform.call:c1',
        'types': ['platform.result', 'platform.error'],
      },
    ],
  },
  {
    'name': 'unmatched interactions before and after the failure',
    'deps': ['ws'],
    'base': 0,
    'failureT': 500,
    'events': [
      _ix(100, 'ws.connect', {'conn': 'ws1', 'key': 'K', 'occurrence': 0}),
      _ix(150, 'ws.message', {'conn': 'ws1', 'index': 0}),
      _ix(400, 'ws.send', {'conn': 'ws1', 'index': 0}),
      _ix(900, 'ws.send', {'conn': 'ws1', 'index': 1}),
    ],
    'steps': [
      {'at': 0, 'op': 'runStarted'},
      {'at': 100, 'op': 'take', 'dep': 'ws', 'type': 'ws.connect', 'key': 'K'},
      {'at': 100, 'op': 'bind', 'scope': 'ws:ws1'},
    ],
  },
];

Map<String, Object?> _ix(int t, String type, Map<String, Object?> data) {
  final dep = type.startsWith('ws.') ? 'ws' : 'ch';
  return {
    't': t,
    'type': type,
    'data': {'dep': dep, ...data},
  };
}
