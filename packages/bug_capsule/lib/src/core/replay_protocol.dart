import 'failure.dart';

/// HTTP protocol between the `bugcapsule` CLI (host) and an app in replay mode.
///
/// The CLI serves `GET /capsule` (the .bugcapsule bytes) and `GET /settings`
/// ([ReplaySettings] JSON), and receives `POST /result` ([ReplayReport] JSON).
/// The app learns the base URL from `BUGCAPSULE_REPLAY_URL` (dart-define or
/// process environment). Release builds never enter replay mode.
///
/// Since CLI 0.3 the base URL carries a per-attempt token
/// (`http://127.0.0.1:<port>/a/<token>`), so the paths above are relative to
/// it. The server answers only the armed attempt: requests for another token
/// get 404 and reports after the attempt closed get 410 (stale). Apps that
/// echo [ReplaySettings.attemptId] in their report are also checked against
/// it. See `spec/runtimes-v1.md`.
abstract final class ReplayProtocol {
  static const envUrl = 'BUGCAPSULE_REPLAY_URL';
  static const capsulePath = '/capsule';
  static const settingsPath = '/settings';
  static const resultPath = '/result';

  /// Printed to stdout as a fallback channel: `BUGCAPSULE_RESULT::{json}`.
  static const stdoutPrefix = 'BUGCAPSULE_RESULT::';
}

/// How replay drives user input.
/// * `pointer` — re-inject recorded touches (needs the same logical screen).
/// * `semantic` — invoke recorded semantic actions (`BugCapsule.action`).
/// * `auto` — pointer when the screen size matches, otherwise semantic.
enum ReplayStrategy { auto, pointer, semantic }

class ReplaySettings {
  const ReplaySettings({
    this.strategy = ReplayStrategy.auto,
    this.settleTimeoutMs = 8000,
    this.attempt = 1,
    this.kind = 'replay',
    this.strictNetwork = true,
    this.idleCompression = true,
    this.attemptId,
    this.runtime,
  });

  factory ReplaySettings.fromJson(Map<String, Object?> j) => ReplaySettings(
    strategy: ReplayStrategy.values.byName(j['strategy'] as String? ?? 'auto'),
    settleTimeoutMs: j['settleTimeoutMs'] as int? ?? 8000,
    attempt: j['attempt'] as int? ?? 1,
    kind: j['kind'] as String? ?? 'replay',
    strictNetwork: j['strictNetwork'] as bool? ?? true,
    idleCompression: j['idleCompression'] as bool? ?? true,
    attemptId: j['attemptId'] as String?,
    runtime: j['runtime'] as String?,
  );

  final ReplayStrategy strategy;

  /// How long to wait for the failure after the last replayed event (or after
  /// the original failure time, whichever is later).
  final int settleTimeoutMs;
  final int attempt;

  /// `replay` (expect the failure) or `verify` (expect it gone).
  final String kind;

  /// Strict: an unrecorded request fails with a connection error.
  /// Lenient: it goes to the real network.
  final bool strictNetwork;

  /// Shorten long idle gaps between inputs (see `IdleCompressor`). Recorded
  /// network latency is always kept.
  final bool idleCompression;

  /// Identifies the attempt (CLI 0.3+). Apps echo it in [ReplayReport.attemptId].
  final String? attemptId;

  /// Runtime the CLI launched (`flutter`, `android`, `ios`, `web`).
  final String? runtime;

  Map<String, Object?> toJson() => {
    'strategy': strategy.name,
    'settleTimeoutMs': settleTimeoutMs,
    'attempt': attempt,
    'kind': kind,
    'strictNetwork': strictNetwork,
    'idleCompression': idleCompression,
    if (attemptId != null) 'attemptId': attemptId,
    if (runtime != null) 'runtime': runtime,
  };
}

