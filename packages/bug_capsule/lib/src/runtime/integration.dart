import 'dart:async';

import '../core/core.dart';

import 'config.dart';

/// What the runtime exposes to integrations (BLoC, Dio, router, storage...).
abstract interface class BugCapsuleSession {
  BugCapsuleConfig get config;
  CaptureMode get mode;

  /// True while events are being recorded (capture mode, enabled, sampled).
  bool get isRecording;
  bool get isReplaying;
  Redactor get redactor;
  bool get captureNetworkBodies;
  int get maxBodyBytes;

  /// Milliseconds on the session clock (same clock as event `t`).
  int now();

  /// Records an event. No-op when not recording.
  void record(String type, [Map<String, Object?> data = const {}]);

  /// Non-null in replay mode.
  ReplayContext? get replay;

  /// Reports an error as a failure (deduplicated by signature).
  void reportError(Object error, StackTrace? stack);
}

abstract interface class ReplayContext {
  Capsule get capsule;
  ReplaySettings get settings;
  FixtureStore get fixtures;

  /// Records a difference between the recording and this replay.
  void diverge(String type, String detail);

  /// Counts a network response served from the capsule.
  void fixtureServed();

  /// Marks work in progress that idle compression must not skip over, such
  /// as a response waiting out its recorded latency. Call the returned
  /// function once the work ends.
  void Function() beginWork();

  /// Notes that the app did something (e.g. a BLoC event), so idle
  /// compression waits for it to settle.
  void activity();
}

/// Extension point for libraries the app uses.
///
/// Lifecycle in capture mode: [setUp] → [snapshot] (launch, then periodic) →
/// [describeEligibility] when a capsule is written.
/// In replay mode: [setUp] (with `session.replay` set) → [restore] with this
/// integration's checkpoint data, before the app starts.
abstract class BugCapsuleIntegration {
  /// Key of this integration's data in checkpoints, e.g. `bloc`.
  String get name;

  Future<void> setUp(BugCapsuleSession session) async {}

  /// JSON-safe snapshot for a checkpoint, or null.
  FutureOr<Object?> snapshot(CheckpointKind kind) => null;

  Future<void> restore(Object? data, BugCapsuleSession session) async {}

  void describeEligibility(EligibilityBuilder eligibility, RecordedWindow window) {}
}
