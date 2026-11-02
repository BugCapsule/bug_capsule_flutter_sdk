import 'dart:math' as math;

import 'capsule.dart' show EligibilityStatus;
import 'failure.dart';
import 'replay_protocol.dart';

/// `replay` expects the original failure; `verify` expects it gone.
enum RunKind { replay, verify }

/// What a batch of attempts proves. See [evaluateRun] for the rules.
enum Verdict {
  /// replay: the failure fired in every requested attempt.
  reproduced('reproduced'),

  /// replay: every requested attempt ran validly and the failure never fired.
  notReproduced('not_reproduced'),

  /// verify: every requested attempt ran validly and the failure never fired.
  fixed('not_reproduced'),

  /// verify: the failure fired and no attempt ran validly without it.
  stillFailing('reproduced'),

  /// Both outcomes among attempts that ran validly.
  flaky('flaky'),

  /// verify (v2): baseline reproduced, every candidate attempt clean, but the
  /// evidence is weak or the capsule is partial. Sent to the backend as
  /// inconclusive, so it never satisfies a gate.
  fixedQualified('inconclusive'),

  /// Replay containment was not kept (live traffic allowed): no conclusion.
  unsafe('inconclusive'),

  /// The capsule cannot run against this build.
  incompatible('incompatible'),

  /// Nothing can be concluded: attempts errored, are missing, diverged
  /// materially, or the capsule has no failure assertion.
  inconclusive('inconclusive');

  const Verdict(this.wire);

  /// Outcome sent to the backend `runs` endpoint.
  final String wire;
}

/// How one attempt counts toward the verdict.
enum AttemptStatus {
  /// The expected failure fired.
  reproduced,

  /// Ran to the end as recorded and the failure did not fire.
  clean,

  /// Proves nothing either way (see [AttemptAssessment.reasons]).
  invalid,
}

/// Separates divergences that are expected between a recording and a replay
/// from those that make a "the failure did not happen" result meaningless.
abstract final class DivergencePolicy {
  /// Expected differences. Everything else, including divergence types this
  /// version does not know, is material: an unknown difference must not be
  /// able to produce a "fixed" verdict.
  static const expected = {
    // verify builds a different commit on purpose; replay warns about it.
    'build.gitSha',
    // pointer replay scales coordinates to the replay screen.
    'screen.size',
    // the recording continues after the failure; a fix may also skip calls.
    'network.unused',
    // capsule-v2 §5: interactions recorded after the failure.
    'ws.unusedAfterFailure',
    'platform.unusedAfterFailure',
    'native.unusedAfterFailure',
  };
  // Not expected: `text.redacted`, `storage.redacted`, `route.redacted`. A
  // placeholder replayed instead of a token, an OTP or a route can send the
  // app down another path (logged out, validation error) where the failure
  // never fires, which must not read as a fix.

  static bool isMaterial(Divergence d) => !expected.contains(d.type);

  /// The capsule-v2 §8 reason code of a material interaction divergence,
  /// or null for other divergence types.
  static String? reasonCode(String type) {
    if (type == 'dependency.live' || type == 'dependency.late') {
      return 'interaction.live';
    }
    final family = type.split('.').first;
    if (family != 'ws' && family != 'platform' && family != 'native') {
      return null;
    }
    return switch (type.substring(family.length + 1)) {
      'unused' || 'undelivered' => 'interaction.missing',
      'unrecorded' => 'interaction.unexpected',
      'mismatch' => 'interaction.mismatch',
      'noPayload' => 'interaction.incomplete',
      'unrestored' => 'interaction.unrestored',
      _ => null,
    };
  }
}

class AttemptAssessment {
  const AttemptAssessment(
    this.report,
    this.status,
    this.reasons, [
    this.reasonCodes = const [],
  ]);

  final ReplayReport report;
  final AttemptStatus status;

  /// Why an attempt is invalid (empty otherwise).
  final List<String> reasons;

  /// Machine-readable codes for [reasons] that concern interaction
  /// dependencies (capsule-v2 §8), e.g. `interaction.missing`.
  final List<String> reasonCodes;
}

