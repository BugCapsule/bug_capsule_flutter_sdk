import 'dart:async';
import 'dart:convert';

import '../core/core.dart';
import 'config.dart';
import 'integration.dart';
import 'interactions.dart';

/// Runs interaction adapters outside an app: capture into a list of
/// events, then replay those events offline, the way the runtime does.
/// Used by BugCapsule's own adapter tests and by [AdapterConformance], so
/// app teams can qualify adapters they write for unsupported SDKs.
class InteractionHarness implements InteractionSession, ReplayContext {
  InteractionHarness._({
    required this.isRecording,
    required List<BugCapsuleEvent> events,
    List<CapsuleDependency> dependencies = const [],
    Redactor? redactor,
    InteractionLimits limits = const InteractionLimits(),
  }) : redactor = redactor ?? Redactor(),
       interactions = InteractionHost(limits: limits),
       _events = events,
       _dependencies = dependencies {
    if (dependencies.isNotEmpty) {
      final served = {
        for (final d in dependencies)
          if (d.required) d.id,
      };
      interactions.replay = ReplayInteractions(
        InteractionScript(events, dependencies: served, clock: now),
        dependencies: served,
        diverge: diverge,
        activity: activity,
      );
    }
  }

  /// A session that records.
  factory InteractionHarness.capture({
    Redactor? redactor,
    InteractionLimits limits = const InteractionLimits(),
  }) => InteractionHarness._(
    isRecording: true,
    events: [],
    redactor: redactor,
    limits: limits,
  );

  /// A replay of [events] serving [dependencies].
  factory InteractionHarness.replay(
    List<BugCapsuleEvent> events, {
    required List<CapsuleDependency> dependencies,
    Redactor? redactor,
  }) => InteractionHarness._(
    isRecording: false,
    events: events,
    dependencies: dependencies,
    redactor: redactor,
  );

  @override
  final bool isRecording;
  @override
  final Redactor redactor;
  @override
  final InteractionHost interactions;
  final List<BugCapsuleEvent> _events;
  final List<CapsuleDependency> _dependencies;
  final List<Divergence> divergences = [];
  final Stopwatch _clock = Stopwatch()..start();
  final List<BugCapsuleIntegration> _integrations = [];

  /// Recorded events (capture) or the events being replayed.
  List<BugCapsuleEvent> get events => List.unmodifiable(_events);

  /// Sets up [integrations] against this session (and, when replaying,
  /// starts the replay clock).
  Future<void> setUp(List<BugCapsuleIntegration> integrations) async {
    for (final i in integrations) {
      _integrations.add(i);
      await i.setUp(this);
    }
    interactions.replay?.runStarted();
  }

  /// The `manifest.dependencies` of everything captured so far.
  List<CapsuleDependency> dependencies() {
    final window = RecordedWindow(
      checkpoint: const Checkpoint(
        kind: CheckpointKind.launch,
        t: 0,
        wallClockMs: 0,
        afterSeq: 0,
      ),
      events: _events,
      droppedEvents: 0,
      hasGap: false,
    );
    return [
      for (final i in _integrations.whereType<InteractionIntegration>())
        ?i.dependency(window),
    ];
  }

  /// Eligibility gaps the adapters report for what was captured.
  Eligibility eligibility() {
    final window = RecordedWindow(
      checkpoint: const Checkpoint(
        kind: CheckpointKind.launch,
        t: 0,
        wallClockMs: 0,
        afterSeq: 0,
      ),
      events: _events,
      droppedEvents: 0,
      hasGap: false,
    );
    final b = EligibilityBuilder();
    for (final i in _integrations) {
      i.describeEligibility(b, window);
    }
    return b.build();
  }

  /// Ends a replay: reports unmatched interactions and returns every
  /// divergence.
  List<Divergence> finish({int? failureT}) {
    interactions.replay?.finish(failureT);
    return List.unmodifiable(divergences);
  }

  /// Round-trips the captured events through the capsule JSON encoding, as
  /// an upload and download would.
  List<BugCapsuleEvent> encodedEvents() => [
    for (final e in _events)
      BugCapsuleEvent.fromJson(
        (jsonDecode(jsonEncode(e.toJson())) as Map).cast<String, Object?>(),
      ),
  ];

  // ------------------------------------------------------ BugCapsuleSession

