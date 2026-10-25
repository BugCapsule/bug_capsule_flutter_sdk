import 'package:flutter/foundation.dart';
import '../core/core.dart';

import 'backend.dart' show OutboxLimits;
import 'monitoring/options.dart';

/// Where capsules are uploaded and remote capture config comes from.
///
/// Most apps pass `BugCapsuleConfig(token: ...)` instead; this explicit form
/// is for self-hosted backends and advanced setups, and wins over a token.
class BugCapsuleBackendConfig {
  const BugCapsuleBackendConfig({required this.url, required this.ingestKey});

  /// e.g. `http://127.0.0.1:8787` locally, `https://bugcapsule.example.com` hosted.
  final String url;

  /// Ingest credential: an SDK token key (`bct_...`) or a legacy ingest key
  /// (`bci_...`). Upload-only; safe to ship in the app.
  final String ingestKey;
}

class BugCapsuleConfig {
  /// The usual setup is the SDK token from the dashboard:
  ///
  /// ```dart
  /// const BugCapsuleConfig(token: 'bcsdk.v1.…')
  /// ```
  ///
  /// [appVersion] and [appBuild] default to the `BUGCAPSULE_APP_VERSION` /
  /// `BUGCAPSULE_APP_BUILD` dart-defines, else to the version in
  /// `MonitoringOptions.release` (`<id>@<version>+<build>`), else `unknown`
  /// and `0`.
  const BugCapsuleConfig({
    this.token,
    String? appVersion,
    String? appBuild,
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
    this.monitoring = const MonitoringOptions(),
  }) : _appVersion = appVersion,
       _appBuild = appBuild,
       _mode = mode,
       _gitSha = gitSha,
       _showOverlay = showOverlay;

  /// SDK connection token from the BugCapsule dashboard
  /// (`bcsdk.v1.<payload>`): the API URL and an upload-only credential in one
  /// string, safe to ship in the app. Ignored when [backend] is set. A token
  /// that can't be used never stops the app: it runs without BugCapsule and
  /// `BugCapsule.status` says why.
  final String? token;
  final String? _appVersion;
  final String? _appBuild;

  String get appVersion {
    if (_appVersion != null && _appVersion.isNotEmpty) return _appVersion;
    const fromEnv = String.fromEnvironment('BUGCAPSULE_APP_VERSION');
    if (fromEnv.isNotEmpty) return fromEnv;
    return _releaseVersion.$1 ?? 'unknown';
  }

  String get appBuild {
    if (_appBuild != null && _appBuild.isNotEmpty) return _appBuild;
    const fromEnv = String.fromEnvironment('BUGCAPSULE_APP_BUILD');
    if (fromEnv.isNotEmpty) return fromEnv;
    return _releaseVersion.$2 ?? '0';
  }

  /// `com.shop.app@1.4.0+52` → (`1.4.0`, `52`).
  (String?, String?) get _releaseVersion {
    final release = monitoring.release;
    if (release == null || release.isEmpty) return (null, null);
    final at = release.lastIndexOf('@');
    final version = at < 0 ? release : release.substring(at + 1);
    final plus = version.indexOf('+');
    final name = plus < 0 ? version : version.substring(0, plus);
    final build = plus < 0 ? '' : version.substring(plus + 1);
    return (name.isEmpty ? null : name, build.isEmpty ? null : build);
  }

  final String? appId;
  final String? appName;
  final String? flavor;
  final CaptureMode? _mode;

  /// Local master switch. The backend kill switch can also disable capture.
  final bool enabled;

  /// Explicit backend URL and ingest key (self-hosted / advanced). Wins over
  /// [token].
  final BugCapsuleBackendConfig? backend;
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
  final Map<String, Object?>? Function(String type, Map<String, Object?> data)?
  beforeRecord;

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

  /// Replay source for tests. Apps normally get it from `BUGCAPSULE_REPLAY_URL`.
  final String? replayUrl;

  /// Error events, release health, tracing and feedback (monitoring-v1).
  /// On by default; `MonitoringOptions.disabled` turns it off. [enabled]
  /// false turns it off too.
  final MonitoringOptions monitoring;

  /// `BUGCAPSULE_MODE` dart-define, else debug for debug builds and production
  /// for release builds.
  CaptureMode get mode {
    if (_mode != null) return _mode;
    const fromEnv = String.fromEnvironment('BUGCAPSULE_MODE');
    if (fromEnv.isNotEmpty) return CaptureMode.values.byName(fromEnv);
    return kReleaseMode ? CaptureMode.production : CaptureMode.debug;
  }

  /// `BUGCAPSULE_GIT_SHA` dart-define unless given explicitly.
  String? get gitSha {
    if (_gitSha != null && _gitSha.isNotEmpty) return _gitSha;
    const fromEnv = String.fromEnvironment('BUGCAPSULE_GIT_SHA');
    return fromEnv.isEmpty ? null : fromEnv;
  }

  /// `BUGCAPSULE_GIT_DIRTY=true` dart-define.
  bool? get gitDirty {
    const fromEnv = String.fromEnvironment('BUGCAPSULE_GIT_DIRTY');
    return fromEnv.isEmpty ? null : fromEnv == 'true';
  }

  bool get showOverlay => _showOverlay ?? mode != CaptureMode.production;
}
