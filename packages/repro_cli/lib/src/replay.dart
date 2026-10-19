import 'dart:io';

import 'package:repro_core/repro_core.dart';

import 'capsule_source.dart';
import 'git.dart';
import 'launcher.dart';
import 'replay_server.dart';
import 'term.dart';

enum ReplayKind { replay, verify }

class ReplaySummary {
  ReplaySummary(this.kind, this.reports, this.buildSha);

  final ReplayKind kind;
  final List<ReplayReport> reports;
  final String? buildSha;

  int get attempts => reports.length;
  int get reproductions => reports.where((r) => r.outcome == ReplayOutcome.reproduced).length;
  bool get incompatible => reports.any((r) => r.outcome == ReplayOutcome.incompatible);
  bool get errored => reports.every((r) => r.outcome == ReplayOutcome.error);
  bool get noAssertion => reports.any((r) => r.outcome == ReplayOutcome.noAssertion);

  /// Wire outcome for the backend `runs` endpoint.
  String get wireOutcome => incompatible
      ? 'incompatible'
      : errored
          ? 'error'
          : reproductions > 0
              ? 'reproduced'
              : 'not_reproduced';

  int get durationMs => reports.fold(0, (s, r) => s + r.durationMs);
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
    stdout.writeln(yellow('! capsule has no git SHA (build with REPRO_GIT_SHA); replaying HEAD'));
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
      ),
      budget,
    );
    reports.add(report);
    stdout.writeln(_attemptLine(kind, report));
    if (report.outcome == ReplayOutcome.incompatible || report.outcome == ReplayOutcome.noAssertion) {
      break;
    }
  }
  return ReplaySummary(kind, reports, buildSha);
}

String _attemptLine(ReplayKind kind, ReplayReport r) {
  final secs = dim('${(r.durationMs / 1000).toStringAsFixed(1)}s');
  final label = switch (r.outcome) {
    ReplayOutcome.reproduced => kind == ReplayKind.replay ? green('REPRODUCED') : red('STILL FAILS'),
    ReplayOutcome.notReproduced => kind == ReplayKind.replay ? yellow('NOT REPRODUCED') : green('PASS'),
    ReplayOutcome.incompatible => red('INCOMPATIBLE'),
    ReplayOutcome.noAssertion => yellow('NO ASSERTION'),
    ReplayOutcome.error => red('ERROR'),
  };
  final extra = r.message != null ? '  ${dim(r.message!.split('\n').first)}' : '';
  return '$label  $secs  ${dim('${r.strategy.name}, ${r.eventsDispatched} inputs, ${r.fixturesServed} responses')}$extra';
}

void printSummary(ReplaySummary s, Capsule capsule) {
  stdout.writeln();
  final n = s.attempts;
  final k = s.reproductions;
  String verdict;
  if (s.incompatible) {
    verdict = '${red('INCOMPATIBLE')} — capsule cannot run against this build';
  } else if (s.noAssertion) {
    verdict = '${yellow('NO ASSERTION')} — capsule has no failure to check; replay ran for inspection only';
  } else if (s.errored) {
    verdict = '${red('ERROR')} — replay did not complete';
  } else if (s.kind == ReplayKind.replay) {
    verdict = k == n
        ? green('REPRODUCED $k/$n')
        : k == 0
            ? yellow('NOT REPRODUCED 0/$n')
            : yellow('FLAKY $k/$n');
  } else {
    verdict = k == 0 ? green('FIXED — failure gone in $n/$n runs') : red('STILL FAILING $k/$n');
  }
  stdout.writeln('${bold('Result:')} $verdict');

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
    stdout.writeln(bold('Divergences:'));
    for (final e in divergences.entries.take(15)) {
      stdout.writeln('  ${yellow('•')} ${e.key}${e.value > 1 ? dim(' ×${e.value}') : ''}');
    }
    if (divergences.length > 15) stdout.writeln(dim('  … ${divergences.length - 15} more'));
  }
  final errors = s.reports.where((r) => r.outcome == ReplayOutcome.error && r.message != null);
  if (errors.isNotEmpty) stdout.writeln(red(errors.first.message!));
}

/// Exit codes: 0 success, 1 opposite of expected, 2 flaky, 3 error/incompatible.
int exitCodeFor(ReplaySummary s) {
  if (s.incompatible || s.errored || s.noAssertion) return 3;
  final k = s.reproductions;
  if (s.kind == ReplayKind.replay) return k == s.attempts ? 0 : (k == 0 ? 1 : 2);
  return k == 0 ? 0 : 1;
}