/// The attempt result for an app death (crash-capsules §4), given the
/// capsule's [expected] failure. Reports without [ReplayReport.crash], and
/// reports where the expected failure had already fired, are unchanged.
///
/// * A crash capsule, the same type → `reproduced`; a different in-app
///   frame (when both are known) is divergence `failure.different_frame`.
/// * Another type, or any capsule whose failure is not a crash → the
///   death is another failure: the attempt proves nothing (reason code
///   `failure.different`).
/// * The cause is unknown → a replay error.
ReplayReport resolveCrash(ReplayReport report, FailureRecord? expected) {
  final crash = report.crash;
  if (crash == null || report.outcome == ReplayOutcome.reproduced) {
    return report;
  }
  final what = crash.name;
  if (what == null) {
    return report.copyWith(
      outcome: ReplayOutcome.error,
      message:
          'the app process died during the attempt and the cause is unknown'
          '${report.message == null ? '' : ': ${report.message}'}',
    );
  }
  final observed = crash.toFailure();
  if (expected != null &&
      expected.kind == FailureKind.crash &&
      crash.sameTypeAs(expected)) {
    final wantFrame = expected.crash?.inAppFrame;
    final differentFrame =
        wantFrame != null &&
        crash.inAppFrame != null &&
        crash.inAppFrame != wantFrame;
    return report.copyWith(
      outcome: ReplayOutcome.reproduced,
      expectedSignature: expected.signature,
      observed: observed,
      divergences: [
        ...report.divergences,
        if (differentFrame)
          Divergence(
            'failure.different_frame',
            'crashed in ${crash.inAppFrame}, recorded in $wantFrame',
          ),
      ],
      message: 'the app died with $what as recorded',
    );
  }
  return report.copyWith(
    outcome: ReplayOutcome.notReproduced,
    expectedSignature: expected?.signature,
    otherFailures: [...report.otherFailures, observed],
    message: expected?.kind == FailureKind.crash
        ? 'the app died with $what; the capsule recorded ${expected!.type}'
        : 'the app died with $what',
  );
}

enum ReplayOutcome {
  /// The original failure assertion fired again.
  reproduced('reproduced'),

  /// Replay completed without the original failure.
  notReproduced('not_reproduced'),

  /// The capsule cannot run against this build (spec/schema mismatch).
  incompatible('incompatible'),

  /// The capsule has no failure assertion; replay ran but proves nothing.
  noAssertion('no_assertion'),

  /// Replay itself broke.
  error('error');

  const ReplayOutcome(this.wire);
  final String wire;

  static ReplayOutcome parse(String wire) => values.firstWhere(
    (o) => o.wire == wire,
    orElse: () => ReplayOutcome.error,
  );
}

class Divergence {
  const Divergence(this.type, this.detail, {this.t});

  factory Divergence.fromJson(Map<String, Object?> j) =>
      Divergence(j['type'] as String, j['detail'] as String, t: j['t'] as int?);

  /// e.g. `network.unrecorded`, `network.reused`, `action.unregistered`,
  /// `build.gitSha`, `failure.other`, `bloc.unrestored`.
  final String type;
  final String detail;
  final int? t;

  Map<String, Object?> toJson() => {
    'type': type,
    'detail': detail,
    if (t != null) 't': t,
  };

  @override
  String toString() => '$type: $detail';
}

/// The app under test died during an attempt (crash-capsules §4), as a
/// runner or the CLI saw it.
class ObservedCrash {
  const ObservedCrash({
    this.type,
    this.mechanism,
    this.signal,
    this.inAppFrame,
    this.source,
    this.message,
  });

  factory ObservedCrash.fromJson(Map<String, Object?> j) => ObservedCrash(
    type: j['type'] as String?,
    mechanism: j['mechanism'] as String?,
    signal: (j['signal'] as num?)?.toInt(),
    inAppFrame: j['inAppFrame'] as String?,
    source: j['source'] as String?,
    message: j['message'] as String?,
  );

