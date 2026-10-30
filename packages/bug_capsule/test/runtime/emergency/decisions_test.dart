import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/actions.dart';
import 'package:bug_capsule/src/runtime/emergency/decisions.dart';
import 'package:bug_capsule/src/runtime/emergency/emergency.dart';
import 'package:bug_capsule/src/runtime/emergency/transport.dart';
import 'package:bug_capsule/src/runtime/replay_engine.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'signing.dart';

/// §7.8: decisions recorded into capsules, through the real runtime, and
/// served back to the guard in replay.

const _key = 'checkout.confirm_order';

const _block = EmergencyDecision(
  featureKey: _key,
  allowed: false,
  action: EmergencyAction.block,
  source: EmergencyDecisionSource.policy,
  reasonCode: 'INCIDENT',
  documentRevision: 42,
);

/// The guarded path: the bug only exists while the feature is blocked.
void pay(
  BugCapsuleEmergency guard,
  void Function(Object, StackTrace) onFailure,
) {
  try {
    if (!guard.evaluate(_key).allowed) throw StateError('blocked path crashes');
  } catch (e, st) {
    onFailure(e, st);
  }
}

class _Transport implements BugCapsuleTransport {
  List<String>? redactKeys;

  @override
  Future<ConfigFetchResult> fetchConfig() async {
    final keys = redactKeys;
    if (keys == null) return const ConfigFetchFailed('offline');
    return ConfigFetched(
      RemoteCaptureConfig(
        enabled: true,
        sampleRate: 1,
        maxCapsuleBytes: 5 * 1024 * 1024,
        captureNetworkBodies: true,
        redactKeys: keys,
        configTtlSeconds: 300,
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<UploadResult> upload(List<int> bytes) async =>
      UploadResult(UploadStatus.uploaded, serverId: 'srv');
  @override
  void close() {}
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shared vectors', () {
    final vectors =
        jsonDecode(
              File(
                '../../spec/fixtures/emergency-v1/replay-decisions.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;

    test('subject tags', () {
      for (final c
          in (vectors['subjectTags'] as List).cast<Map<String, Object?>>()) {
        expect(emergencySubjectTag(c['subject'] as String), c['tag']);
      }
    });

    test('lookups', () {
      final events = [
        for (final e
            in (vectors['events'] as List).cast<Map<String, Object?>>())
          BugCapsuleEvent.fromJson(e),
      ];
      final script = EmergencyDecisionScript(events);
      for (final c in (vectors['cases'] as List).cast<Map<String, Object?>>()) {
        final subject = c['subject'] as String?;
        final got = script.lookup(
          c['key'] as String,
          subject == null ? null : emergencySubjectTag(subject),
          c['t'] as int,
        );
        final expected = c['expect'] as Map<String, Object?>?;
        if (expected == null) {
          expect(got, isNull, reason: c['name'] as String);
          continue;
        }
        expect(got, isNotNull, reason: c['name'] as String);
        final json = got!.toJson();
        const fields = {
          'allowed': 'allowed',
          'action': 'action',
          'reasonCode': 'reason_code',
          'policyId': 'policy_id',
          'policyRevision': 'policy_revision',
          'documentRevision': 'document_revision',
          'message': 'public_user_message',
          'requiredVersion': 'required_version',
          'fallback': 'fallback',
          'fallbackAvailable': 'fallback_available',
        };
        for (final e in expected.entries) {
          expect(json[fields[e.key]], e.value, reason: '${c['name']} ${e.key}');
        }
        expect(got.source, EmergencyDecisionSource.replay);
      }
    });
  });

  group('tracker', () {
    test('writes a decision only when it changes', () {
      final t = EmergencyDecisionTracker();
      expect(t.track(_block, null), isNotNull);
      expect(t.track(_block, null), isNull);
      const next = EmergencyDecision(
        featureKey: _key,
        allowed: false,
        action: EmergencyAction.block,
        source: EmergencyDecisionSource.policy,
        reasonCode: 'INCIDENT',
        documentRevision: 43,
      );
      expect(t.track(next, null)?['documentRevision'], 43);
      expect(t.current, hasLength(1));
    });

    test('subjects are tracked apart and never written', () {
      final t = EmergencyDecisionTracker();
      final a = t.track(_block, 'user-1')!;
      expect(a['subject'], '748982dd71b97baf');
      expect(jsonEncode(a), isNot(contains('user-1')));
      expect(t.track(_block, 'user-2'), isNotNull);
      expect(t.track(_block, 'user-1'), isNull);
      expect(t.current, hasLength(2));
    });

    test('past the limit the recording says it is incomplete', () {
      final t = EmergencyDecisionTracker(maxPairs: 1);
      expect(t.track(_block, 'user-1'), isNotNull);
      expect(t.complete, isTrue);
      expect(t.track(_block, 'user-2'), isNull);
      expect(t.complete, isFalse);
    });
  });

  group('facade', () {
    test('replay returns the recorded decision and stays offline', () async {
      final host = FakeHost()..isReplaying = true;
      String? asked;
      host.replay = (key, tag) {
        asked = tag;
        return _block;
      };
      final f = BugCapsuleEmergency.internal(host);
      expect(f.evaluate(_key, subject: 'user-1').action, EmergencyAction.block);
      expect(asked, '748982dd71b97baf');
      expect(host.recorded, isEmpty);
      await f.resetForTest();
    });

    test('a failing recording never changes the decision', () async {
      final f = BugCapsuleEmergency.internal(_ThrowingHost());
      expect(f.evaluate(_key).allowed, isTrue);
      await f.resetForTest();
    });
  });

  group('capture', () {
    late Directory dir;
    late TestSigner signer;
    late _Transport transport;
    final originalDebugPrint = debugPrint;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bugcapsule-decisions-');
      signer = TestSigner.generate();
      transport = _Transport();
      debugPrint = (String? message, {int? wrapWidth}) {};
    });

    tearDown(() async {
      await BugCapsule.resetForTest();
      BugCapsule.debugOverrides = null;
      debugPrint = originalDebugPrint;
      await dir.delete(recursive: true);
    });

    /// A real policy document blocking [_key], fetched and verified.
    Future<void> guard() async {
      final clock = DateTime.now().toUtc();
      final doc = signer.document(
        revision: 5,
        issuedAt: clock,
        expiresAt: clock.add(const Duration(hours: 1)),
        policies: [signer.policy()],
      );
      final transport = FakeTransport()
        ..otherwise = (() => EmergencyFetched(signer.envelope(doc), '"e"'));
      BugCapsule.emergency.debugOverrides = EmergencyTestOverrides(
        storageDirectory: dir,
        platform: () => EmergencyPlatform.flutterIos,
        transport: transport,
      );
      await BugCapsule.emergency.initialize(
        EmergencyConfig(
          trustAnchor: signer.anchor(),
          backend: const BugCapsuleBackendConfig(
            url: 'http://backend.test',
            ingestKey: 'bct_test',
          ),
        ),
      );
      await BugCapsule.emergency.refreshPolicies();
    }

    Future<void> start({
      Duration checkpointInterval = const Duration(seconds: 30),
      int maxEvents = 20000,
      Map<String, Object?>? Function(String, Map<String, Object?>)? hook,
    }) async {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: dir,
        transport: transport,
      );
      await BugCapsule.init(
        config: BugCapsuleConfig(
          appVersion: '1.0.0',
          backend: const BugCapsuleBackendConfig(
            url: 'https://bugcapsule.test',
            ingestKey: 'bci_test',
          ),
          appBuild: '1',
          mode: CaptureMode.qa,
          gitSha: 'abc123',
          autoCaptureOnFailure: false,
          checkpointInterval: checkpointInterval,
          maxEvents: maxEvents,
          beforeRecord: hook,
        ),
        appRunner: () {},
      );
      await settle();
    }

    Future<Capsule> captured() async {
      final r = (await BugCapsule.capture())!;
      return CapsuleCodec.decode(await r.file.readAsBytes());
    }

    List<BugCapsuleEvent> decisions(Capsule c) =>
        c.eventsOfType(EventTypes.emergencyDecision).toList();

    test('a blocked feature is in the capsule, once', () async {
      await guard();
      await start();
      for (var i = 0; i < 50; i++) {
        BugCapsule.emergency.evaluate(_key);
      }
      final c = await captured();
      final d = decisions(c).single.data;
      expect(d['key'], _key);
      expect(d['action'], 'BLOCK');
      expect(d['documentRevision'], 5);
      expect(d['source'], 'policy');
      expect(
        c.manifest.capabilities[emergencyDecisionsCapability],
        'supported',
      );
    });

    test('a decision made before recording started is written', () async {
      await guard();
      BugCapsule.emergency.evaluate(_key);
      await start();
      expect(decisions(await captured()).single.data['action'], 'BLOCK');
    });

    test('a window that starts at a periodic checkpoint knows it', () async {
      await guard();
      await start(
        checkpointInterval: const Duration(milliseconds: 20),
        maxEvents: 50,
      );
      BugCapsule.emergency.evaluate(_key);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      for (var i = 0; i < 200; i++) {
        BugCapsule.log('filler $i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final c = await captured();
      expect(c.checkpoint.kind, CheckpointKind.periodic);
      expect(decisions(c).first.data['action'], 'BLOCK');
    });

    test('a decision the app drops makes the capsule partial', () async {
      await guard();
      await start(
        hook: (type, data) =>
            type == EventTypes.emergencyDecision ? null : data,
      );
      BugCapsule.emergency.evaluate(_key);
      final c = await captured();
      expect(decisions(c), isEmpty);
      expect(c.manifest.capabilities[emergencyDecisionsCapability], 'partial');
    });

    test(
      'a decision whose key is redacted makes the capsule partial',
      () async {
        await guard();
        await start(hook: (type, data) => {...data, 'key': '[REDACTED]'});
        BugCapsule.emergency.evaluate(_key);
        final c = await captured();
        expect(decisions(c), isEmpty);
        expect(
          c.manifest.capabilities[emergencyDecisionsCapability],
          'partial',
        );
      },
    );

    test(
      'a remote rule on the key loses buffered decisions, and says so',
      () async {
        await guard();
        await start();
        BugCapsule.emergency.evaluate(_key);
        transport.redactKeys = ['key'];
        await BugCapsule.refreshRemoteConfig();
        final c = await captured();
        expect(decisions(c), isEmpty);
        expect(
          c.manifest.capabilities[emergencyDecisionsCapability],
          'partial',
        );
      },
    );

    test('a hook that changes the subject loses the decision', () async {
      await guard();
      await start(hook: (type, data) => {...data, 'subject': 'other'});
      BugCapsule.emergency.evaluate(_key, subject: 'user-1');
      final c = await captured();
      expect(decisions(c), isEmpty);
      expect(c.manifest.capabilities[emergencyDecisionsCapability], 'partial');
    });

    test('an app with no guards still says it recorded none', () async {
      await start();
      final c = await captured();
      expect(decisions(c), isEmpty);
      expect(
        c.manifest.capabilities[emergencyDecisionsCapability],
        'supported',
      );
    });
  });

  group('replay of a real capture', () {
    late Capsule capsule;

    Capsule withoutDecisions(Capsule c) => Capsule(
      manifest: c.manifest,
      checkpoint: c.checkpoint,
      events: [
        for (final e in c.events)
          if (e.type != EventTypes.emergencyDecision) e,
      ],
    );

    Future<ReplayReport> replay(WidgetTester tester, Capsule c) async {
      final report = await tester.runAsync(() async {
        final actions = ActionRegistry();
        final engine = ReplayEngine(
          capsule: c,
          settings: const ReplaySettings(settleTimeoutMs: 300),
          actions: actions,
          buildGitSha: null,
        );
        final host = FakeHost()
          ..isReplaying = true
          ..replay = engine.emergencyDecision;
        final guard = BugCapsuleEmergency.internal(host);
        actions.register('pay', (_) {
          pay(guard, (e, st) {
            engine.onFailure(FailureRecord.exception(e, st, 0));
          });
        });
        return engine.run();
      });
      return report!;
    }

    testWidgets('the blocked path reproduces only with its decision', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('bc-decisions-');
        final signer = TestSigner.generate();
        final now = DateTime.now().toUtc();
        final doc = signer.document(
          revision: 5,
          issuedAt: now,
          expiresAt: now.add(const Duration(hours: 1)),
          policies: [signer.policy()],
        );
        BugCapsule.emergency.debugOverrides = EmergencyTestOverrides(
          storageDirectory: dir,
          platform: () => EmergencyPlatform.flutterIos,
          transport: FakeTransport()
            ..otherwise = (() => EmergencyFetched(signer.envelope(doc), '"e"')),
        );
        await BugCapsule.emergency.initialize(
          EmergencyConfig(
            trustAnchor: signer.anchor(),
            backend: const BugCapsuleBackendConfig(
              url: 'http://backend.test',
              ingestKey: 'bct_test',
            ),
          ),
        );
        await BugCapsule.emergency.refreshPolicies();
        BugCapsule.debugOverrides = BugCapsuleTestOverrides(
          storageDirectory: dir,
          transport: _Transport(),
        );
        await BugCapsule.init(
          config: const BugCapsuleConfig(
            appVersion: '1.0.0',
            appBuild: '1',
            mode: CaptureMode.qa,
            gitSha: 'abc123',
            autoCaptureOnFailure: false,
          ),
          appRunner: () {},
        );
        await settle();
        BugCapsule.action('pay', () {
          pay(BugCapsule.emergency, BugCapsule.session!.reportError);
        })();
        final r = (await BugCapsule.capture())!;
        final raw = CapsuleCodec.decode(await r.file.readAsBytes());
        // No frame here, so no anchor: move the session after time zero.
        capsule = Capsule(
          manifest: raw.manifest,
          checkpoint: raw.checkpoint.shift(-100),
          events: [for (final e in raw.events) e.shift(-100)],
        );
        await BugCapsule.resetForTest();
        BugCapsule.debugOverrides = null;
        await dir.delete(recursive: true);
      });
      expect(capsule.manifest.failure, isNotNull);

      final faithful = await replay(tester, capsule);
      expect(
        faithful.outcome,
        ReplayOutcome.reproduced,
        reason: '${faithful.toJson()}',
      );
      // What every replay did before: all features allowed, bug not reached.
      final allowed = await replay(tester, withoutDecisions(capsule));
      expect(
        allowed.outcome,
        isNot(ReplayOutcome.reproduced),
        reason: '${allowed.toJson()}',
      );
    });
  });
}

class _ThrowingHost extends FakeHost {
  @override
  void recordDecision(Map<String, Object?> data) => throw StateError('nope');
}
