import 'dart:io';

import 'package:bug_capsule_core/bug_capsule_core.dart';

import 'capsule_source.dart';
import 'git.dart';
import 'launcher.dart';
import 'replay_server.dart';
import 'term.dart';

enum ReplayKind { replay, verify }

/// The attempts of one `bugcapsule run` / `bugcapsule verify` and what they prove.
/// The verdict comes from [evaluateRun] (bug_capsule_core), the single source of
/// the rules for output, exit code and the result recorded on the backend.
class ReplaySummary {
  ReplaySummary(this.kind, this.reports, this.buildSha, {required this.requestedAttempts})
      : evaluation = evaluateRun(
            kind == ReplayKind.replay ? RunKind.replay : RunKind.verify, requestedAttempts, reports);

  final ReplayKind kind;
  final List<ReplayReport> reports;
  final String? buildSha;
  final int requestedAttempts;
  final RunEvaluation evaluation;

  Verdict get verdict => evaluation.verdict;

  /// Attempts that ran (may be fewer than requested).
  int get attempts => reports.length;
  int get reproductions => reports.where((r) => r.outcome == ReplayOutcome.reproduced).length;
  bool get incompatible => verdict == Verdict.incompatible;
  bool get inconclusive => verdict == Verdict.inconclusive;

  /// Outcome for the backend `runs` endpoint.
  String get wireOutcome => verdict.wire;

  int get durationMs => reports.fold(0, (s, r) => s + r.durationMs);

  /// Body of `POST /v1/capsules/{id}/runs`. `attempts` is the number
  /// requested, so attempts that never ran cannot make a run look complete.
  Map<String, Object?> runPayload({String? device}) => {
        'kind': kind.name,
        'outcome': wireOutcome,
        'attempts': requestedAttempts < 1 ? 1 : requestedAttempts,
        'reproductions': reproductions,
        'validAttempts': evaluation.validAttempts,
        'gitSha': buildSha,
        'device': device,
        'durationMs': durationMs,
        'details': {
          'verdict': verdict.name,
          'reasons': evaluation.reasons.take(50).toList(),
          'completedAttempts': attempts,
          'reports': [for (final r in reports) r.toJson()],
        },
      };
}

/// Resolves which source tree to build: the capsule's pinned commit for
/// `replay` (when available), the working tree for `verify`.
Future<(String projectDir, String? buildSha, bool dirty)> resolveTree(
  LoadedCapsule loaded, {
  required String projectDir,
  required ReplayKind kind,
  required bool? pin,
}) async {
  final git = await gitInfo(projectDir);
  final sha = loaded.capsule.manifest.gitSha;
  if (git == null) {
    stdout.writeln(yellow('! $projectDir is not a git checkout; replaying the files as they are'));
    return (projectDir, null, false);
  }
  final wantPin = kind == ReplayKind.replay && (pin ?? true) && sha != null && sha != git.head;
  if (wantPin) {
    if (await commitExists(git.root, sha)) {
      final dir = await pinnedProjectDir(git, projectDir, sha);
      stdout.writeln('Pinned to capsule commit ${shortId(sha)} ${dim('($dir)')}');
      return (dir, sha, false);
    }
    stdout.writeln(yellow('! capsule commit ${shortId(sha)} is not in this repository; '
        'replaying HEAD ${shortId(git.head)} instead'));
  } else if (kind == ReplayKind.replay && sha == null) {
    stdout.writeln(yellow('! capsule has no git SHA (build with BUGCAPSULE_GIT_SHA); replaying HEAD'));
  }
  if (git.dirty && kind == ReplayKind.replay && (pin ?? true) && sha == git.head) {
    stdout.writeln(yellow('! working tree has uncommitted changes on top of the capsule commit'));
  }
  return (projectDir, git.head, git.dirty);
}