  @override
  BugCapsuleConfig get config => const BugCapsuleConfig();
  @override
  CaptureMode get mode => CaptureMode.debug;
  @override
  bool get isReplaying => !isRecording;
  @override
  bool get captureNetworkBodies => true;
  @override
  int get maxBodyBytes => 256 * 1024;
  @override
  int now() => _clock.elapsedMilliseconds;

  @override
  void record(String type, [Map<String, Object?> data = const {}]) {
    if (!isRecording) return;
    _events.add(
      BugCapsuleEvent(
        seq: _events.length + 1,
        t: now(),
        type: type,
        data: data,
      ),
    );
  }

  @override
  ReplayContext? get replay => isRecording ? null : this;

  @override
  void reportError(Object error, StackTrace? stack) {}

  // ---------------------------------------------------------- ReplayContext

  @override
  Capsule get capsule => throw UnsupportedError('no capsule in the harness');
  @override
  ReplaySettings get settings => const ReplaySettings();
  @override
  late final FixtureStore fixtures = FixtureStore(_events);
  @override
  void diverge(String type, String detail) =>
      divergences.add(Divergence(type, detail, t: now()));
  @override
  void fixtureServed() {}
  @override
  void Function() beginWork() => () {};
  @override
  void activity() {}

  List<CapsuleDependency> get replayedDependencies => _dependencies;
}

/// Result of [AdapterConformance.run].
class AdapterConformanceResult {
  const AdapterConformanceResult({
    required this.captured,
    required this.replayed,
    required this.events,
    required this.dependencies,
    required this.divergences,
    required this.eligibility,
  });

  /// What the scenario returned against the real (or fake) dependency.
  final Object? captured;

  /// What it returned during offline replay.
  final Object? replayed;
  final List<BugCapsuleEvent> events;
  final List<CapsuleDependency> dependencies;
  final List<Divergence> divergences;
  final Eligibility eligibility;

  /// Problems that disqualify the adapter for the scenario: replay did not
  /// return what capture returned, a divergence occurred, or nothing was
  /// recorded.
  List<String> get problems => [
    if (events.isEmpty) 'the scenario recorded no interaction events',
    if (dependencies.isEmpty) 'no manifest dependency was produced',
    if (canonicalJson(captured) != canonicalJson(replayed))
      'replay returned ${jsonEncode(replayed)}, capture returned ${jsonEncode(captured)}',
    for (final d in divergences) 'divergence ${d.type}: ${d.detail}',
  ];
}

/// Conformance check for an interaction adapter (capsule-v2): runs a
/// scenario against the dependency while capturing, encodes the events as
/// a capsule would, replays the scenario offline with a fresh adapter, and
/// compares what the app saw.
///
/// ```dart
/// final result = await AdapterConformance.run(
///   create: (replaying) => WeatherAdapter(api: replaying ? ThrowingApi() : FakeApi()),
///   scenario: (adapter) async => (await adapter.forecast('Oslo')).toJson(),
/// );
/// expect(result.problems, isEmpty);
/// ```
///
/// `create(true)` should wire a dependency that fails if it is called, so
/// the check also proves replay never reaches the real SDK.
abstract final class AdapterConformance {
  static Future<AdapterConformanceResult>
  run<A extends InteractionIntegration>({
    required A Function(bool replaying) create,
    required FutureOr<Object?> Function(A adapter) scenario,
    Redactor? redactor,
    Duration settle = const Duration(milliseconds: 50),
  }) async {
    final capture = InteractionHarness.capture(redactor: redactor);
    final captureAdapter = create(false);
    await capture.setUp([captureAdapter]);
    final captured = await scenario(captureAdapter);
    await Future<void>.delayed(settle);
    final dependencies = capture.dependencies();

    final replay = InteractionHarness.replay(
      capture.encodedEvents(),
      dependencies: dependencies,
      redactor: redactor,
    );
    final replayAdapter = create(true);
    await replay.setUp([replayAdapter]);
    final replayed = await scenario(replayAdapter);
    await Future<void>.delayed(settle);
    final divergences = replay.finish();
    return AdapterConformanceResult(
      captured: captured,
      replayed: replayed,
      events: capture.events,
      dependencies: dependencies,
      divergences: divergences,
      eligibility: capture.eligibility(),
    );
  }
}
