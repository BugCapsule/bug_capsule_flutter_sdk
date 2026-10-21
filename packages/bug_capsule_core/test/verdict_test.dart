import 'package:bug_capsule_core/bug_capsule_core.dart';
import 'package:test/test.dart';

const sig = 'exception:StateError:boom';

ReplayReport report(
  ReplayOutcome outcome, {
  List<Divergence> divergences = const [],
  List<FailureRecord> otherFailures = const [],
  String? expected = sig,
  int dispatched = 4,
  int? eventsExpected = 4,
  String? message,
}) => ReplayReport(
  outcome: outcome,
  attempt: 1,
  durationMs: 100,
  strategy: ReplayStrategy.semantic,
  expectedSignature: expected,
  divergences: divergences,
  otherFailures: otherFailures,
  eventsDispatched: dispatched,
  eventsExpected: eventsExpected,
  message: message,
);

final clean = report(ReplayOutcome.notReproduced);
final reproduced = report(ReplayOutcome.reproduced);
final error = report(ReplayOutcome.error, message: 'app crashed during launch');

void main() {
  group('verify', () {
    test('every requested attempt clean -> fixed, exit 0', () {
      final e = evaluateRun(RunKind.verify, 3, [clean, clean, clean]);
      expect(e.verdict, Verdict.fixed);
      expect(e.exitCode, 0);
      expect(e.verdict.wire, 'not_reproduced');
      expect(e.validAttempts, 3);
      expect(e.succeeded, isTrue);
    });

    test('one clean attempt and one error is inconclusive, never fixed (regression)', () {
      final e = evaluateRun(RunKind.verify, 2, [clean, error]);
      expect(e.verdict, Verdict.inconclusive);
      expect(e.exitCode, 3);
      expect(e.verdict.wire, 'inconclusive');
      expect(e.reasons.join(' '), contains('replay error'));
    });

    test('fewer completed attempts than requested is inconclusive', () {
      final e = evaluateRun(RunKind.verify, 5, [clean, clean]);
      expect(e.verdict, Verdict.inconclusive);
      expect(e.reasons, contains('3 of 5 requested attempts did not run'));
    });

    test('zero attempts is inconclusive', () {
      expect(evaluateRun(RunKind.verify, 0, const []).verdict, Verdict.inconclusive);
      expect(evaluateRun(RunKind.verify, 2, const []).verdict, Verdict.inconclusive);
    });

    test('no failure assertion is inconclusive', () {
      final e = evaluateRun(RunKind.verify, 1, [report(ReplayOutcome.noAssertion, expected: null)]);
      expect(e.verdict, Verdict.inconclusive);
      final missing = evaluateRun(RunKind.verify, 1, [
        report(ReplayOutcome.notReproduced, expected: null),
      ]);
      expect(missing.verdict, Verdict.inconclusive);
    });

    for (final type in [
      'action.unregistered',
      'text.untracked',
      'restore.bloc',
      'restore.missingIntegration',
      'integration.missing',
      'bloc.unrestored',
      'network.unrecorded',
      'network.noBody',
      'network.reused',
      'dispatch.error',
      'route.extra',
      'some.future.divergence',
    ]) {
      test('material divergence $type makes a clean-looking attempt inconclusive', () {
        final e = evaluateRun(RunKind.verify, 2, [
          clean,
          report(ReplayOutcome.notReproduced, divergences: [Divergence(type, 'x')]),
        ]);
        expect(e.verdict, Verdict.inconclusive);
        expect(e.reasons.single, 'divergence $type');
      });
    }

    test('expected differences (changed commit, screen size, unused responses) do not block a fix', () {
      final e = evaluateRun(RunKind.verify, 1, [
        report(
          ReplayOutcome.notReproduced,
          divergences: const [
            Divergence('build.gitSha', 'capsule a vs build b'),
            Divergence('screen.size', '402x874 vs 390x844'),
            Divergence('network.unused', 'GET a/b'),
          ],
        ),
      ]);
      expect(e.verdict, Verdict.fixed);
    });

    for (final type in ['text.redacted', 'storage.redacted', 'route.redacted']) {
      test('a replayed placeholder ($type) blocks a fix: the app may never reach the bug', () {
        final e = evaluateRun(RunKind.verify, 1, [
          report(ReplayOutcome.notReproduced, divergences: [Divergence(type, 'auth_token')]),
        ]);
        expect(e.verdict, Verdict.inconclusive);
      });
    }

    test('more reports than requested attempts is inconclusive', () {
      expect(evaluateRun(RunKind.verify, 1, [clean, clean]).verdict, Verdict.inconclusive);
    });

    test('an unexpected failure blocks a fix', () {
      final other = FailureRecord.exception(StateError('new crash'), null, 5);
      final e = evaluateRun(RunKind.verify, 1, [
        report(ReplayOutcome.notReproduced, otherFailures: [other]),
      ]);
      expect(e.verdict, Verdict.inconclusive);
      expect(e.reasons.single, startsWith('unexpected failure'));
    });

    test(
      'inputs not all dispatched is inconclusive; older SDKs without the count are judged on divergences',
      () {
        expect(
          evaluateRun(RunKind.verify, 1, [
            report(ReplayOutcome.notReproduced, dispatched: 2),
          ]).verdict,
          Verdict.inconclusive,
        );
        expect(
          evaluateRun(RunKind.verify, 1, [
            report(ReplayOutcome.notReproduced, eventsExpected: null),
          ]).verdict,
          Verdict.fixed,
        );
      },
    );

    test('still failing, flaky and mixed with errors', () {
      expect(evaluateRun(RunKind.verify, 2, [reproduced, reproduced]).verdict, Verdict.stillFailing);
      expect(evaluateRun(RunKind.verify, 2, [reproduced, reproduced]).exitCode, 1);
      expect(evaluateRun(RunKind.verify, 2, [reproduced, clean]).verdict, Verdict.flaky);
      expect(evaluateRun(RunKind.verify, 2, [reproduced, clean]).exitCode, 2);
      expect(evaluateRun(RunKind.verify, 2, [reproduced, error]).verdict, Verdict.stillFailing);
    });

    test('incompatible wins', () {
      final e = evaluateRun(RunKind.verify, 3, [
        report(ReplayOutcome.incompatible, message: 'schema v2'),
      ]);
      expect(e.verdict, Verdict.incompatible);
      expect(e.exitCode, 3);
    });
  });

  group('replay', () {
    test('reproduced in every attempt', () {
      final e = evaluateRun(RunKind.replay, 3, [reproduced, reproduced, reproduced]);
      expect(e.verdict, Verdict.reproduced);
      expect(e.exitCode, 0);
    });

    test('a reproduction counts even with divergences', () {
      final r = report(
        ReplayOutcome.reproduced,
        divergences: const [Divergence('network.unrecorded', 'k')],
      );
      expect(evaluateRun(RunKind.replay, 1, [r]).verdict, Verdict.reproduced);
    });

    test('not reproduced needs valid attempts', () {
      expect(evaluateRun(RunKind.replay, 2, [clean, clean]).verdict, Verdict.notReproduced);
      expect(evaluateRun(RunKind.replay, 2, [clean, clean]).exitCode, 1);
      expect(evaluateRun(RunKind.replay, 2, [clean, error]).verdict, Verdict.inconclusive);
    });

    test('flaky and partial', () {
      expect(evaluateRun(RunKind.replay, 2, [reproduced, clean]).verdict, Verdict.flaky);
      expect(evaluateRun(RunKind.replay, 2, [reproduced, error]).verdict, Verdict.inconclusive);
      expect(evaluateRun(RunKind.replay, 3, [reproduced]).verdict, Verdict.inconclusive);
    });

    test('a reproduction without an expected failure is invalid', () {
      expect(
        evaluateRun(RunKind.replay, 1, [report(ReplayOutcome.reproduced, expected: null)]).verdict,
        Verdict.inconclusive,
      );
    });
  });

  test('eventsExpected survives the wire', () {
    final json = report(ReplayOutcome.notReproduced, dispatched: 3, eventsExpected: 5).toJson();
    final back = ReplayReport.fromJson(json);
    expect(back.eventsExpected, 5);
    expect(ReplayReport.fromJson({...json}..remove('eventsExpected')).eventsExpected, isNull);
  });
}
