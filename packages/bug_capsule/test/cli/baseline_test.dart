import 'dart:io';

import 'package:bug_capsule/src/cli/baseline.dart';
import 'package:bug_capsule/src/cli/replay.dart';
import 'package:bug_capsule/src/core/core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('bc_baseline'));
  tearDown(() => dir.delete(recursive: true));

  group('baseline cache', () {
    const result = BaselineResult(revision: 'abc', attempts: 3, reproduced: 3);
    final key = baselineKey(
      capsuleBytes: [1, 2, 3],
      revision: 'abc',
      harness: 'flutter|auto',
    );

    test('a stored result comes back marked cached', () {
      final cache = BaselineCache(dir.path)..write(key, result);
      final hit = cache.read(key)!;
      expect(
        [hit.revision, hit.attempts, hit.reproduced, hit.cached],
        ['abc', 3, 3, true],
      );
    });

    test('expires after seven days', () {
      final cache = BaselineCache(dir.path)..write(key, result);
      expect(
        cache.read(key, now: DateTime.now().add(const Duration(days: 8))),
        isNull,
      );
    });

    test('an unreadable entry is never trusted', () {
      BaselineCache(dir.path).write(key, result);
      File(
        '${dir.path}/bugcapsule/.cache/baselines/$key.json',
      ).writeAsStringSync('{nope');
      expect(BaselineCache(dir.path).read(key), isNull);
    });

    test('the key changes with the capsule, the revision and the harness', () {
      final other = {
        baselineKey(
          capsuleBytes: [1, 2, 4],
          revision: 'abc',
          harness: 'flutter|auto',
        ),
        baselineKey(
          capsuleBytes: [1, 2, 3],
          revision: 'abd',
          harness: 'flutter|auto',
        ),
        baselineKey(
          capsuleBytes: [1, 2, 3],
          revision: 'abc',
          harness: 'flutter|pointer',
        ),
      };
      expect(other, hasLength(3));
      expect(other, isNot(contains(key)));
    });
  });

  group('v2 run payload', () {
    ReplayReport clean() => const ReplayReport(
      outcome: ReplayOutcome.notReproduced,
      attempt: 1,
      durationMs: 1,
      strategy: ReplayStrategy.auto,
      expectedSignature: 'assertion:x:',
      eventsDispatched: 0,
      eventsExpected: 0,
      evidence: ReplayEvidence(failurePointPassed: true),
    );

    test(
      'FIXED (QUALIFIED) reaches the backend as inconclusive, with the baseline',
      () {
        const baseline = BaselineResult(
          revision: 'abc',
          attempts: 3,
          reproduced: 3,
        );
        final reports = List.generate(8, (_) => clean());
        final s =
            ReplaySummary(
              ReplayKind.verify,
              reports,
              'def',
              requestedAttempts: 8,
            ).withEvaluation(
              evaluateVerifyV2(
                requestedAttempts: 8,
                candidate: reports,
                baseline: baseline,
                eligibility: EligibilityStatus.eligible,
              ),
              baseline: baseline,
            );
        expect(s.verdict, Verdict.fixedQualified);
        final p = s.runPayload();
        expect(p['outcome'], 'inconclusive');
        final details = p['details']! as Map;
        expect(details['verdictVersion'], 2);
        expect((details['baseline'] as Map)['revision'], 'abc');
        expect(details['verdict'], 'fixedQualified');
      },
    );

    test('a v1 summary carries no v2 fields', () {
      final p = ReplaySummary(
        ReplayKind.verify,
        [clean()],
        'def',
        requestedAttempts: 1,
      ).runPayload();
      final details = p['details']! as Map;
      expect(details.containsKey('verdictVersion'), isFalse);
      expect(details.containsKey('baseline'), isFalse);
    });
  });
}