/// Classifies one attempt.
///
/// A reproduction counts whatever else happened: the failure fired. A run
/// without the failure counts as [AttemptStatus.clean] only when it is
/// complete and faithful: an assertion to check, every recorded input
/// dispatched, no other failure, and no material divergence.
AttemptAssessment assessAttempt(ReplayReport r) {
  final reasons = <String>[];
  final codes = <String>{};
  switch (r.outcome) {
    case ReplayOutcome.reproduced:
      if (r.expectedSignature == null) {
        reasons.add('reported a reproduction without an expected failure');
        return AttemptAssessment(r, AttemptStatus.invalid, reasons);
      }
      // crash-capsules §4: the same crash in another in-app frame still
      // reproduces, and says so.
      return AttemptAssessment(r, AttemptStatus.reproduced, const [], [
        if (r.divergences.any((d) => d.type == 'failure.different_frame'))
          'failure.different_frame',
      ]);
    case ReplayOutcome.incompatible:
      reasons.add(
        'incompatible: ${r.message ?? 'capsule cannot run against this build'}',
      );
      if (r.message?.startsWith('dependency.') ?? false) {
        codes.add('dependency.unsupported');
      }
    case ReplayOutcome.noAssertion:
      reasons.add('capsule has no failure assertion');
    case ReplayOutcome.error:
      reasons.add('replay error: ${r.message ?? 'unknown'}');
    case ReplayOutcome.notReproduced:
      if (r.expectedSignature == null) {
        reasons.add('no expected failure to check');
      }
      final expected = r.eventsExpected;
      if (expected != null && r.eventsDispatched < expected) {
        reasons.add(
          'only ${r.eventsDispatched} of $expected recorded inputs were replayed',
        );
      }
      for (final f in r.otherFailures) {
        reasons.add('unexpected failure: ${f.signature}');
      }
      // crash-capsules §4: the app died of another crash than the one
      // recorded, or a crash replaced the recorded failure.
      if (r.otherFailures.any((f) => f.kind == FailureKind.crash) ||
          (r.otherFailures.isNotEmpty &&
              (r.expectedSignature?.startsWith('crash:') ?? false))) {
        codes.add('failure.different');
      }
      final material = <String>{
        for (final d in r.divergences)
          if (DivergencePolicy.isMaterial(d)) d.type,
      };
      for (final type in material) {
        final n = r.divergences.where((d) => d.type == type).length;
        reasons.add('divergence $type${n > 1 ? ' ×$n' : ''}');
        final code = DivergencePolicy.reasonCode(type);
        if (code != null) codes.add(code);
      }
  }
  return AttemptAssessment(
    r,
    reasons.isEmpty ? AttemptStatus.clean : AttemptStatus.invalid,
    reasons,
    codes.toList()..sort(),
  );
}

class RunEvaluation {
  const RunEvaluation({
    required this.kind,
    required this.requestedAttempts,
    required this.verdict,
    required this.attempts,
    required this.reasons,
    this.reasonCodes = const [],
  });

  final RunKind kind;
  final int requestedAttempts;
  final Verdict verdict;
  final List<AttemptAssessment> attempts;

  /// Why the verdict is not a clean success (deduplicated).
  final List<String> reasons;

  /// Interaction reason codes over all attempts (capsule-v2 §8), sorted.
  final List<String> reasonCodes;

  int get completedAttempts => attempts.length;
  int get reproductions =>
      attempts.where((a) => a.status == AttemptStatus.reproduced).length;
  int get cleanAttempts =>
      attempts.where((a) => a.status == AttemptStatus.clean).length;
  int get invalidAttempts =>
      attempts.where((a) => a.status == AttemptStatus.invalid).length;

  /// Attempts that count as evidence (reproduced or clean).
  int get validAttempts => reproductions + cleanAttempts;

  /// The verdict the caller asked for: reproduced for replay, fixed for verify.
  bool get succeeded =>
      verdict == (kind == RunKind.replay ? Verdict.reproduced : Verdict.fixed);

  /// 0 success, 1 the opposite, 2 flaky, 3 inconclusive / incompatible,
  /// 4 fixed with qualifications, 5 unsafe.
  int get exitCode => switch (verdict) {
    Verdict.reproduced || Verdict.fixed => 0,
    Verdict.notReproduced || Verdict.stillFailing => 1,
    Verdict.flaky => 2,
    Verdict.incompatible || Verdict.inconclusive => 3,
    Verdict.fixedQualified => 4,
    Verdict.unsafe => 5,
  };
}

