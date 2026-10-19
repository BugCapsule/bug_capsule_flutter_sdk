import 'failure.dart';

/// HTTP protocol between the `repro` CLI (host) and an app in replay mode.
///
/// The CLI serves `GET /capsule` (the .repro bytes) and `GET /settings`
/// ([ReplaySettings] JSON), and receives `POST /result` ([ReplayReport] JSON).
/// The app learns the base URL from `REPRO_REPLAY_URL` (dart-define or
/// process environment). Release builds never enter replay mode.
abstract final class ReplayProtocol {
  static const envUrl = 'REPRO_REPLAY_URL';
  static const capsulePath = '/capsule';
  static const settingsPath = '/settings';
  static const resultPath = '/result';

  /// Printed to stdout as a fallback channel: `REPRO_RESULT::{json}`.
  static const stdoutPrefix = 'REPRO_RESULT::';
}

/// How replay drives user input.
/// * `pointer` — re-inject recorded touches (needs the same logical screen).
/// * `semantic` — invoke recorded semantic actions (`Repro.action`).
/// * `auto` — pointer when the screen size matches, otherwise semantic.
enum ReplayStrategy { auto, pointer, semantic }

class ReplaySettings {
  const ReplaySettings({
    this.strategy = ReplayStrategy.auto,
    this.settleTimeoutMs = 8000,
    this.attempt = 1,
    this.kind = 'replay',
    this.strictNetwork = true,
  });

  factory ReplaySettings.fromJson(Map<String, Object?> j) => ReplaySettings(
        strategy: ReplayStrategy.values.byName(j['strategy'] as String? ?? 'auto'),
        settleTimeoutMs: j['settleTimeoutMs'] as int? ?? 8000,
        attempt: j['attempt'] as int? ?? 1,
        kind: j['kind'] as String? ?? 'replay',
        strictNetwork: j['strictNetwork'] as bool? ?? true,
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

  Map<String, Object?> toJson() => {
        'strategy': strategy.name,
        'settleTimeoutMs': settleTimeoutMs,
        'attempt': attempt,
        'kind': kind,
        'strictNetwork': strictNetwork,
      };
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

  static ReplayOutcome parse(String wire) =>
      values.firstWhere((o) => o.wire == wire, orElse: () => ReplayOutcome.error);
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

  Map<String, Object?> toJson() => {'type': type, 'detail': detail, if (t != null) 't': t};

  @override
  String toString() => '$type: $detail';
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
    this.fixturesServed = 0,
    this.buildGitSha,
    this.message,
  });

  factory ReplayReport.fromJson(Map<String, Object?> j) => ReplayReport(
        outcome: ReplayOutcome.parse(j['outcome'] as String),
        attempt: j['attempt'] as int? ?? 1,
        durationMs: j['durationMs'] as int? ?? 0,
        strategy: ReplayStrategy.values.byName(j['strategy'] as String? ?? 'auto'),
        expectedSignature: j['expectedSignature'] as String?,
        observed: j['observed'] == null
            ? null
            : FailureRecord.fromJson((j['observed'] as Map).cast<String, Object?>()),
        otherFailures: [
          for (final f in (j['otherFailures'] as List?) ?? const [])
            FailureRecord.fromJson((f as Map).cast<String, Object?>()),
        ],
        divergences: [
          for (final d in (j['divergences'] as List?) ?? const [])
            Divergence.fromJson((d as Map).cast<String, Object?>()),
        ],
        eventsDispatched: j['eventsDispatched'] as int? ?? 0,
        fixturesServed: j['fixturesServed'] as int? ?? 0,
        buildGitSha: j['buildGitSha'] as String?,
        message: j['message'] as String?,
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
  final int fixturesServed;
  final String? buildGitSha;
  final String? message;

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
        'fixturesServed': fixturesServed,
        'buildGitSha': buildGitSha,
        'message': message,
      };
}
