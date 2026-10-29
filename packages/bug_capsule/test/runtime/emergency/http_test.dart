import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/emergency/emergency.dart';
import 'package:bug_capsule/src/version.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// `BugCapsule.emergency` with the SDK's own HTTP client against a real
/// local server serving the envelopes of spec/fixtures/emergency-v1.

final _fixtures =
    jsonDecode(
          File(
            '../../spec/fixtures/emergency-v1/envelopes.json',
          ).readAsStringSync(),
        )
        as Map<String, Object?>;
final _anchor = _fixtures['anchor']! as String;
final _appId = _fixtures['application_id']! as String;

Map<String, Object?> _envelope(String name) =>
    ((_fixtures['cases']! as List<Object?>).firstWhere(
              (c) => (c! as Map)['name'] == name,
            )!
            as Map)['envelope']!
        as Map<String, Object?>;

const _key = 'checkout.confirm_order';
const _ingestKey = 'bct_emergency0123456789';

typedef Seen = ({
  String method,
  String path,
  Map<String, String> query,
  String? auth,
  String? ifNoneMatch,
});

class EmergencyServer {
  late final HttpServer server;
  final List<Seen> seen = [];
  final List<Map<String, Object?>> receipts = [];
  bool captureEnabled = true;

  /// Answers `GET …/emergency/policies`; by default [envelope] with
  /// [etag], or 304 when the client already has it.
  Future<void> Function(HttpRequest req)? policies;
  Map<String, Object?>? envelope;
  String etag = '"v1"';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decodeStream(req);
      seen.add((
        method: req.method,
        path: req.uri.path,
        query: req.uri.queryParameters,
        auth: req.headers.value('authorization'),
        ifNoneMatch: req.headers.value('if-none-match'),
      ));
      final res = req.response;
      final path = req.uri.path;
      if (path == '/v1/apps/$_appId/emergency/policies') {
        final handler = policies;
        if (handler != null) {
          await handler(req);
        } else if (req.headers.value('if-none-match') == etag) {
          res.statusCode = 304;
        } else {
          res
            ..headers.contentType = ContentType.json
            ..headers.set('etag', etag)
            ..write(jsonEncode(envelope));
        }
      } else if (path == '/v1/apps/$_appId/emergency/receipts') {
        receipts.add((jsonDecode(body) as Map).cast<String, Object?>());
        res.statusCode = 204;
      } else if (path == '/v1/sdk/config') {
        res
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({'enabled': captureEnabled, 'configTtlSeconds': 300}),
          );
      } else if (path == '/v1/envelope') {
        res.write(jsonEncode({'accepted': 1, 'rejected': <Object?>[]}));
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  }

  String get api => 'http://127.0.0.1:${server.port}';
  BugCapsuleBackendConfig get backend =>
      BugCapsuleBackendConfig(url: api, ingestKey: _ingestKey);

  Iterable<Seen> get fetches =>
      seen.where((s) => s.path.endsWith('/emergency/policies'));

  Future<void> stop() => server.close(force: true);
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test answers every HttpClient request with 400; these tests talk
  // to a real local server.
  HttpOverrides.global = null;

  late Directory dir;
  late EmergencyServer server;
  final now = DateTime.utc(2026, 10, 29, 8, 30);
  final originalDebugPrint = debugPrint;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bugcapsule-emergency-http-');
    server = EmergencyServer()..envelope = _envelope('valid');
    await server.start();
    debugPrint = (String? message, {int? wrapWidth}) {};
    BugCapsule.emergency.debugOverrides = EmergencyTestOverrides(
      storageDirectory: dir,
      platform: () => EmergencyPlatform.flutterAndroid,
      now: () => now,
      random: MidRandom(),
    );
  });

  tearDown(() async {
    await BugCapsule.resetForTest();
    BugCapsule.debugOverrides = null;
    BugCapsule.emergency.debugOverrides = null;
    debugPrint = originalDebugPrint;
    await server.stop();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> initialize({EmergencyConfig? config}) =>
      BugCapsule.emergency.initialize(
        config ??
            EmergencyConfig(
              trustAnchor: _anchor,
              backend: server.backend,
              appVersion: '2.4.1',
            ),
      );

  test('200 with an ETag, then 304 with If-None-Match', () async {
    await initialize();
    await BugCapsule.emergency.refreshPolicies();

    final d = BugCapsule.emergency.evaluate(_key);
    expect(d.action, EmergencyAction.block);
    expect(d.reasonCode, 'PRICING_SAFETY');
    expect(d.documentRevision, 42);
    expect(d.source, EmergencyDecisionSource.policy);

    final first = server.fetches.first;
    expect(first.method, 'GET');
    expect(first.auth, 'Bearer $_ingestKey');
    expect(first.ifNoneMatch, isNull);
    expect(first.query, {
      'environment': 'production',
      'platform': 'FLUTTER_ANDROID',
      'app_version': '2.4.1',
      'sdk_version': bugCapsuleVersion,
    });

    await BugCapsule.emergency.refreshPolicies();
    expect(server.fetches.last.ifNoneMatch, '"v1"');
    expect(BugCapsule.emergency.status.revision, 42);
    expect(BugCapsule.emergency.status.lastFetchAt, now);
    expect(BugCapsule.emergency.status.lastError, isNull);
    expect(BugCapsule.emergency.evaluate(_key).action, EmergencyAction.block);

    await until(() => server.receipts.isNotEmpty);
    await BugCapsule.emergency.refreshPolicies();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.receipts, hasLength(1));
    final receipt = server.receipts.single;
    expect(receipt['status'], 'APPLIED');
    expect(receipt['revision'], 42);
    expect(receipt['errorCode'], isNull);
    expect(receipt['environment'], 'production');
    expect(receipt['platform'], 'FLUTTER_ANDROID');
    expect(receipt['appVersion'], '2.4.1');
    expect(receipt['sdkVersion'], bugCapsuleVersion);
    expect(receipt['installationId'], matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    final receiptRequest = server.seen.firstWhere(
      (s) => s.path.endsWith('/receipts'),
    );
    expect(receiptRequest.method, 'POST');
    expect(receiptRequest.auth, 'Bearer $_ingestKey');
  });

  test('a tampered envelope is rejected with a FAILED receipt', () async {
    server.envelope = _envelope('payload_tampered');
    await initialize();
    await BugCapsule.emergency.refreshPolicies();
    expect(BugCapsule.emergency.status.lastError?.code, 'bad_signature');
    expect(BugCapsule.emergency.status.state, EmergencyDocumentState.none);
    expect(
      BugCapsule.emergency.evaluate(_key).source,
      EmergencyDecisionSource.failureMode,
    );
    await until(() => server.receipts.isNotEmpty);
    expect(server.receipts.first, containsPair('status', 'FAILED'));
    expect(server.receipts.first, containsPair('errorCode', 'bad_signature'));
    expect(server.receipts.first, containsPair('revision', 0));
  });

  test('a hotfix status is posted as a RUNTIME receipt, and APPLIED '
      'carries it', () async {
    var answered = false;
    server.policies = (req) async {
      // The first fetch waits until the runtime report is in.
      await until(() => server.receipts.isNotEmpty);
      answered = true;
      req.response
        ..headers.contentType = ContentType.json
        ..headers.set('etag', server.etag)
        ..write(jsonEncode(server.envelope));
    };
    await initialize(
      config: EmergencyConfig(
        trustAnchor: _anchor,
        backend: server.backend,
        appVersion: '2.4.1+42',
        hotfixProvider: FakeHotfixProvider(
          const HotfixStatus(
            provider: 'shorebird',
            available: true,
            state: HotfixState.restartRequired,
            currentPatch: 3,
            nextPatch: 4,
          ),
        ),
      ),
    );
    await until(() => server.receipts.length >= 2);
    expect(answered, isTrue);
    const runtime = {
      'hotfix': {
        'provider': 'shorebird',
        'available': true,
        'releaseVersion': '2.4.1+42',
        'currentPatch': 3,
        'nextPatch': 4,
        'state': 'restart_required',
      },
    };
    final report = server.receipts.first;
    expect(report, {
      'environment': 'production',
      'platform': 'FLUTTER_ANDROID',
      'installationId': report['installationId'],
      'appVersion': '2.4.1+42',
      'sdkVersion': bugCapsuleVersion,
      'revision': 0,
      'status': 'RUNTIME',
      'errorCode': null,
      'runtime': runtime,
    });
    expect(report['installationId'], matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    final applied = server.receipts[1];
    expect(applied['status'], 'APPLIED');
    expect(applied['revision'], 42);
    expect(applied['runtime'], runtime);
    final post = server.seen.firstWhere((s) => s.path.endsWith('/receipts'));
    expect(post.auth, 'Bearer $_ingestKey');
  });

  test('a 200 body that is not JSON is malformed', () async {
    server.policies = (req) async {
      req.response.write('<html>proxy error</html>');
    };
    await initialize();
    await BugCapsule.emergency.refreshPolicies();
    expect(BugCapsule.emergency.status.lastError?.code, 'malformed');
  });

  test('401 stops scheduled fetches and keeps the cached document', () async {
    await initialize();
    await BugCapsule.emergency.refreshPolicies();
    expect(BugCapsule.emergency.status.revision, 42);
    server.policies = (req) async {
      req.response
        ..statusCode = 401
        ..headers.contentType = ContentType('application', 'problem+json')
        ..write(jsonEncode({'reason': 'token_revoked'}));
    };
    await BugCapsule.emergency.refreshPolicies();
    final status = BugCapsule.emergency.status;
    expect(status.credentialRejected, isTrue);
    expect(status.lastError?.code, 'credential_rejected');
    expect(status.lastError?.httpStatus, 401);
    expect(BugCapsule.emergency.debugEngine!.nextFetchAt, isNull);
    expect(BugCapsule.emergency.evaluate(_key).action, EmergencyAction.block);
  });

  test('409 emergency_not_configured is a failed fetch', () async {
    server.policies = (req) async {
      req.response
        ..statusCode = 409
        ..headers.contentType = ContentType('application', 'problem+json')
        ..write(
          jsonEncode({
            'code': 'integration_not_configured',
            'reason': 'emergency_not_configured',
          }),
        );
    };
    await initialize();
    await BugCapsule.emergency.refreshPolicies();
    final status = BugCapsule.emergency.status;
    expect(status.lastError?.code, 'not_configured');
    expect(status.lastError?.httpStatus, 409);
    expect(status.credentialRejected, isFalse);
    expect(BugCapsule.emergency.debugEngine!.nextFetchAt, isNotNull);
  });

  test('503 honors Retry-After', () async {
    server.policies = (req) async {
      req.response
        ..statusCode = 503
        ..headers.set('retry-after', '120');
    };
    await initialize();
    await BugCapsule.emergency.refreshPolicies();
    expect(BugCapsule.emergency.status.lastError?.code, 'http_503');
    expect(
      BugCapsule.emergency.debugEngine!.nextFetchAt,
      now.add(const Duration(seconds: 120)),
    );
  });

  test('a body over 1 MiB is a failed fetch', () async {
    server.policies = (req) async {
      req.response
        ..headers.contentType = ContentType.json
        ..write('"${'x' * (1024 * 1024 + 10)}"');
    };
    await initialize();
    await BugCapsule.emergency.refreshPolicies();
    expect(BugCapsule.emergency.status.lastError?.code, 'response_too_large');
  });

  test('a backend that cannot be reached is a network error', () async {
    final backend = server.backend;
    await server.stop();
    await initialize(
      config: EmergencyConfig(trustAnchor: _anchor, backend: backend),
    );
    await BugCapsule.emergency.refreshPolicies();
    expect(BugCapsule.emergency.status.lastError?.code, 'network_error');
    expect(
      BugCapsule.emergency.debugEngine!.nextFetchAt,
      now.add(const Duration(seconds: 60)),
    );
    server = EmergencyServer();
    await server.start(); // For tearDown.
  });

  group('with BugCapsule.init', () {
    setUp(() {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: dir,
      );
    });

    test('uses its connection, and the capture kill switch does not turn '
        'guards off', () async {
      server.captureEnabled = false;
      await BugCapsule.init(
        config: BugCapsuleConfig(backend: server.backend, appVersion: '2.4.1'),
        appRunner: () {},
      );
      await BugCapsule.refreshRemoteConfig();
      expect(BugCapsule.isRecording, isFalse);

      await initialize(config: EmergencyConfig(trustAnchor: _anchor));
      await BugCapsule.emergency.refreshPolicies();
      expect(BugCapsule.emergency.evaluate(_key).action, EmergencyAction.block);
      final fetch = server.fetches.first;
      expect(fetch.auth, 'Bearer $_ingestKey');
      expect(fetch.query['app_version'], '2.4.1');
    });

    test('works with capture disabled locally', () async {
      await BugCapsule.init(
        config: BugCapsuleConfig(backend: server.backend, enabled: false),
        appRunner: () {},
      );
      await initialize(config: EmergencyConfig(trustAnchor: _anchor));
      await BugCapsule.emergency.refreshPolicies();
      expect(BugCapsule.emergency.evaluate(_key).action, EmergencyAction.block);
      expect(server.seen.any((s) => s.path == '/v1/sdk/config'), isFalse);
    });

    test(
      'initialize before BugCapsule.init fetches once init connects',
      () async {
        await initialize(config: EmergencyConfig(trustAnchor: _anchor));
        await BugCapsule.emergency.refreshPolicies();
        expect(BugCapsule.emergency.status.lastError?.code, 'not_connected');
        await BugCapsule.init(
          config: BugCapsuleConfig(backend: server.backend, enabled: false),
          appRunner: () {},
        );
        await until(() => BugCapsule.emergency.status.revision == 42);
        expect(
          BugCapsule.emergency.evaluate(_key).action,
          EmergencyAction.block,
        );
      },
    );
  });
}