/// The verdict rules, shared by `bugcapsule run`, `bugcapsule verify` and
/// `bugcapsule regress run`. With N requested attempts, R reproductions, C clean
/// attempts and I invalid ones:
///
/// * any attempt incompatible → [Verdict.incompatible];
/// * N == 0 → [Verdict.inconclusive];
/// * replay: R == N → reproduced; C == N → notReproduced; R > 0 and C > 0 →
///   flaky; otherwise inconclusive;
/// * verify: C == N → fixed; R > 0 and C > 0 → flaky; R > 0 and C == 0 →
///   stillFailing; otherwise inconclusive.
///
/// Attempts that never ran count against N, so "fixed" needs every
/// requested attempt to complete validly without the failure.
RunEvaluation evaluateRun(
  RunKind kind,
  int requestedAttempts,
  List<ReplayReport> reports,
) {
  final attempts = [for (final r in reports) assessAttempt(r)];
  final reasons = <String>{};
  for (final a in attempts) {
    reasons.addAll(a.reasons);
  }
  if (reports.length > requestedAttempts) {
    reasons.add(
      '${reports.length} reports for $requestedAttempts requested attempts',
    );
  }
  final missing = requestedAttempts - attempts.length;
  if (missing > 0) {
    reasons.add(
      '$missing of $requestedAttempts requested attempts did not run',
    );
  }
  if (requestedAttempts <= 0) reasons.add('no attempts were requested');

  final n = requestedAttempts;
  final r = attempts.where((a) => a.status == AttemptStatus.reproduced).length;
  final c = attempts.where((a) => a.status == AttemptStatus.clean).length;
  final Verdict verdict;
  if (reports.any(
    (x) => x.divergences.any((d) => d.type == unsafeLiveDivergence),
  )) {
    reasons.add('live traffic was allowed during replay');
    verdict = Verdict.unsafe;
  } else if (reports.any((x) => x.outcome == ReplayOutcome.incompatible)) {
    verdict = Verdict.incompatible;
  } else if (n <= 0 || reports.length > n) {
    verdict = Verdict.inconclusive;
  } else if (kind == RunKind.replay) {
    verdict = r == n
        ? Verdict.reproduced
        : c == n
        ? Verdict.notReproduced
        : r > 0 && c > 0
        ? Verdict.flaky
        : Verdict.inconclusive;
  } else {
    verdict = c == n
        ? Verdict.fixed
        : r > 0 && c > 0
        ? Verdict.flaky
        : r > 0
        ? Verdict.stillFailing
        : Verdict.inconclusive;
  }
  return RunEvaluation(
    kind: kind,
    requestedAttempts: requestedAttempts,
    verdict: verdict,
    attempts: attempts,
    reasons: reasons.toList(),
    reasonCodes: {for (final a in attempts) ...a.reasonCodes}.toList()..sort(),
  );
}

// ------------------------------------------------------------- verdict v2

/// Divergence a runner adds when the user let live traffic through
/// (`--allow-live`): the attempt proves nothing either way.
const unsafeLiveDivergence = 'replay.unsafe_live';

/// Baseline attempts below this never support FIXED.
const minBaselineAttempts = 3;

/// Candidate attempts are never fewer than this, nor more than
/// [maxCandidateAttempts].
const minCandidateAttempts = 5;
const maxCandidateAttempts = 30;

/// The baseline build's result for a capsule (spec/verdict-v2.md).
class BaselineResult {
  const BaselineResult({
    required this.revision,
    required this.attempts,
    required this.reproduced,
    this.cached = false,
  });

  factory BaselineResult.fromJson(Map<String, Object?> j) => BaselineResult(
    revision: j['revision'] as String,
    attempts: j['attempts'] as int,
    reproduced: j['reproduced'] as int,
    cached: j['cached'] == true,
  );

  final String revision;
  final int attempts;
  final int reproduced;
  final bool cached;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'attempts': attempts,
    'reproduced': reproduced,
    'cached': cached,
  };
}

/// Lower bound of the Wilson 95% interval of [successes] / [n].
double wilsonLower(int successes, int n) {
  if (n <= 0) return 0;
  const z = 1.959963984540054;
  final p = successes / n;
  final z2 = z * z;
  final centre = p + z2 / (2 * n);
  final margin = z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n));
  return ((centre - margin) / (1 + z2 / n)).clamp(0.0, 1.0);
}

/// Candidate attempts so that a build still failing at the baseline's lower
/// rate would pass every attempt with probability below 1%.
int requiredCandidateAttempts(int baselineReproduced, int baselineAttempts) {
  final low = wilsonLower(baselineReproduced, baselineAttempts);
  if (low <= 0) return maxCandidateAttempts;
  if (low >= 1) return minCandidateAttempts;
  final n = (math.log(0.01) / math.log(1 - low)).ceil();
  return n.clamp(minCandidateAttempts, maxCandidateAttempts);
}

