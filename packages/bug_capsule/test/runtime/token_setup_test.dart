import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/backend.dart'
    show BugCapsuleBackendClient;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Token-only setup (spec/connection-token-v1.md) against a real local HTTP
/// server: the SDK's own HTTP client, timeouts and outbox, end to end.

typedef Seen = ({String method, String path, String? auth});

enum Answer { ok, revoked, down, unavailable, hang }

class FakeBackend {
  late final HttpServer server;
  final List<Seen> seen = [];
  Answer answer = Answer.ok;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await req.drain<void>();
      seen.add((
        method: req.method,
        path: req.uri.path,
        auth: req.headers.value('authorization'),
      ));
      final res = req.response;
      switch (answer) {
        case Answer.hang:
          return; // never answers
        case Answer.down:
          (await res.detachSocket(writeHeaders: false)).destroy();
          return;
        case Answer.unavailable:
          res.statusCode = 503;
        case Answer.revoked:
          res
            ..statusCode = 401
            ..headers.contentType = ContentType('application', 'problem+json')
            ..write(
              jsonEncode({
                'code': 'unauthorized',
                'reason': 'token_revoked',
                'detail':
                    'this SDK token was revoked; generate a new token in the BugCapsule dashboard',
              }),
            );
        case Answer.ok:
          res.headers.contentType = ContentType.json;
          if (req.uri.path.endsWith('/v1/sdk/config')) {
            res.write(
              jsonEncode({
                'enabled': true,
                'sampleRate': 1,
                'configTtlSeconds': 300,
              }),
            );
          } else if (req.uri.path.endsWith('/v1/capsules')) {
            res
              ..statusCode = 201
              ..write(jsonEncode({'id': 'srv-1'}));
          } else if (req.uri.path.endsWith('/v1/envelope')) {
            res.write(jsonEncode({'accepted': 1, 'rejected': []}));
          } else {
            res.statusCode = 404;
          }
      }
      await res.close();
    });
  }

  String get api => 'http://127.0.0.1:${server.port}';

  Future<void> stop() => server.close(force: true);
}

const key = 'bct_Q2xpZW50VmlzaWJsZUluZ2VzdE9ubHlLZXlfMDEyMzQ';

