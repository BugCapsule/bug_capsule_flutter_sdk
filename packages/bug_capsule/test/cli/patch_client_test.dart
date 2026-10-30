import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/src/cli/backend_client.dart';
import 'package:bug_capsule/src/cli/patch_client.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Credentials credentials;
  late Future<void> Function(HttpRequest) handle;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    credentials = Credentials(
      url: 'http://127.0.0.1:${server.port}',
      token: 'bcp_test_token',
    );
    handle = (r) async {
      r.response.write('{}');
      await r.response.close();
    };
    server.listen((r) async => handle(r));
  });
  tearDown(() async => server.close(force: true));
  PatchClient client() =>
      PatchClient(credentials, retries: 1, retryDelay: Duration.zero);

  test(
    'ephemeral human session is project-scoped and never falls back after expiry',
    () async {
      var calls = 0;
      handle = (r) async {
        calls++;
        expect(r.headers.value('authorization'), 'Bearer bcw_ephemeral');
        expect(
          r.headers.value('x-bugcapsule-project'),
          '11111111-2222-4333-8444-555555555555',
        );
        r.response.statusCode = 401;
        r.response.write('{"code":"unauthorized","detail":"Session expired"}');
        await r.response.close();
      };
      final human = PatchClient(
        credentials,
        sessionToken: 'bcw_ephemeral',
        projectId: '11111111-2222-4333-8444-555555555555',
      );
      await expectLater(
        human.request('GET', '/v1/patches/bases'),
        throwsA(
          isA<PatchApiException>().having((e) => e.status, 'status', 401),
        ),
      );
      expect(calls, 1);
      await expectLater(
        PatchClient(
          credentials,
          sessionToken: 'bcw_ephemeral',
        ).request('GET', '/v1/patches/bases'),
        throwsStateError,
      );
      expect(calls, 1);
    },
  );

  test('refuses legacy and missing credentials without a request', () async {
    var calls = 0;
    handle = (r) async {
      calls++;
      await r.response.close();
    };
    await expectLater(
      PatchClient(
        Credentials(url: credentials.url, secretKey: 'bcs_old'),
      ).request('GET', '/v1/patches/bases'),
      throwsStateError,
    );
    expect(calls, 0);
  });
  test(
    'retries transient failure with identical body, project token and idempotency key',
    () async {
      final bodies = <String>[];
      final keys = <String?>[];
      handle = (r) async {
        expect(r.headers.value('authorization'), 'Bearer bcp_test_token');
        keys.add(r.headers.value('idempotency-key'));
        bodies.add(await utf8.decoder.bind(r).join());
        r.response.statusCode = bodies.length == 1 ? 503 : 202;
        r.response.headers.set('idempotent-replayed', 'true');
        r.response.write(
          jsonEncode(
            bodies.length == 1
                ? {'code': 'unavailable'}
                : {'result': 'approval_required'},
          ),
        );
        await r.response.close();
      };
      final result = await client().request(
        'POST',
        '/v1/patches/deployments/id/request',
        body: {'expectedVersion': 7, 'reason': 'reviewed'},
        idempotencyKey: 'retry-request-123',
      );
      expect(result.status, 202);
      expect(result.data['result'], 'approval_required');
      expect(result.replayed, isTrue);
      expect(keys, ['retry-request-123', 'retry-request-123']);
      expect(bodies[0], bodies[1]);
    },
  );
  test(
    'preserves conflict reason and does not retry authorization or optimistic conflicts',
    () async {
      for (final status in [403, 409]) {
        var calls = 0;
        handle = (r) async {
          calls++;
          await r.drain<void>();
          r.response.statusCode = status;
          r.response.write(
            jsonEncode({
              'code': 'conflict',
              'reason': 'version_mismatch',
              'currentVersion': 8,
            }),
          );
          await r.response.close();
        };
        await expectLater(
          client().request(
            'POST',
            '/v1/patches/deployments/id/request',
            body: {},
            idempotencyKey: 'conflict-key-123',
          ),
          throwsA(
            isA<PatchApiException>()
                .having((e) => e.status, 'status', status)
                .having(
                  (e) => e.problem['reason'],
                  'reason',
                  'version_mismatch',
                ),
          ),
        );
        expect(calls, 1);
      }
    },
  );
  test('never follows backend redirects carrying a management token', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var leaked = false;
    target.listen((r) async {
      leaked = true;
      await r.response.close();
    });
    try {
      handle = (r) async {
        r.response.statusCode = 307;
        r.response.headers.set(
          'location',
          'http://127.0.0.1:${target.port}/leak',
        );
        await r.response.close();
      };
      await expectLater(
        client().request('GET', '/v1/patches/bases'),
        throwsA(
          isA<PatchApiException>().having((e) => e.status, 'status', 307),
        ),
      );
      expect(leaked, isFalse);
    } finally {
      await target.close(force: true);
    }
  });
  test(
    'sends the bundle media type and keeps encoded identifiers encoded once',
    () async {
      handle = (r) async {
        expect(r.uri.path, '/v1/patches/uploads/ios%2B42/content');
        expect(
          r.headers.contentType!.mimeType,
          'application/vnd.bugcapsule.bcpatch',
        );
        expect(await r.fold<List<int>>([], (a, b) => a..addAll(b)), [
          0,
          1,
          255,
        ]);
        r.response.write('{"state":"received"}');
        await r.response.close();
      };
      expect(
        (await client().request(
          'PUT',
          '/v1/patches/uploads/ios%2B42/content',
          bytes: [0, 1, 255],
          idempotencyKey: 'bundle-key-123',
        )).data['state'],
        'received',
      );
    },
  );
  test('bounds a stalled response by an absolute deadline', () async {
    handle = (r) async {
      await r.drain<void>();
    };
    final watch = Stopwatch()..start();
    await expectLater(
      PatchClient(
        credentials,
        retries: 0,
        timeout: const Duration(milliseconds: 60),
      ).request('GET', '/v1/patches/bases'),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
