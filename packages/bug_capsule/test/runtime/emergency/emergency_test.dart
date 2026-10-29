import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/emergency/emergency.dart';
import 'package:bug_capsule/src/runtime/emergency/transport.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'signing.dart';

/// `BugCapsule.emergency`: startup, the persisted cache and installation
/// id, inactive states, replay and lifecycle, with a scripted transport and
/// real files.

const _backend = BugCapsuleBackendConfig(
  url: 'http://backend.test',
  ingestKey: 'bct_test',
);
const _key = 'checkout.confirm_order';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late TestSigner signer;
  late FakeTransport transport;
  late FakeHost host;
  late DateTime clock;
  late List<String> logs;
  final originalDebugPrint = debugPrint;
  final facades = <BugCapsuleEmergency>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bugcapsule-emergency-');
    signer = TestSigner.generate();
    // Fetches a test does not script answer "not modified".
    transport = FakeTransport()..otherwise = () => const EmergencyNotModified();
    host = FakeHost(backend: _backend);
    clock = DateTime.utc(2026, 10, 29, 8, 30);
    logs = [];
    debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
  });

  tearDown(() async {
    for (final f in facades) {
      await f.resetForTest();
    }
    facades.clear();
    debugPrint = originalDebugPrint;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  BugCapsuleEmergency facade({EmergencyPlatform? Function()? platform}) {
    final f = BugCapsuleEmergency.internal(host)
      ..debugOverrides = EmergencyTestOverrides(
        storageDirectory: dir,
        platform: platform ?? () => EmergencyPlatform.flutterIos,
        now: () => clock,
        random: MidRandom(),
        transport: transport,
      );
    facades.add(f);
    return f;
  }

  Future<void> restart(BugCapsuleEmergency f) async {
    await f.debugEngine?.flush();
    await f.resetForTest();
    facades.remove(f);
  }

  Map<String, Object?> doc({
    int revision = 5,
    List<Map<String, Object?>>? policies,
    String app = TestSigner.appId,
    TestSigner? by,
  }) => (by ?? signer).document(
    revision: revision,
    issuedAt: DateTime.utc(2026, 10, 29, 8),
    expiresAt: DateTime.utc(2026, 10, 29, 9),
    policies: policies,
    app: app,
  );

  EmergencyFetched served(Map<String, Object?> d, {TestSigner? by}) =>
      EmergencyFetched((by ?? signer).envelope(d), '"etag"');

  File cacheFile() => File('${dir.path}/emergency/policies-production.json');

  group('before initialize', () {
    test('every call answers with the failure mode and never throws', () async {
      final f = facade();
      final d = f.evaluate(_key);
      expect(d.allowed, isTrue);
      expect(d.action, EmergencyAction.allow);
      expect(d.reasonCode, 'POLICY_UNAVAILABLE');
      expect(d.source, EmergencyDecisionSource.failureMode);
      expect(f.isFeatureAllowed(_key), isTrue);
      expect(f.getPolicy(_key), isNull);
      expect(f.status.initialized, isFalse);
      expect(f.status.active, isFalse);
      expect(f.status.state, EmergencyDocumentState.none);
      expect(f.snapshot.document, isNull);
      await f.refreshPolicies();
      expect(transport.fetches, 0);
    });

    test('BugCapsule.emergency is usable without BugCapsule.init', () async {
      expect(BugCapsule.isInitialized, isFalse);
      final d = BugCapsule.emergency.evaluate(_key);
      expect(d.source, EmergencyDecisionSource.failureMode);
      expect(BugCapsule.emergency.isFeatureAllowed(_key), isTrue);
      expect(BugCapsule.emergency.status.initialized, isFalse);
      await BugCapsule.emergency.refreshPolicies();
    });
  });

  group('startup', () {
    test('initialize does not wait for the network', () async {
      final gate = Completer<EmergencyFetchResult>();
      transport.script.add(() => gate.future);
      final f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      expect(transport.fetches, 1, reason: 'fetch started in the background');
      expect(f.status.active, isTrue);
      expect(f.evaluate(_key).source, EmergencyDecisionSource.failureMode);
      final next = f.changes.first;
      gate.complete(served(doc()));
      await f.refreshPolicies();
      expect((await next).revision, 5);
      expect(f.evaluate(_key).action, EmergencyAction.block);
      expect(f.getPolicy(_key)?.policyId, 'p-1');
      expect(f.isFeatureAllowed(_key), isFalse);
      expect(f.isFeatureAllowed('search.query'), isTrue);
    });

    test('a second initialize is ignored', () async {
      final f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.initialize(
        const EmergencyConfig(trustAnchor: 'bcek.v1.x', environment: 'other'),
      );
      expect(f.status.active, isTrue);
      expect(f.status.environment, 'production');
      expect(logs.join('\n'), contains('initialize was called again'));
    });

    test('the refresh interval is at least 15 s', () {
      expect(
        const EmergencyConfig(
          trustAnchor: 'x',
          refreshInterval: Duration(seconds: 1),
        ).effectiveRefreshInterval,
        const Duration(seconds: 15),
      );
      expect(
        const EmergencyConfig(trustAnchor: 'x').effectiveRefreshInterval,
        const Duration(seconds: 60),
      );
    });
  });

  group('persistence', () {
    test(
      'the cache is persisted, re-verified on restart and used offline',
      () async {
        transport.answer(served(doc(revision: 5)));
        var f = facade();
        await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
        await f.refreshPolicies();
        expect(f.evaluate(_key).action, EmergencyAction.block);
        await restart(f);

        final cached = jsonDecode(await cacheFile().readAsString()) as Map;
        expect(cached['application_id'], TestSigner.appId);
        expect(cached['highest_revision'], 5);
        expect(cached['etag'], '"etag"');
        expect(cached['envelope'], isA<Map<Object?, Object?>>());
        expect(cached['received_at'], clock.millisecondsSinceEpoch);
        expect(
          dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.tmp')),
          isEmpty,
        );

        // Offline restart: the cached document decides as soon as
        // initialize returns.
        transport.otherwise = () =>
            const EmergencyFetchFailed('network_error', 'offline');
        f = facade();
        await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
        final d = f.evaluate(_key);
        expect(d.action, EmergencyAction.block);
        expect(d.source, EmergencyDecisionSource.policy);
        expect(d.documentRevision, 5);
        expect(f.status.revision, 5);
        expect(f.status.receivedAt, clock);
        expect(f.snapshot.revision, 5);
        // The next fetch revalidates with the stored ETag.
        await f.refreshPolicies();
        expect(transport.requests.last.etag, '"etag"');
        expect(f.status.lastError?.code, 'network_error');
        expect(f.evaluate(_key).action, EmergencyAction.block);
      },
    );

    test('the highest revision survives restarts (no replay of older '
        'documents)', () async {
      transport.answer(served(doc(revision: 5)));
      var f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      await restart(f);

      transport.otherwise = () =>
          served(doc(revision: 4, policies: [signer.policy(action: 'ALLOW')]));
      f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      expect(f.status.revision, 5);
      expect(f.status.lastError?.code, 'stale_revision');
    });

    test('a cache that no longer verifies is discarded, keeping the highest '
        'revision', () async {
      transport.answer(served(doc(revision: 5)));
      var f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      await restart(f);

      // The app ships a new anchor with only another key.
      final other = TestSigner.generate(kid: 'ek_other');
      transport.otherwise = () =>
          served(doc(revision: 4, by: other), by: other);
      f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: other.anchor()));
      expect(f.status.state, EmergencyDocumentState.none);
      expect(f.evaluate(_key).source, EmergencyDecisionSource.failureMode);
      expect(logs.join('\n'), contains('discarding cached policies'));
      await f.refreshPolicies();
      expect(f.status.lastError?.code, 'stale_revision');
      await f.debugEngine!.flush();
      final cached = jsonDecode(await cacheFile().readAsString()) as Map;
      expect(cached['envelope'], isNull);
      expect(cached['highest_revision'], 5);

      transport.otherwise = () =>
          served(doc(revision: 6, by: other), by: other);
      await f.refreshPolicies();
      expect(f.status.revision, 6);
    });

    test(
      'a rotated anchor that still lists the old key keeps the cache',
      () async {
        transport.answer(served(doc(revision: 5)));
        var f = facade();
        await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
        await f.refreshPolicies();
        await restart(f);

        final next = TestSigner.generate(kid: 'ek_next');
        f = facade();
        await f.initialize(
          EmergencyConfig(trustAnchor: signer.anchor(others: [next])),
        );
        expect(f.status.revision, 5);
      },
    );

    test('a cache written for another application starts over', () async {
      transport.answer(served(doc(revision: 5)));
      var f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      await restart(f);

      const otherApp = '16fd2706-8baf-433b-82eb-8c7fada847da';
      transport.otherwise = () => served(doc(revision: 1, app: otherApp));
      f = facade();
      await f.initialize(
        EmergencyConfig(trustAnchor: signer.anchor(app: otherApp)),
      );
      expect(f.status.state, EmergencyDocumentState.none);
      await f.refreshPolicies();
      expect(f.status.revision, 1, reason: 'revision 1 is not stale there');
    });

    test('an unreadable cache file is ignored', () async {
      await Directory('${dir.path}/emergency').create(recursive: true);
      await cacheFile().writeAsString('{not json');
      transport.answer(served(doc(revision: 2)));
      final f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      expect(f.status.revision, 2);
    });

    test('each environment has its own cache', () async {
      transport.answer(served(doc(revision: 5)));
      var f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      await restart(f);

      f = facade();
      await f.initialize(
        EmergencyConfig(trustAnchor: signer.anchor(), environment: 'staging'),
      );
      expect(f.status.state, EmergencyDocumentState.none);
      expect(transport.requests.last.environment, 'staging');
    });

    test('the installation id persists apart from the cache and is the '
        'default subject', () async {
      final f1 = facade();
      await f1.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      final idFile = File('${dir.path}/emergency/installation_id');
      final id = (await idFile.readAsString()).trim();
      expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      await restart(f1);

      // Half rollout: with no subject the installation id decides.
      final policies = [signer.policy(rolloutBp: 5000)];
      transport.otherwise = () => served(doc(revision: 3, policies: policies));
      final f2 = facade();
      await f2.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f2.refreshPolicies();
      expect((await idFile.readAsString()).trim(), id);
      expect(f2.evaluate(_key).action, f2.evaluate(_key, subject: id).action);
      // Some subjects are in, some are not.
      final actions = {
        for (var i = 0; i < 40; i++) f2.evaluate(_key, subject: 'u$i').action,
      };
      expect(actions, {EmergencyAction.block, EmergencyAction.allow});
    });
  });

  group('inactive', () {
    test(
      'an invalid anchor: failure modes apply, nothing is fetched',
      () async {
        final f = facade();
        await f.initialize(
          const EmergencyConfig(
            trustAnchor: 'bcek.v1.garbage',
            failureModes: {'checkout.*': EmergencyFailureMode.failClosed},
          ),
        );
        expect(f.status.active, isFalse);
        expect(f.status.initialized, isTrue);
        expect(f.status.inactiveReason, 'invalid_anchor');
        expect(f.evaluate(_key).action, EmergencyAction.block);
        expect(f.evaluate(_key).source, EmergencyDecisionSource.failureMode);
        expect(f.evaluate('search.query').allowed, isTrue);
        await f.refreshPolicies();
        expect(transport.fetches, 0);
        expect(
          logs.where((l) => l.contains('trust anchor is invalid')),
          hasLength(1),
        );
      },
    );

    test('an invalid environment', () async {
      final f = facade();
      await f.initialize(
        EmergencyConfig(trustAnchor: signer.anchor(), environment: 'Prod!'),
      );
      expect(f.status.inactiveReason, 'invalid_environment');
      expect(transport.fetches, 0);
    });

    test(
      'an unsupported platform stays in failure mode and logs once',
      () async {
        final f = facade(platform: () => null);
        await f.initialize(
          EmergencyConfig(
            trustAnchor: signer.anchor(),
            failureModes: const {_key: EmergencyFailureMode.failClosed},
          ),
        );
        expect(f.status.inactiveReason, 'unsupported_platform');
        expect(f.evaluate(_key).action, EmergencyAction.block);
        expect(f.evaluate('a.b').action, EmergencyAction.allow);
        await f.refreshPolicies();
        expect(transport.fetches, 0);
        expect(
          logs.where((l) => l.contains('Android and iOS only')),
          hasLength(1),
        );
      },
    );

    test('the host platform is detected from the OS', () async {
      final f = BugCapsuleEmergency.internal(host)
        ..debugOverrides = EmergencyTestOverrides(
          storageDirectory: dir,
          transport: transport,
        );
      facades.add(f);
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      // Tests run on a desktop host.
      expect(f.status.inactiveReason, 'unsupported_platform');
    });
  });

  group('replay', () {
    test(
      'while replaying: ALLOW from replay, no network, no receipts',
      () async {
        host.isReplaying = true;
        transport.otherwise = () => served(doc());
        final f = facade();
        await f.initialize(
          EmergencyConfig(
            trustAnchor: signer.anchor(),
            failureModes: const {_key: EmergencyFailureMode.failClosed},
          ),
        );
        final d = f.evaluate(_key);
        expect(d.allowed, isTrue);
        expect(d.source, EmergencyDecisionSource.replay);
        expect(f.status.inactiveReason, 'replay');
        await f.refreshPolicies();
        expect(transport.fetches, 0);
        expect(transport.receipts, isEmpty);
      },
    );

    test('a replay that starts later overrides the document', () async {
      transport.answer(served(doc()));
      final f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      expect(f.evaluate(_key).action, EmergencyAction.block);
      final fetches = transport.fetches;
      final receipts = transport.receipts.length;
      host.isReplaying = true;
      expect(f.evaluate(_key).source, EmergencyDecisionSource.replay);
      await f.refreshPolicies();
      expect(transport.fetches, fetches);
      expect(transport.receipts.length, receipts);
    });
  });

  group('connection', () {
    test('uses the BugCapsule connection by default', () async {
      transport.answer(served(doc()));
      final f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      expect(transport.requests.first.backend, same(_backend));
      expect(transport.requests.first.appVersion, '2.4.1');
    });

    test('an explicit backend or token wins', () async {
      const mine = BugCapsuleBackendConfig(url: 'http://mine', ingestKey: 'k');
      final f = facade();
      await f.initialize(
        EmergencyConfig(
          trustAnchor: signer.anchor(),
          backend: mine,
          appVersion: '9.9.9',
        ),
      );
      await f.refreshPolicies();
      expect(transport.requests.last.backend, same(mine));
      expect(transport.requests.last.appVersion, '9.9.9');
      await restart(f);

      final token =
          'bcsdk.v1.${base64Url.encode(utf8.encode(jsonEncode({'api': 'http://tok.example', 'key': 'bct_tok0123456789abcdef'}))).replaceAll('=', '')}';
      final g = facade();
      await g.initialize(
        EmergencyConfig(trustAnchor: signer.anchor(), token: token),
      );
      await g.refreshPolicies();
      expect(transport.requests.last.backend.url, 'http://tok.example');
      expect(
        transport.requests.last.backend.ingestKey,
        'bct_tok0123456789abcdef',
      );
    });

    test('without any connection: not_connected, nothing fetched', () async {
      host.backend = null;
      final f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      expect(transport.fetches, 0);
      expect(f.status.lastError?.code, 'not_connected');
      // BugCapsule.init provides one later.
      host.backend = _backend;
      transport.answer(served(doc()));
      f.runtimeAttached();
      await f.refreshPolicies();
      expect(transport.fetches, greaterThanOrEqualTo(1));
      expect(f.status.revision, 5);
    });
  });

  group('observation and lifecycle', () {
    test('an observer that throws does not affect the module', () async {
      final errors = <Object>[];
      final f = facade();
      transport.answer(served(doc()));
      await runZonedGuarded(() async {
        f.changes.listen((_) => throw StateError('observer bug'));
        await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
        await f.refreshPolicies();
        await pumpEventQueue();
      }, (e, _) => errors.add(e));
      expect(errors, isNotEmpty);
      expect(f.status.revision, 5);
      expect(f.evaluate(_key).action, EmergencyAction.block);
    });

    test('app lifecycle pauses timers and resume refreshes', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      transport.otherwise = () => const EmergencyNotModified();
      transport.answer(served(doc()));
      final f = facade();
      await f.initialize(EmergencyConfig(trustAnchor: signer.anchor()));
      await f.refreshPolicies();
      final before = transport.fetches;
      expect(f.debugEngine!.nextFetchAt, isNotNull);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(
        f.debugEngine!.nextFetchAt,
        isNull,
        reason: 'no timer in background',
      );

      clock = clock.add(const Duration(minutes: 10));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(transport.fetches, before + 1);
      expect(f.debugEngine!.nextFetchAt, isNotNull);
    });
  });
}
