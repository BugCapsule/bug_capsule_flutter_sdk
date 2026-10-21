import 'package:flutter/foundation.dart';
import 'package:repro_core/repro_core.dart';

import 'backend.dart' show OutboxLimits;

/// Where capsules are uploaded and remote capture config comes from.
class ReproBackendConfig {
  const ReproBackendConfig({required this.url, required this.ingestKey});

  /// e.g. `http://127.0.0.1:8787` locally, `https://repro.example.com` hosted.
  final String url;

  /// Project ingest key (`rpi_...`). Upload-only; safe to ship in the app.
  final String ingestKey;
}

class ReproConfig {
  const ReproConfig({
    required this.appVersion,
    required this.appBuild,
    this.appId,
    this.appName,
    this.flavor,
    CaptureMode? mode,
    this.enabled = true,
    this.backend,
    String? gitSha,
    this.stateSchemaVersion = 1,
    this.checkpointInterval = const Duration(seconds: 30),
    this.window = const Duration(minutes: 5),
    this.maxEvents = 20000,
    this.productionSampleRate = 0.1,
    this.autoCaptureOnFailure = true,
    this.maxCapsulesPerSession = 3,
    this.captureNetworkBodies = true,
    this.maxBodyBytes = 256 * 1024,
    this.redactKeys = const [],
    this.redactHeaders = const [],
    this.redactPatterns = const [],
    this.beforeRecord,
    this.beforeCheckpoint,
    this.outboxLimits = const OutboxLimits(),
    this.maxStaleConfig = const Duration(days: 7),
    bool? showOverlay,
    this.ignoreError,
    this.labels = const {},
    this.replayUrl,
  })  : _mode = mode,
        _gitSha = gitSha,
        _showOverlay = showOverlay;

  final String appVersion;
  final String appBuild;
  final String? appId;
  final String? appName;
  final String? flavor;
  final CaptureMode? _mode;

  /// Local master switch. The backend kill switch can also disable capture.
  final bool enabled;
  final ReproBackendConfig? backend;
  final String? _gitSha;

  /// Bump when serialized state classes change incompatibly.
  final int stateSchemaVersion;
  final Duration checkpointInterval;

  /// Events older than this are evicted (a periodic checkpoint then becomes
  /// the replay start).
  final Duration window;
  final int maxEvents;

  /// Maximum fraction of production sessions that record. QA and debug
  /// always record. The backend `sampleRate` can lower it, never raise it.
  final double productionSampleRate;
  final bool autoCaptureOnFailure;
  final int maxCapsulesPerSession;
  final bool captureNetworkBodies;
  final int maxBodyBytes;
  final List<String> redactKeys;
  final List<String> redactHeaders;

  /// Extra free-text patterns replaced with `[REDACTED]` wherever text is
  /// recorded (messages, logs, text bodies, string values), e.g. internal
  /// account ids: `[RegExp(r'ACCT-\d{8}')]`.
  final List<RegExp> redactPatterns;

  /// Last look at every recorded event, after built-in redaction. Return the
  /// data to keep (possibly modified), or null to drop the event. If it
  /// throws, the event is dropped.
  final Map<String, Object?>? Function(String type, Map<String, Object?> data)? beforeRecord;

  /// Last look at each integration's checkpoint snapshot, after built-in
  /// redaction. Return null to leave the integration out of the checkpoint
  /// (replay then reports it as not restored). If it throws, the snapshot is
  /// dropped.
  final Object? Function(String integration, Object? data)? beforeCheckpoint;

  /// Bounds on capsules waiting for upload (see `OutboxLimits`).
  final OutboxLimits outboxLimits;

  /// How old the last fetched remote config may be for uploads to proceed
  /// when the backend cannot be reached. A cached kill switch applies however
  /// old it is.
  final Duration maxStaleConfig;
  final bool? _showOverlay;

  /// Return true for errors that should not count as failures.
  final bool Function(Object error)? ignoreError;
  final Map<String, String> labels;

  /// Replay source for tests. Apps normally get it from `REPRO_REPLAY_URL`.
  final String? replayUrl;

  /// `REPRO_MODE` dart-define, else debug for debug builds and production
  /// for release builds.
  CaptureMode get mode {
    if (_mode != null) return _mode;
    const fromEnv = String.fromEnvironment('REPRO_MODE');
    if (fromEnv.isNotEmpty) return CaptureMode.values.byName(fromEnv);
    return kReleaseMode ? CaptureMode.production : CaptureMode.debug;
  }

  /// `REPRO_GIT_SHA` dart-define unless given explicitly.
  String? get gitSha {
    if (_gitSha != null && _gitSha.isNotEmpty) return _gitSha;
    const fromEnv = String.fromEnvironment('REPRO_GIT_SHA');
    return fromEnv.isEmpty ? null : fromEnv;
  }

  /// `REPRO_GIT_DIRTY=true` dart-define.
  bool? get gitDirty {
    const fromEnv = String.fromEnvironment('REPRO_GIT_DIRTY');
    return fromEnv.isEmpty ? null : fromEnv == 'true';
  }

  bool get showOverlay => _showOverlay ?? mode != CaptureMode.production;
}