/// `verify` under verdict v2: [candidate] are the candidate build's reports,
/// [baseline] the baseline build's result (null when none could be built).
///
/// FIXED needs a baseline that reproduced in every one of at least
/// [minBaselineAttempts] attempts, at least [requiredCandidateAttempts]
/// candidate attempts all clean, strong positive evidence in each, and an
/// eligible capsule. Weak evidence or a partial capsule gives
/// [Verdict.fixedQualified]; no evidence at all is inconclusive.
RunEvaluation evaluateVerifyV2({
  required int requestedAttempts,
  required List<ReplayReport> candidate,
  required BaselineResult? baseline,
  required EligibilityStatus eligibility,
}) {
  final v1 = evaluateRun(RunKind.verify, requestedAttempts, candidate);
  final reasons = [...v1.reasons];
  final codes = {...v1.reasonCodes};
  RunEvaluation result(Verdict verdict, [String? reason, String? code]) {
    if (reason != null) reasons.add(reason);
    if (code != null) codes.add(code);
    return RunEvaluation(
      kind: RunKind.verify,
      requestedAttempts: requestedAttempts,
      verdict: verdict,
      attempts: v1.attempts,
      reasons: reasons,
      reasonCodes: codes.toList()..sort(),
    );
  }

  if (candidate.any(
    (r) => r.divergences.any((d) => d.type == unsafeLiveDivergence),
  )) {
    return result(
      Verdict.unsafe,
      'live traffic was allowed during replay',
      'replay.unsafe',
    );
  }
  if (v1.verdict == Verdict.incompatible ||
      v1.verdict == Verdict.stillFailing) {
    return result(v1.verdict);
  }
  if (baseline == null) {
    return result(
      Verdict.inconclusive,
      'no baseline: the capsule\'s build could not be replayed, so nothing shows this harness reproduces the failure',
      'baseline.unavailable',
    );
  }
  if (baseline.reproduced == 0) {
    return result(
      Verdict.inconclusive,
      'the baseline build did not reproduce the failure in ${baseline.attempts} attempts',
      'baseline.not_reproduced',
    );
  }
  if (baseline.reproduced < baseline.attempts) {
    return result(
      Verdict.flaky,
      'the baseline build reproduced in ${baseline.reproduced} of ${baseline.attempts} attempts',
      'baseline.flaky',
    );
  }
  if (baseline.attempts < minBaselineAttempts) {
    return result(
      Verdict.inconclusive,
      'the baseline ran ${baseline.attempts} attempts; at least $minBaselineAttempts are needed',
      'baseline.too_few',
    );
  }
  final needed = requiredCandidateAttempts(
    baseline.reproduced,
    baseline.attempts,
  );
  if (requestedAttempts < needed) {
    return result(
      Verdict.inconclusive,
      '$requestedAttempts candidate attempts; $needed are needed after a ${baseline.reproduced}/${baseline.attempts} baseline',
      'attempts.too_few',
    );
  }
  if (v1.verdict != Verdict.fixed) return result(v1.verdict);
  if (eligibility == EligibilityStatus.ineligible) {
    return result(
      Verdict.inconclusive,
      'the capsule is ineligible for replay',
      'capsule.ineligible',
    );
  }
  final levels = [
    for (final a in v1.attempts) a.report.evidence?.level ?? EvidenceLevel.none,
  ];
  if (levels.any((l) => l == EvidenceLevel.none)) {
    final failed = {
      for (final a in v1.attempts) ...?a.report.evidence?.failedPostconditions,
    };
    if (failed.isNotEmpty) {
      return result(
        Verdict.stillFailing,
        'postconditions did not hold: ${failed.join(', ')}',
        'postcondition.failed',
      );
    }
    return result(
      Verdict.inconclusive,
      'no positive evidence: nothing shows the failing path ran (update the SDK, or register a postcondition with BugCapsule.expect)',
      'evidence.none',
    );
  }
  final weak = levels.any((l) => l == EvidenceLevel.weak);
  final partial = eligibility == EligibilityStatus.partial;
  if (weak || partial) {
    return result(
      Verdict.fixedQualified,
      [
        if (weak)
          'only shows the recorded failure point was passed (no assertion or postcondition held)',
        if (partial) 'the capsule is partial: some inputs were not recorded',
      ].join('; '),
      weak ? 'evidence.weak' : 'capsule.partial',
    );
  }
  return result(Verdict.fixed);
}
