import 'dart:convert';

import 'replay.dart';
import 'term.dart';

/// The release gate (verification.md §3): what a build of a release must not
/// reproduce, and how `bugcapsule gate` turns the verify runs into a report,
/// a table, JUnit XML, JSON and an exit code. The command itself is
/// `GateCommand` in `commands.dart`.

/// One capsule of `GET /v1/verification/plan`.
class GateItem {
  const GateItem({
    required this.capsuleId,
    required this.reason,
    this.issueId,
    this.issueTitle,
    this.runtime,
    this.status,
    this.eligibility,
  });

  factory GateItem.fromJson(Map<String, Object?> j) => GateItem(
    capsuleId: j['capsuleId'] as String,
    reason: j['reason'] as String? ?? 'fix',
    issueId: j['issueId'] as String?,
    issueTitle: j['issueTitle'] as String?,
    runtime: (j['runtime'] ?? j['platform']) as String?,
    status: j['status'] as String?,
    eligibility: j['eligibility'] as String?,
  );

  final String capsuleId;

  /// `fix` (a fix this release claims) or `regression` (fixed earlier, must
  /// stay fixed).
  final String reason;
  final String? issueId;
  final String? issueTitle;
  final String? runtime;
  final String? status;
  final String? eligibility;
}

/// What verifying one [GateItem] gave.
class GateResult {
  const GateResult(
    this.item,
    this.outcome, {
    this.runId,
    this.summary,
    this.error,
    this.durationMs = 0,
  });

  final GateItem item;

  /// The run outcome: `not_reproduced` (stays fixed), `reproduced`, `flaky`,
  /// `inconclusive`, `incompatible` or `error` (it could not run).
  final String outcome;
  final String? runId;
  final ReplaySummary? summary;

  /// Why it could not run, for `error`.
  final String? error;
  final int durationMs;

  bool get passed => outcome == GateOutcomes.notReproduced;
  bool get couldNotRun => GateOutcomes.couldNotRun.contains(outcome);

  /// Why it did not pass, for output.
  List<String> get reasons => [?error, ...?summary?.evaluation.reasons];

  Map<String, Object?> toReportJson() => {
    'capsuleId': item.capsuleId,
    'runId': runId,
    'reason': item.reason,
    'outcome': outcome,
  };

  Map<String, Object?> toJson() => {
    'capsuleId': item.capsuleId,
    'issueId': item.issueId,
    'issueTitle': item.issueTitle,
    'reason': item.reason,
    'outcome': outcome,
    'runId': runId,
    if (summary != null) ...{
      'attempts': summary!.requestedAttempts,
      'reproductions': summary!.reproductions,
      'validAttempts': summary!.evaluation.validAttempts,
      'reasonCodes': summary!.evaluation.reasonCodes,
    },
    'reasons': reasons.take(20).toList(),
    'durationMs': durationMs,
  };
}

abstract final class GateOutcomes {
  static const notReproduced = 'not_reproduced';
  static const reproduced = 'reproduced';
  static const flaky = 'flaky';
  static const error = 'error';
  static const couldNotRun = {'inconclusive', 'incompatible', 'error'};

  /// Values of `--fail-on`.
  static const failOnValues = ['reproduced', 'flaky', 'error'];
  static const defaultFailOn = ['reproduced', 'flaky'];

  /// Whether [outcome] fails the gate under [failOn].
  static bool fails(String outcome, Set<String> failOn) => switch (outcome) {
    reproduced => failOn.contains('reproduced'),
    flaky => failOn.contains('flaky'),
    notReproduced => false,
    _ => failOn.contains('error'),
  };
}

/// verification.md §3.3: 0 passed; 1 an item `reproduced`; 2 an item
/// `flaky` (only with `flaky` in [failOn]); 3 an item could not run and
/// `error` is in [failOn]. The most serious applies. (64 usage and 1
/// backend errors are the command's.)
int gateExitCode(Iterable<GateResult> results, Set<String> failOn) {
  bool any(bool Function(GateResult r) test) => results.any(test);
  if (failOn.contains('reproduced') &&
      any((r) => r.outcome == GateOutcomes.reproduced)) {
    return 1;
  }
  if (failOn.contains('flaky') && any((r) => r.outcome == GateOutcomes.flaky)) {
    return 2;
  }
  if (failOn.contains('error') && any((r) => r.couldNotRun)) return 3;
  return 0;
}

/// Body of `POST /v1/verification/reports`.
Map<String, Object?> gateReport({
  required String release,
  required String platform,
  required List<GateResult> results,
  required bool passed,
  required DateTime startedAt,
  required DateTime finishedAt,
  String? gitSha,
}) => {
  'release': release,
  'platform': platform,
  'gitSha': gitSha != null && gitSha.length > 64
      ? gitSha.substring(0, 64)
      : gitSha,
  'startedAt': startedAt.toUtc().toIso8601String(),
  'finishedAt': finishedAt.toUtc().toIso8601String(),
  'results': [for (final r in results.take(200)) r.toReportJson()],
  'passed': passed,
};

String _cell(String s, int width) {
  final one = s.replaceAll('\n', ' ');
  return one.length <= width
      ? one.padRight(width)
      : '${one.substring(0, width - 1)}…';
}

