import 'package:test/test.dart';
import 'package:bug_capsule/src/core/verdict.dart';

import '../../tool/conformance_cases.dart';
import '../../tool/generate_conformance.dart';

/// Verdict v2 (spec/verdict-v2.md). The fixtures are generated from the
/// implementation, so this test pins the intended verdict of every case
/// independently: a rule change shows up here, not just as a new fixture.
void main() {
  const expected = {
    'FIXED: reproducing baseline, enough clean attempts, assertion held':
        'fixed',
    'FIXED: postconditions held': 'fixed',
    'R1 counter-example: flaky baseline never gives FIXED': 'flaky',
    'baseline that never reproduced is inconclusive': 'inconclusive',
    'no baseline is inconclusive': 'inconclusive',
    'baseline with too few attempts is inconclusive': 'inconclusive',
    'too few candidate attempts after a 3/3 baseline': 'inconclusive',
    'pre-v2 SDK reports carry no evidence: inconclusive': 'inconclusive',
    'only the failure point was passed: FIXED_QUALIFIED': 'fixedQualified',
    'replay ended before the failure point: no evidence': 'inconclusive',
    'partial capsule with strong evidence: FIXED_QUALIFIED': 'fixedQualified',
    'ineligible capsule is inconclusive': 'inconclusive',
    'a postcondition that did not hold is still failing': 'stillFailing',
    'candidate still reproduces': 'stillFailing',
    'live traffic allowed is unsafe even with a good baseline': 'unsafe',
  };

  final cases =
      (buildConformanceFixtures()['verdicts.json'] as Map)['verifyV2'] as List;

  test('every v2 case has a pinned expectation', () {
    expect({for (final c in cases) (c as Map)['name']}, expected.keys.toSet());
    expect(cases.length, verifyV2Cases.length);
  });

  for (final c in cases.cast<Map<String, Object?>>()) {
    test(c['name'] as String, () {
      expect(c['verdict'], expected[c['name']]);
    });
  }

  test('only FIXED exits 0; qualified exits 4 and unsafe 5', () {
    final exits = {
      for (final c in cases.cast<Map<String, Object?>>())
        c['verdict']: c['exitCode'],
    };
    expect(exits['fixed'], 0);
    expect(exits['fixedQualified'], 4);
    expect(exits['unsafe'], 5);
    expect(exits['flaky'], 2);
    expect(exits['inconclusive'], 3);
  });

  test('required candidate attempts follow the spec table', () {
    expect(requiredCandidateAttempts(3, 3), 8);
    expect(requiredCandidateAttempts(5, 5), 6);
    expect(requiredCandidateAttempts(10, 10), 5);
    expect(requiredCandidateAttempts(0, 5), maxCandidateAttempts);
    expect(wilsonLower(5, 5), closeTo(0.5655, 1e-4));
  });

  test(
    'a FIXED_QUALIFIED or UNSAFE result never reaches the backend as fixed',
    () {
      expect(Verdict.fixedQualified.wire, isNot(Verdict.fixed.wire));
      expect(Verdict.unsafe.wire, isNot(Verdict.fixed.wire));
    },
  );
}
