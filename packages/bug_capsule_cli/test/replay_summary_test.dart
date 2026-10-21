import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule_cli/src/capsule_source.dart';
import 'package:bug_capsule_cli/src/launcher.dart';
import 'package:bug_capsule_cli/src/replay.dart';
import 'package:bug_capsule_cli/src/replay_server.dart';
import 'package:bug_capsule_core/bug_capsule_core.dart';
import 'package:test/test.dart';

const sig = 'exception:StateError:Bad state: Cart total is negative (#)';

ReplayReport report(ReplayOutcome outcome, {List<Divergence> divergences = const [], String? message}) =>
    ReplayReport(
      outcome: outcome,
      attempt: 1,
      durationMs: 10,
      strategy: ReplayStrategy.semantic,
      expectedSignature: outcome == ReplayOutcome.noAssertion ? null : sig,
      divergences: divergences,
      eventsDispatched: 3,
      eventsExpected: 3,
      message: message,
    );

final clean = report(ReplayOutcome.notReproduced);
final reproduced = report(ReplayOutcome.reproduced);
final error = report(ReplayOutcome.error, message: 'app did not start');

/// Hands out scripted reports instead of launching an app.
class ScriptedLauncher implements AppLauncher {
  ScriptedLauncher(this.reports);
  final List<ReplayReport> reports;
  int launches = 0;

  @override
  LaunchOptions get options => throw UnimplementedError();
  @override
  Future<void> prepare(ReplayServer server) async {}
  @override
  Future<ReplayReport> attempt(
      ReplayServer server, List<int> capsule, ReplaySettings settings, Duration timeout) async {
    launches++;
    return reports.removeAt(0);
  }

  @override
  Future<void> dispose() async {}
}

String plain(String s) => s.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

void main() {
  group('verify summary', () {
    test('one valid pass plus one error is INCONCLUSIVE, exit 3, never "fixed" on the backend', () {
      final s = ReplaySummary(ReplayKind.verify, [clean, error], 'b1', requestedAttempts: 2);
      expect(exitCodeFor(s), 3);
      expect(s.wireOutcome, 'inconclusive');
      final payload = s.runPayload(device: 'sim');
      expect(payload['outcome'], 'inconclusive');
      expect(payload['attempts'], 2);
      expect(payload['validAttempts'], 1);
      final text = plain(summaryLines(s).join('\n'));
      expect(text, contains('INCONCLUSIVE'));
      expect(text, contains('replay error: app did not start'));
      expect(text, isNot(contains('FIXED')));
    });

    test('the backend payload has exactly the fields the backend accepts', () {
      final payload = ReplaySummary(ReplayKind.verify, [clean], 'b1', requestedAttempts: 1).runPayload(device: 'sim');
      // bug_capsule_backend runBody (additionalProperties: false) and test/verification.test.ts cliPayload.
      expect(payload.keys.toSet(), {
        'kind', 'outcome', 'attempts', 'reproductions', 'validAttempts', 'gitSha', 'device', 'durationMs', 'details',
      });
      expect((payload['details'] as Map).keys.toSet(), {'verdict', 'reasons', 'completedAttempts', 'reports'});
    });

    test('every attempt valid without the failure is FIXED, exit 0', () {
      final s = ReplaySummary(ReplayKind.verify, [clean, clean], 'b1', requestedAttempts: 2);
      expect(exitCodeFor(s), 0);
      expect(s.wireOutcome, 'not_reproduced');
      expect(s.runPayload()['validAttempts'], 2);
      expect(plain(summaryLines(s).join('\n')), contains('FIXED'));
    });

    test('a material divergence (missing action) is INCONCLUSIVE', () {
      final s = ReplaySummary(ReplayKind.verify, [
        report(ReplayOutcome.notReproduced, divergences: const [Divergence('action.unregistered', 'cart.pay')]),
      ], null, requestedAttempts: 1);
      expect(exitCodeFor(s), 3);
      expect(plain(summaryLines(s).join('\n')), contains('divergence action.unregistered'));
    });

    test('zero attempts is INCONCLUSIVE', () {
      final s = ReplaySummary(ReplayKind.verify, const [], null, requestedAttempts: 0);
      expect(exitCodeFor(s), 3);
      expect(s.runPayload()['attempts'], 1, reason: 'the backend requires attempts >= 1');
      expect(s.runPayload()['validAttempts'], 0);
    });

    test('STILL FAILING and FLAKY', () {
      expect(exitCodeFor(ReplaySummary(ReplayKind.verify, [reproduced, reproduced], null, requestedAttempts: 2)), 1);
      expect(exitCodeFor(ReplaySummary(ReplayKind.verify, [reproduced, clean], null, requestedAttempts: 2)), 2);
    });
  });

  group('replay summary', () {
    test('reproduced in all attempts is exit 0, partial is not', () {
      expect(exitCodeFor(ReplaySummary(ReplayKind.replay, [reproduced, reproduced], null, requestedAttempts: 2)), 0);
      expect(exitCodeFor(ReplaySummary(ReplayKind.replay, [reproduced, error], null, requestedAttempts: 2)), 3);
      expect(exitCodeFor(ReplaySummary(ReplayKind.replay, [clean, clean], null, requestedAttempts: 2)), 1);
    });
  });

  group('replayCapsule', () {
    late ReplayServer server;
    late LoadedCapsule loaded;

    setUpAll(() async {
      server = await ReplayServer.start();
      final fixture = jsonDecode(File('../../spec/fixtures/capsule-v1/valid/full.json').readAsStringSync()) as Map;
      final doc = (fixture['document'] as Map).cast<String, Object?>();
      final bytes = gzip.encode(utf8.encode(jsonEncode(doc)));
      loaded = LoadedCapsule(bytes, CapsuleCodec.decode(bytes));
    });
    tearDownAll(() => server.close());

    Future<ReplaySummary> run(ReplayKind kind, int attempts, List<ReplayReport> reports) => replayCapsule(
          loaded: loaded,
          launcher: ScriptedLauncher(reports),
          server: server,
          kind: kind,
          attempts: attempts,
          strategy: ReplayStrategy.auto,
          settleTimeoutMs: 100,
          strictNetwork: true,
        );

    test('stops at an incompatible attempt and reports INCOMPATIBLE', () async {
      final s = await run(ReplayKind.verify, 3, [clean, report(ReplayOutcome.incompatible, message: 'schema v2'), clean]);
      expect(s.attempts, 2);
      expect(s.verdict, Verdict.incompatible);
      expect(exitCodeFor(s), 3);
    });

    test('a capsule without an assertion stops early and is INCONCLUSIVE', () async {
      final s = await run(ReplayKind.verify, 3, [report(ReplayOutcome.noAssertion), clean, clean]);
      expect(s.attempts, 1);
      expect(s.verdict, Verdict.inconclusive);
      expect(s.evaluation.reasons, contains('2 of 3 requested attempts did not run'));
    });

    test('a full clean batch verifies the fix', () async {
      final s = await run(ReplayKind.verify, 3, [clean, clean, clean]);
      expect(s.verdict, Verdict.fixed);
      expect(s.runPayload()['outcome'], 'not_reproduced');
      expect((s.runPayload()['details'] as Map)['verdict'], 'fixed');
    });
  });
}