/// The table `bugcapsule gate` prints: capsule, issue, reason, outcome.
List<String> gateTable(List<GateResult> results, Set<String> failOn) {
  final lines = [
    bold(
      '${_cell('CAPSULE', 10)}  ${_cell('ISSUE', 44)}  ${_cell('REASON', 10)}  OUTCOME',
    ),
  ];
  for (final r in results) {
    final fails = GateOutcomes.fails(r.outcome, failOn);
    final outcome = r.passed
        ? green(r.outcome)
        : fails
        ? red(r.outcome)
        : yellow(r.outcome);
    final runs = r.summary == null
        ? ''
        : dim(
            '  ${r.summary!.reproductions}/${r.summary!.requestedAttempts} reproduced',
          );
    lines.add(
      '${_cell(shortId(r.item.capsuleId), 10)}  '
      '${_cell(r.item.issueTitle ?? r.item.issueId ?? '-', 44)}  '
      '${_cell(r.item.reason, 10)}  $outcome$runs',
    );
  }
  return lines;
}

String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
    // Characters XML 1.0 does not allow.
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

/// JUnit XML of a gate: one `<testcase name="<issue title> (<capsule id>)">`
/// per item, a `<failure>` for outcomes in [failOn], `<skipped>` for items
/// that could not run otherwise.
String gateJunit({
  required String release,
  required String platform,
  required List<GateResult> results,
  required Set<String> failOn,
  required DateTime startedAt,
  required DateTime finishedAt,
  String? gitSha,
  bool truncated = false,
}) {
  final failures = results
      .where((r) => GateOutcomes.fails(r.outcome, failOn))
      .length;
  final skipped = results
      .where((r) => r.couldNotRun && !GateOutcomes.fails(r.outcome, failOn))
      .length;
  final seconds = (finishedAt.difference(startedAt).inMilliseconds / 1000)
      .toStringAsFixed(3);
  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<testsuites name="bugcapsule gate" tests="${results.length}" '
      'failures="$failures" errors="0" skipped="$skipped" time="$seconds">',
    )
    ..writeln(
      '  <testsuite name="${_xml('bugcapsule gate $release ($platform)')}" '
      'tests="${results.length}" failures="$failures" errors="0" '
      'skipped="$skipped" time="$seconds" '
      'timestamp="${startedAt.toUtc().toIso8601String()}">',
    )
    ..writeln('    <properties>')
    ..writeln('      <property name="release" value="${_xml(release)}"/>')
    ..writeln('      <property name="platform" value="${_xml(platform)}"/>');
  if (gitSha != null) {
    out.writeln('      <property name="gitSha" value="${_xml(gitSha)}"/>');
  }
  if (truncated) {
    out.writeln('      <property name="truncated" value="true"/>');
  }
  out.writeln('    </properties>');
  for (final r in results) {
    final title = r.item.issueTitle ?? r.item.issueId ?? 'capsule';
    final name = _xml('$title (${r.item.capsuleId})');
    final time = (r.durationMs / 1000).toStringAsFixed(3);
    out.write(
      '    <testcase classname="bugcapsule.gate.${_xml(r.item.reason)}" '
      'name="$name" time="$time"',
    );
    final detail = _xml(
      [
        'outcome: ${r.outcome}',
        if (r.summary != null)
          '${r.summary!.reproductions}/${r.summary!.requestedAttempts} attempts reproduced the failure',
        ...r.reasons.take(10),
        if (r.runId != null) 'run: ${r.runId}',
      ].join('\n'),
    );
    if (GateOutcomes.fails(r.outcome, failOn)) {
      final message = switch (r.outcome) {
        GateOutcomes.reproduced => 'the fixed failure reproduced',
        GateOutcomes.flaky => 'the failure reproduced in some attempts',
        _ => 'could not verify (${r.outcome})',
      };
      out
        ..writeln('>')
        ..writeln(
          '      <failure type="${_xml(r.outcome)}" message="${_xml(message)}">$detail</failure>',
        )
        ..writeln('    </testcase>');
    } else if (r.couldNotRun) {
      out
        ..writeln('>')
        ..writeln(
          '      <skipped message="${_xml('could not verify (${r.outcome})')}"/>',
        )
        ..writeln('      <system-out>$detail</system-out>')
        ..writeln('    </testcase>');
    } else if (!r.passed) {
      out
        ..writeln('>')
        ..writeln('      <system-out>$detail</system-out>')
        ..writeln('    </testcase>');
    } else {
      out.writeln('/>');
    }
  }
  out
    ..writeln('  </testsuite>')
    ..writeln('</testsuites>');
  return out.toString();
}

/// The `--json` document.
String gateJson({
  required String release,
  required String platform,
  required String scope,
  required List<GateResult> results,
  required bool passed,
  required int exitCode,
  String? gitSha,
  String? reportId,
  bool truncated = false,
  List<String> errors = const [],
}) => const JsonEncoder.withIndent('  ').convert({
  'release': release,
  'platform': platform,
  'scope': scope,
  'gitSha': gitSha,
  'passed': passed,
  // The plan left capsules out (10 per issue, 200 in all): not all were checked.
  'truncated': truncated,
  'exitCode': exitCode,
  'reportId': reportId,
  'total': results.length,
  'failed': results.where((r) => !r.passed).length,
  'results': [for (final r in results) r.toJson()],
  if (errors.isNotEmpty) 'errors': errors,
});