  /// Same vocabulary as `failure.type` of a crash capsule: the signal name
  /// (`SIGSEGV`), the Mach exception (`EXC_BAD_ACCESS`),
  /// `ApplicationNotResponding`, `OutOfMemory`, or an exception class for
  /// a managed crash. Null: the process died and why is unknown.
  final String? type;

  /// `signal`, `mach_exception`, `anr`, `oom`, `exception`.
  final String? mechanism;
  final int? signal;

  /// Function of the in-app frame closest to the crash, when the frames
  /// were visible.
  final String? inAppFrame;

  /// How the death was seen: `xctest`, `instrumentation`, `exit_info`,
  /// `tombstone`, `logcat`, `crash_report`, `process_exit`.
  final String? source;
  final String? message;

  /// [type], or the signal's name when only the number is known.
  String? get name => type ?? (signal == null ? null : signalName(signal!));

  /// Whether this is the death a crash capsule recorded as [expected]
  /// (`failure.type`): the same type, or the same signal (an iOS crash
  /// report names both the Mach exception and the signal).
  bool sameTypeAs(FailureRecord expected) {
    final expectedSignal = expected.crash?.signal;
    final mine = {?type, if (signal != null) signalName(signal!)};
    final theirs = {
      expected.type,
      if (expectedSignal != null) signalName(expectedSignal),
    };
    return mine.any(theirs.contains);
  }

  /// The death as a failure record (`crash:<type>`).
  FailureRecord toFailure() => FailureRecord.crash(
    type: name ?? 'ProcessDied',
    message: message ?? 'the app process died',
    t: 0,
    crash: CrashInfo(
      mechanism: mechanism ?? 'signal',
      signal: signal,
      inAppFrame: inAppFrame,
    ),
  );

  Map<String, Object?> toJson() => {
    'type': ?type,
    'mechanism': ?mechanism,
    'signal': ?signal,
    'inAppFrame': ?inAppFrame,
    'source': ?source,
    'message': ?message,
  };

  static const _signals = {
    1: 'SIGHUP',
    2: 'SIGINT',
    3: 'SIGQUIT',
    4: 'SIGILL',
    5: 'SIGTRAP',
    6: 'SIGABRT',
    7: 'SIGBUS',
    8: 'SIGFPE',
    9: 'SIGKILL',
    10: 'SIGBUS',
    11: 'SIGSEGV',
    12: 'SIGSYS',
    13: 'SIGPIPE',
    15: 'SIGTERM',
  };

  /// POSIX names of the common fatal signals (Linux numbering, and SIGBUS
  /// is 10 on Darwin).
  static String signalName(int signal) => _signals[signal] ?? 'SIG$signal';
}

class ReplayReport {
  const ReplayReport({
    required this.outcome,
    required this.attempt,
    required this.durationMs,
    required this.strategy,
    this.expectedSignature,
    this.observed,
    this.otherFailures = const [],
    this.divergences = const [],
    this.eventsDispatched = 0,
    this.eventsExpected,
    this.fixturesServed = 0,
    this.compressedMs = 0,
    this.gapsCompressed = 0,
    this.buildGitSha,
    this.message,
    this.attemptId,
    this.runtime,
    this.crash,
  });

  factory ReplayReport.fromJson(Map<String, Object?> j) => ReplayReport(
    outcome: ReplayOutcome.parse(j['outcome'] as String),
    attempt: j['attempt'] as int? ?? 1,
    durationMs: j['durationMs'] as int? ?? 0,
    strategy: ReplayStrategy.values.byName(j['strategy'] as String? ?? 'auto'),
    expectedSignature: j['expectedSignature'] as String?,
    observed: j['observed'] == null
        ? null
        : FailureRecord.fromJson(
            (j['observed'] as Map).cast<String, Object?>(),
          ),
    otherFailures: [
      for (final f in (j['otherFailures'] as List?) ?? const [])
        FailureRecord.fromJson((f as Map).cast<String, Object?>()),
    ],
    divergences: [
      for (final d in (j['divergences'] as List?) ?? const [])
        Divergence.fromJson((d as Map).cast<String, Object?>()),
    ],
    eventsDispatched: j['eventsDispatched'] as int? ?? 0,
    eventsExpected: j['eventsExpected'] as int?,
    fixturesServed: j['fixturesServed'] as int? ?? 0,
    compressedMs: j['compressedMs'] as int? ?? 0,
    gapsCompressed: j['gapsCompressed'] as int? ?? 0,
    buildGitSha: j['buildGitSha'] as String?,
    message: j['message'] as String?,
    attemptId: j['attemptId'] as String?,
    runtime: j['runtime'] as String?,
    crash: j['crash'] is Map
        ? ObservedCrash.fromJson((j['crash'] as Map).cast<String, Object?>())
        : null,
  );