String tokenFor(String api, {String k = key}) =>
    'bcsdk.v1.${base64Url.encode(utf8.encode(jsonEncode({'api': api, 'key': k}))).replaceAll('=', '')}';

Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test answers every HttpClient request with 400; these tests talk
  // to a real local server.
  HttpOverrides.global = null;

  late Directory dir;
  late FakeBackend backend;
  late List<String> logs;
  final originalDebugPrint = debugPrint;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bugcapsule-token-');
    backend = FakeBackend();
    await backend.start();
    logs = [];
    debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(storageDirectory: dir);
  });

  tearDown(() async {
    await BugCapsule.resetForTest();
    BugCapsule.debugOverrides = null;
    debugPrint = originalDebugPrint;
    await backend.stop();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<bool> init(BugCapsuleConfig config) async {
    var ran = false;
    await BugCapsule.init(config: config, appRunner: () => ran = true);
    return ran;
  }

  BugCapsuleConnectionStatus connection() => BugCapsule.status.connection;

  Future<int> queued() async {
    final outbox = Directory('${dir.path}/outbox');
    if (!await outbox.exists()) return 0;
    return (await outbox
            .list()
            .where((e) => e.path.endsWith('.bugcapsule'))
            .toList())
        .length;
  }

  test('status before init is not_configured', () {
    expect(
      BugCapsule.status.connection.state,
      BugCapsuleConnectionState.notConfigured,
    );
    expect(BugCapsule.status.instrumentation.missing, [
      'network',
      'navigation',
      'app_state',
    ]);
  });

  test(
    'token only: config from the token API with Bearer key, then data, each confirmed separately',
    () async {
      expect(
        await init(
          BugCapsuleConfig(
            token: tokenFor(backend.api),
            mode: CaptureMode.qa,
            gitSha: 'abc',
          ),
        ),
        isTrue,
      );
      await until(
        () => connection().state == BugCapsuleConnectionState.connected,
      );

      final c = connection();
      expect(c.source, BugCapsuleConnectionSource.token);
      expect(c.apiUrl, backend.api);
      expect(c.configFetchedAt, isNotNull);
      expect(c.firstCapsuleAcceptedAt, isNull);
      expect(c.firstEventAcceptedAt, isNull);
      expect(backend.seen.first, (
        method: 'GET',
        path: '/v1/sdk/config',
        auth: 'Bearer $key',
      ));

      BugCapsule.fail('checkout.total');
      final r = (await BugCapsule.capture())!;
      expect(r.upload!.status, UploadStatus.uploaded);
      expect(
        backend.seen,
        contains((method: 'POST', path: '/v1/capsules', auth: 'Bearer $key')),
      );
      expect(connection().firstCapsuleAcceptedAt, isNotNull);

      expect(
        BugCapsule.captureException(StateError('price is null')),
        isNotNull,
      );
      expect(await BugCapsule.flush(const Duration(seconds: 5)), isTrue);
      expect(
        backend.seen,
        contains((method: 'POST', path: '/v1/envelope', auth: 'Bearer $key')),
      );
      expect(connection().firstEventAcceptedAt, isNotNull);

      // Basic connectivity is not complete replay instrumentation.
      final i = BugCapsule.status.instrumentation;
      expect(i.recording, isTrue);
      expect(i.missing, ['network', 'navigation', 'app_state']);
      expect(
        BugCapsule.status.toJson(),
        containsPair('connection', containsPair('state', 'connected')),
      );
      // A capture path may include the test directory 'bugcapsule-token-'.
      // Check actual credentials rather than that incidental word.
      expect(
        logs.where((l) => l.contains(tokenFor(backend.api)) || l.contains(key)),
        isEmpty,
      );
      // App version and build have defaults when only the token is given.
      expect(r.file.existsSync(), isTrue);
      final capsule = CapsuleCodec.decode(await r.file.readAsBytes());
      expect(capsule.manifest.app.version, 'unknown');
      expect(capsule.manifest.app.build, '0');
    },
  );

  test(
    'instrumentation reports the replay integrations that are set up',
    () async {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: dir,
      );
      var ran = false;
      await BugCapsule.init(
        config: BugCapsuleConfig(
          token: tokenFor(backend.api),
          mode: CaptureMode.qa,
        ),
        integrations: [BugCapsuleGoRouter(), BugCapsuleNotifiers()],
        appRunner: () => ran = true,
      );
      expect(ran, isTrue);
      final i = BugCapsule.status.instrumentation;
      expect(i.navigation, isTrue);
      expect(i.appState, isTrue);
      expect(i.network, isFalse);
      expect(i.missing, ['network']);
      expect(i.integrations, ['go_router', 'notifier']);
    },
  );

  test(
    'explicit url + ingest key keeps working and wins over a token',
    () async {
      final legacy = 'bci_${'k' * 43}';
      expect(
        await init(
          BugCapsuleConfig(
            appVersion: '1.0.0',
            appBuild: '1',
            mode: CaptureMode.qa,
            token: tokenFor('${backend.api}/elsewhere'),
            backend: BugCapsuleBackendConfig(
              url: '${backend.api}/',
              ingestKey: legacy,
            ),
          ),
        ),
        isTrue,
      );
      await until(
        () => connection().state == BugCapsuleConnectionState.connected,
      );
      expect(backend.seen.first, (
        method: 'GET',
        path: '/v1/sdk/config',
        auth: 'Bearer $legacy',
      ));
      expect(connection().source, BugCapsuleConnectionSource.backend);
      expect(connection().apiUrl, backend.api);
      expect(logs.join('\n'), contains('ignoring token'));
    },
  );

  test(
    'an invalid or unsupported token never throws or blocks; the app runs without a backend',
    () async {
      for (final (token, state) in [
        ('bcsdk.v1.not-json', BugCapsuleConnectionState.invalidToken),
        ('bci_${'x' * 43}', BugCapsuleConnectionState.invalidToken),
        ('', BugCapsuleConnectionState.invalidToken),
        ('bcsdk.v2.e30', BugCapsuleConnectionState.unsupportedTokenVersion),
      ]) {
        BugCapsule.debugOverrides = BugCapsuleTestOverrides(
          storageDirectory: dir,
        );
        logs.clear();
        expect(
          await init(BugCapsuleConfig(token: token, mode: CaptureMode.qa)),
          isTrue,
        );
        final c = connection();
        expect(c.state, state, reason: token);
        expect(c.reason, state.code);
        expect(c.message, isNotEmpty);
        expect(c.source, BugCapsuleConnectionSource.token);
        expect(c.apiUrl, isNull);
        // Local capture still works; nothing is uploaded.
        BugCapsule.fail('still.fine');
        final r = await BugCapsule.capture();
        expect(r!.upload, isNull);
        expect(
          logs.where(
            (l) => l.startsWith("[bugcapsule] the SDK token can't be used"),
          ),
          hasLength(1),
        );
        await BugCapsule.resetForTest();
      }
      expect(backend.seen, isEmpty);
    },
  );

  test(
    'a revoked token (401 + reason) stops capture and uploads with the backend’s detail, logged once',
    () async {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: dir,
      );
      backend.answer = Answer.revoked;
      expect(
        await init(
          BugCapsuleConfig(token: tokenFor(backend.api), mode: CaptureMode.qa),
        ),
        isTrue,
      );
      await until(
        () => connection().state == BugCapsuleConnectionState.rejected,
      );
      final c = connection();
      expect(c.reason, 'token_revoked');
      expect(c.message, contains('generate a new token'));
      expect(c.configFetchedAt, isNull);
      expect(BugCapsule.isRecording, isFalse);
      expect(await BugCapsule.capture(), isNull);

      await BugCapsule.refreshRemoteConfig();
      await BugCapsule.flushUploads();
      final refused = logs
          .where((l) => l.contains("refused this app's SDK token"))
          .toList();
      expect(refused, hasLength(1));
      expect(
        refused.single,
        contains('(token_revoked): this SDK token was revoked'),
      );
      expect(backend.seen.where((s) => s.path == '/v1/capsules'), isEmpty);
    },
  );

  test('a hanging backend never blocks start-up', () async {
    backend.answer = Answer.hang;
    final sw = Stopwatch()..start();
    expect(
      await init(
        BugCapsuleConfig(token: tokenFor(backend.api), mode: CaptureMode.qa),
      ),
      isTrue,
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect(connection().state, BugCapsuleConnectionState.connecting);
    BugCapsule.fail('still.fine');
    expect(BugCapsule.isRecording, isTrue);
  });

  test(
    'offline: no crash, the capsule waits in the outbox and goes out when the backend is back',
    () async {
      backend.answer = Answer.down;
      expect(
        await init(
          BugCapsuleConfig(token: tokenFor(backend.api), mode: CaptureMode.qa),
        ),
        isTrue,
      );
      await until(
        () => connection().state == BugCapsuleConnectionState.offline,
      );
      expect(connection().message, contains('could not be reached'));

      BugCapsule.fail('while.offline');
      final r = (await BugCapsule.capture())!;
      expect(r.upload!.status, UploadStatus.retryLater);
      expect(await queued(), 1);
      await BugCapsule.flushUploads();
      expect(await queued(), 1);

      backend.answer = Answer.unavailable;
      await BugCapsule.refreshRemoteConfig();
      expect(connection().state, BugCapsuleConnectionState.offline);
      expect(connection().reason, 'HTTP 503');
      expect(await queued(), 1);

      backend.answer = Answer.ok;
      await BugCapsule.refreshRemoteConfig();
      await BugCapsule.flushUploads();
      expect(connection().state, BugCapsuleConnectionState.connected);
      expect(await queued(), 0);
      expect(connection().firstCapsuleAcceptedAt, isNotNull);
      expect(
        backend.seen.where(
          (s) => s.path == '/v1/capsules' && s.auth == 'Bearer $key',
        ),
        hasLength(1),
      );
    },
  );

  group('config fetch problem body', () {
    test('a 401 carries the backend’s reason and detail', () async {
      backend.answer = Answer.revoked;
      final r = await BugCapsuleBackendClient(
        BugCapsuleBackendConfig(url: backend.api, ingestKey: key),
      ).fetchConfig();
      final f = r as ConfigFetchFailed;
      expect(f.status, 401);
      expect(f.unauthorized, isTrue);
      expect(f.reason, 'token_revoked');
      expect(f.detail, contains('generate a new token'));
    });

    test(
      'a refusal without a problem body and a network error still work',
      () async {
        backend.answer = Answer.unavailable;
        final client = BugCapsuleBackendClient(
          BugCapsuleBackendConfig(url: backend.api, ingestKey: key),
        );
        final unavailable = await client.fetchConfig() as ConfigFetchFailed;
        expect(
          (unavailable.status, unavailable.reason, unavailable.transient),
          (503, null, true),
        );
        backend.answer = Answer.down;
        final down = await client.fetchConfig() as ConfigFetchFailed;
        expect((down.status, down.transient), (null, true));
      },
    );
  });
}