Future<ReplaySummary> replayCapsule({
  required LoadedCapsule loaded,
  required AppLauncher launcher,
  required ReplayServer server,
  required ReplayKind kind,
  required int attempts,
  required ReplayStrategy strategy,
  required int settleTimeoutMs,
  required bool strictNetwork,
  bool idleCompression = true,
  String? buildSha,
}) async {
  final m = loaded.capsule.manifest;
  final reports = <ReplayReport>[];
  final budget = Duration(
    milliseconds: m.session.durationMs + settleTimeoutMs + 45000,
  );
  for (var i = 1; i <= attempts; i++) {
    stdout.write('  ${kind.name} ${dim('#$i')}  ');
    final report = await launcher.attempt(
      server,
      loaded.bytes,
      ReplaySettings(
        strategy: strategy,
        settleTimeoutMs: settleTimeoutMs,
        attempt: i,
        kind: kind.name,
        strictNetwork: strictNetwork,
        idleCompression: idleCompression,
      ),
      budget,
    );
    reports.add(report);
    stdout.writeln(_attemptLine(kind, report));
    if (report.outcome == ReplayOutcome.incompatible || report.outcome == ReplayOutcome.noAssertion) {
      break;
    }
  }
  return ReplaySummary(kind, reports, buildSha, requestedAttempts: attempts);
}

String _attemptLine(ReplayKind kind, ReplayReport r) {
  final skipped = r.compressedMs > 0
      ? ' (${(r.compressedMs / 1000).toStringAsFixed(1)}s idle skipped)'
      : '';
  final secs = dim('${(r.durationMs / 1000).toStringAsFixed(1)}s$skipped');
  final assessment = assessAttempt(r);
  final invalid = r.outcome == ReplayOutcome.notReproduced &&
      assessment.status == AttemptStatus.invalid;
  final label = switch (r.outcome) {
    ReplayOutcome.reproduced => kind == ReplayKind.replay ? green('REPRODUCED') : red('STILL FAILS'),
    ReplayOutcome.notReproduced when invalid => yellow('INVALID'),
    ReplayOutcome.notReproduced => kind == ReplayKind.replay ? yellow('NOT REPRODUCED') : green('PASS'),
    ReplayOutcome.incompatible => red('INCOMPATIBLE'),
    ReplayOutcome.noAssertion => yellow('NO ASSERTION'),
    ReplayOutcome.error => red('ERROR'),
  };
  final note = invalid ? assessment.reasons.first : r.message;
  final extra = note != null ? '  ${dim(note.split('\n').first)}' : '';
  return '$label  $secs  ${dim('${r.strategy.name}, ${r.eventsDispatched} inputs, ${r.fixturesServed} responses')}$extra';
}

void printSummary(ReplaySummary s, Capsule capsule) {
  stdout.writeln(summaryLines(s).join('\n'));
}

/// The verdict block printed after the attempts.
List<String> summaryLines(ReplaySummary s) {
  final lines = <String>[''];
  final n = s.requestedAttempts;
  final e = s.evaluation;
  final k = e.reproductions;
  final verdict = switch (s.verdict) {
    Verdict.incompatible => '${red('INCOMPATIBLE')} — capsule cannot run against this build',
    Verdict.inconclusive => '${yellow('INCONCLUSIVE')} — ${e.validAttempts} of $n attempts ran validly; '
        'nothing is ${s.kind == ReplayKind.verify ? 'verified' : 'concluded'}',
    Verdict.reproduced => green('REPRODUCED $k/$n'),
    Verdict.notReproduced => yellow('NOT REPRODUCED 0/$n'),
    Verdict.flaky => yellow('FLAKY $k/$n'),
    Verdict.fixed => green('FIXED — failure gone in $n/$n valid runs'),
    Verdict.stillFailing => red('STILL FAILING $k/$n'),
  };
  lines.add('${bold('Result:')} $verdict');
  if (!e.succeeded && e.reasons.isNotEmpty) {
    lines.add(bold('Why:'));
    for (final r in e.reasons.take(10)) {
      lines.add('  ${yellow('•')} $r');
    }
  }

  final divergences = <String, int>{};
  for (final r in s.reports) {
    for (final d in r.divergences) {
      divergences.update('${d.type}: ${d.detail}', (v) => v + 1, ifAbsent: () => 1);
    }
    for (final f in r.otherFailures) {
      divergences.update('other failure: ${f.signature}', (v) => v + 1, ifAbsent: () => 1);
    }
  }
  if (divergences.isNotEmpty) {
    lines.add(bold('Divergences:'));
    for (final e in divergences.entries.take(15)) {
      lines.add('  ${yellow('•')} ${e.key}${e.value > 1 ? dim(' ×${e.value}') : ''}');
    }
    if (divergences.length > 15) lines.add(dim('  … ${divergences.length - 15} more'));
  }
  final errors = s.reports.where((r) => r.outcome == ReplayOutcome.error && r.message != null);
  if (errors.isNotEmpty) lines.add(red(errors.first.message!));
  return lines;
}

/// Exit codes: 0 success (reproduced / fixed), 1 the opposite (not
/// reproduced / still failing), 2 flaky, 3 inconclusive or incompatible.
int exitCodeFor(ReplaySummary s) => s.evaluation.exitCode;