  final ReplayOutcome outcome;
  final int attempt;
  final int durationMs;
  final ReplayStrategy strategy;
  final String? expectedSignature;
  final FailureRecord? observed;
  final List<FailureRecord> otherFailures;
  final List<Divergence> divergences;
  final int eventsDispatched;

  /// Recorded inputs this attempt should have dispatched; null from SDKs
  /// that predate the field. A run without the failure is only conclusive
  /// when every one of them was dispatched.
  final int? eventsExpected;
  final int fixturesServed;

  /// Recorded idle time skipped by idle compression; [durationMs] plus this
  /// is roughly the real-time length of the replay.
  final int compressedMs;
  final int gapsCompressed;
  final String? buildGitSha;
  final String? message;

  /// Echo of [ReplaySettings.attemptId]; null from SDKs that predate it.
  final String? attemptId;

  /// Runtime that ran the attempt.
  final String? runtime;

  /// The app process died during the attempt. The CLI turns it into the
  /// attempt's outcome ([resolveCrash]).
  final ObservedCrash? crash;

  /// A copy with the given fields replaced.
  ReplayReport copyWith({
    ReplayOutcome? outcome,
    String? expectedSignature,
    FailureRecord? observed,
    List<FailureRecord>? otherFailures,
    List<Divergence>? divergences,
    String? message,
    ObservedCrash? crash,
  }) => ReplayReport(
    outcome: outcome ?? this.outcome,
    attempt: attempt,
    durationMs: durationMs,
    strategy: strategy,
    expectedSignature: expectedSignature ?? this.expectedSignature,
    observed: observed ?? this.observed,
    otherFailures: otherFailures ?? this.otherFailures,
    divergences: divergences ?? this.divergences,
    eventsDispatched: eventsDispatched,
    eventsExpected: eventsExpected,
    fixturesServed: fixturesServed,
    compressedMs: compressedMs,
    gapsCompressed: gapsCompressed,
    buildGitSha: buildGitSha,
    message: message ?? this.message,
    attemptId: attemptId,
    runtime: runtime,
    crash: crash ?? this.crash,
  );

  /// Same report with [divergences] appended (e.g. by a runner that saw
  /// requests escape the app's network hooks).
  ReplayReport withDivergences(List<Divergence> extra) =>
      copyWith(divergences: [...divergences, ...extra]);

  Map<String, Object?> toJson() => {
    'outcome': outcome.wire,
    'attempt': attempt,
    'durationMs': durationMs,
    'strategy': strategy.name,
    'expectedSignature': expectedSignature,
    'observed': observed?.toJson(),
    'otherFailures': [for (final f in otherFailures) f.toJson()],
    'divergences': [for (final d in divergences) d.toJson()],
    'eventsDispatched': eventsDispatched,
    'eventsExpected': eventsExpected,
    'fixturesServed': fixturesServed,
    'compressedMs': compressedMs,
    'gapsCompressed': gapsCompressed,
    'buildGitSha': buildGitSha,
    'message': message,
    if (attemptId != null) 'attemptId': attemptId,
    if (runtime != null) 'runtime': runtime,
    if (crash != null) 'crash': crash!.toJson(),
  };
}
