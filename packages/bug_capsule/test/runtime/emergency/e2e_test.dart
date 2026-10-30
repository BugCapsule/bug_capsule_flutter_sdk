import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/emergency/emergency.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opt-in end-to-end check against a real BugCapsule backend. Runs only
/// when BUGCAPSULE_EMERGENCY_E2E_URL is set, with:
///
/// * BUGCAPSULE_EMERGENCY_E2E_KEY: the project's SDK ingest key (bct_/bci_)
/// * BUGCAPSULE_EMERGENCY_E2E_ANCHOR: the project's trust anchor (bcek.v1.…)
/// * BUGCAPSULE_EMERGENCY_E2E_ENV: the environment (default `production`)
/// * BUGCAPSULE_EMERGENCY_E2E_FEATURE: the feature key to evaluate
/// * BUGCAPSULE_EMERGENCY_E2E_EXPECT_ACTION: the expected action (`BLOCK`, …)
/// * BUGCAPSULE_EMERGENCY_E2E_PLATFORM: optional, `FLUTTER_ANDROID` (default)
///   or `FLUTTER_IOS`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final env = Platform.environment;
  final url = env['BUGCAPSULE_EMERGENCY_E2E_URL'];

  test(
    'fetches, verifies and evaluates a real policy document',
    () async {
      String required(String name) {
        final v = env[name];
        if (v == null || v.isEmpty) fail('$name is not set');
        return v;
      }

      final key = required('BUGCAPSULE_EMERGENCY_E2E_KEY');
      final anchor = required('BUGCAPSULE_EMERGENCY_E2E_ANCHOR');
      final feature = required('BUGCAPSULE_EMERGENCY_E2E_FEATURE');
      final expected = required('BUGCAPSULE_EMERGENCY_E2E_EXPECT_ACTION');
      final environment = env['BUGCAPSULE_EMERGENCY_E2E_ENV'] ?? 'production';
      final platform = EmergencyPlatform.values.firstWhere(
        (p) =>
            p.wire ==
            (env['BUGCAPSULE_EMERGENCY_E2E_PLATFORM'] ?? 'FLUTTER_ANDROID'),
      );
      final dir = await Directory.systemTemp.createTemp('bugcapsule-e2e-');
      addTearDown(() async {
        await BugCapsule.resetForTest();
        BugCapsule.emergency.debugOverrides = null;
        await dir.delete(recursive: true);
      });
      BugCapsule.emergency.debugOverrides = EmergencyTestOverrides(
        storageDirectory: dir,
        platform: () => platform,
      );

      await BugCapsule.emergency.initialize(
        EmergencyConfig(
          trustAnchor: anchor,
          environment: environment,
          backend: BugCapsuleBackendConfig(url: url!, ingestKey: key),
        ),
      );
      await BugCapsule.emergency.refreshPolicies();

      final status = BugCapsule.emergency.status;
      expect(status.active, isTrue, reason: '$status');
      expect(status.lastError, isNull, reason: '$status');
      expect(status.state, EmergencyDocumentState.usable, reason: '$status');
      final decision = BugCapsule.emergency.evaluate(feature);
      expect(decision.source, EmergencyDecisionSource.policy);
      expect(decision.action.wire, expected, reason: '$decision');
    },
    skip: url == null || url.isEmpty
        ? 'set BUGCAPSULE_EMERGENCY_E2E_URL (and _KEY, _ANCHOR, _FEATURE, '
              '_EXPECT_ACTION) to run against a real backend'
        : false,
  );
}
