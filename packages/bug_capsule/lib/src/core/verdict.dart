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
  };
  // Not expected: `text.redacted`, `storage.redacted`, `route.redacted`. A
  // placeholder replayed instead of a token, an OTP or a route can send the
  // app down another path (logged out, validation error) where the failure
  // never fires, which must not read as a fix.

  static bool isMaterial(Divergence d) => !expected.contains(d.type);
}

class AttemptAssessment {
  const AttemptAssessment(this.report, this.status, this.reasons);

  final ReplayReport report;
  final AttemptStatus status;

  /// Why an attempt is invalid (empty otherwise).
  final List<String> reasons;
}

/// Classifies one attempt.
///
/// A reproduction counts whatever else happened: the failure fired. A run
/// without the failure counts as [AttemptStatus.clean] only when it is
/// complete and faithful: an assertion to check, every recorded input
/// dispatched, no other failure, and no material divergence.
AttemptAssessment assessAttempt(ReplayReport r) {
  final reasons = <String>[];
  switch (r.outcome) {
    case ReplayOutcome.reproduced:
      if (r.expectedSignature == null) {
        reasons.add('reported a reproduction without an expected failure');
        return AttemptAssessment(r, AttemptStatus.invalid, reasons);
      }
      return AttemptAssessment(r, AttemptStatus.reproduced, const []);
    case ReplayOutcome.incompatible:
      reasons.add('incompatible: ${r.message ?? 'capsule cannot run against this build'}');
    case ReplayOutcome.noAssertion:
      reasons.add('capsule has no failure assertion');
    case ReplayOutcome.error:
      reasons.add('replay error: ${r.message ?? 'unknown'}');
    case ReplayOutcome.notReproduced:
      if (r.expectedSignature == null) reasons.add('no expected failure to check');
      final expected = r.eventsExpected;
      if (expected != null && r.eventsDispatched < expected) {
        reasons.add('only ${r.eventsDispatched} of $expected recorded inputs were replayed');
      }
      for (final f in r.otherFailures) {
        reasons.add('unexpected failure: ${f.signature}');
      }
      final material = <String>{
        for (final d in r.divergences)
          if (DivergencePolicy.isMaterial(d)) d.type,
      };
      for (final type in material) {
        final n = r.divergences.where((d) => d.type == type).length;
        reasons.add('divergence $type${n > 1 ? ' ×$n' : ''}');
      }
  }
  return AttemptAssessment(
      r, reasons.isEmpty ? AttemptStatus.clean : AttemptStatus.invalid, reasons);
}

class RunEvaluation {
  const RunEvaluation({
    required this.kind,
    required this.requestedAttempts,
    required this.verdict,
    required this.attempts,
    required this.reasons,
  });

  final RunKind kind;
  final int requestedAttempts;
  final Verdict verdict;
  final List<AttemptAssessment> attempts;

  /// Why the verdict is not a clean success (deduplicated).
  final List<String> reasons;

  int get completedAttempts => attempts.length;
  int get reproductions => attempts.where((a) => a.status == AttemptStatus.reproduced).length;
  int get cleanAttempts => attempts.where((a) => a.status == AttemptStatus.clean).length;
  int get invalidAttempts => attempts.where((a) => a.status == AttemptStatus.invalid).length;

  /// Attempts that count as evidence (reproduced or clean).
  int get validAttempts => reproductions + cleanAttempts;

  /// The verdict the caller asked for: reproduced for replay, fixed for verify.
  bool get succeeded =>
      verdict == (kind == RunKind.replay ? Verdict.reproduced : Verdict.fixed);

  /// 0 success, 1 the opposite, 2 flaky, 3 inconclusive / incompatible.
  int get exitCode => switch (verdict) {
        Verdict.reproduced || Verdict.fixed => 0,
        Verdict.notReproduced || Verdict.stillFailing => 1,
        Verdict.flaky => 2,
        Verdict.incompatible || Verdict.inconclusive => 3,
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
RunEvaluation evaluateRun(RunKind kind, int requestedAttempts, List<ReplayReport> reports) {
  final attempts = [for (final r in reports) assessAttempt(r)];
  final reasons = <String>{};
  for (final a in attempts) {
    reasons.addAll(a.reasons);
  }
  if (reports.length > requestedAttempts) {
    reasons.add('${reports.length} reports for $requestedAttempts requested attempts');
  }
  final missing = requestedAttempts - attempts.length;
  if (missing > 0) reasons.add('$missing of $requestedAttempts requested attempts did not run');
  if (requestedAttempts <= 0) reasons.add('no attempts were requested');

  final n = requestedAttempts;
  final r = attempts.where((a) => a.status == AttemptStatus.reproduced).length;
  final c = attempts.where((a) => a.status == AttemptStatus.clean).length;
  final Verdict verdict;
  if (reports.any((x) => x.outcome == ReplayOutcome.incompatible)) {
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
  );
}
