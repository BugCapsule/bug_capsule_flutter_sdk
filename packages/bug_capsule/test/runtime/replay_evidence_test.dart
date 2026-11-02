import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/actions.dart';
import 'package:bug_capsule/src/runtime/replay_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verdict v2 evidence (spec/verdict-v2.md): a clean replay says whether the
/// capsule's assertion ran and held, what the postconditions returned, and
/// whether replay got past the recorded failure point.
void main() {
  late Directory dir;
  late Capsule capsule;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('bc_evidence');
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(storageDirectory: dir);
    await BugCapsule.init(
      config: const BugCapsuleConfig(
        appVersion: '1.0.0',
        appBuild: '1',
        mode: CaptureMode.qa,
        gitSha: 'abc',
        autoCaptureOnFailure: false,
      ),
      appRunner: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // The capsule's failure is the assertion `cart.total`.
    BugCapsule.check('cart.total', false, 'total was negative');
    final r = (await BugCapsule.capture())!;
    capsule = CapsuleCodec.decode(await r.file.readAsBytes());
    await BugCapsule.resetForTest();
    BugCapsule.debugOverrides = null;
  });
  tearDownAll(() => dir.delete(recursive: true));

  ReplayEngine engine() => ReplayEngine(
    capsule: capsule,
    settings: const ReplaySettings(settleTimeoutMs: 100),
    actions: ActionRegistry(),
    buildGitSha: null,
  );

  test('the capsule fails on the cart.total assertion', () {
    expect(capsule.manifest.failure!.kind, FailureKind.assertion);
    expect(capsule.manifest.failure!.assertionId, 'cart.total');
  });

  test('a fixed app: assertion held and postconditions reported', () async {
    final e = engine()..postconditions = () => {'cart.total_positive': true};
    e.checkPassed('cart.total');
    final r = await e.run();
    expect(r.outcome, ReplayOutcome.notReproduced);
    expect(r.evidence!.assertionPassed, isTrue);
    expect(r.evidence!.postconditions, {'cart.total_positive': true});
    expect(r.evidence!.level, EvidenceLevel.strong);
    expect(
      ReplayReport.fromJson(r.toJson()).evidence!.level,
      EvidenceLevel.strong,
    );
  });

  test(
    'an app that never evaluates the assertion: at most weak evidence',
    () async {
      final r = await engine().run();
      expect(r.outcome, ReplayOutcome.notReproduced);
      expect(r.evidence!.assertionPassed, isNull);
      expect(r.evidence!.failurePointPassed, isTrue);
      expect(r.evidence!.level, EvidenceLevel.weak);
    },
  );

  test('a check of another assertion is not evidence for this one', () async {
    final e = engine()..checkPassed('profile.loaded');
    final r = await e.run();
    expect(r.evidence!.assertionPassed, isNull);
  });

  test('a postcondition that did not hold leaves no evidence', () async {
    final e = engine()..postconditions = () => {'cart.total_positive': false};
    e.checkPassed('cart.total');
    final r = await e.run();
    expect(r.evidence!.failedPostconditions, ['cart.total_positive']);
    expect(r.evidence!.level, EvidenceLevel.none);
  });

  test('a reproduction carries no fix evidence', () async {
    final e = engine()..checkPassed('cart.total');
    final run = e.run();
    e.onFailure(capsule.manifest.failure!);
    final r = await run;
    expect(r.outcome, ReplayOutcome.reproduced);
    expect(r.evidence!.level, EvidenceLevel.none);
  });
}
