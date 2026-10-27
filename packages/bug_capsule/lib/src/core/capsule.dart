import 'event.dart';
import 'failure.dart';
import 'interactions.dart';

enum CaptureMode { debug, qa, production }

enum CheckpointKind { launch, periodic }

enum EligibilityStatus { eligible, partial, ineligible }

class Checkpoint {
  const Checkpoint({
    required this.kind,
    required this.t,
    required this.wallClockMs,
    required this.afterSeq,
    this.data = const {},
  });

  factory Checkpoint.fromJson(Map<String, Object?> json) => Checkpoint(
    kind: CheckpointKind.values.byName(json['kind'] as String),
    t: json['t'] as int,
    wallClockMs: json['wallClockMs'] as int,
    afterSeq: json['afterSeq'] as int? ?? 0,
    data: (json['data'] as Map?)?.cast<String, Object?>() ?? const {},
  );

  final CheckpointKind kind;

  /// Time of the checkpoint (same clock as event `t`).
  final int t;

  /// Wall clock (epoch ms) when the checkpoint was taken.
  final int wallClockMs;

  /// Sequence number of the last event recorded before this checkpoint.
  /// Events with a greater `seq` happened after it.
  final int afterSeq;

  /// Integration name -> JSON snapshot.
  final Map<String, Object?> data;

  Checkpoint shift(int offsetMs) => Checkpoint(
    kind: kind,
    t: t - offsetMs,
    wallClockMs: wallClockMs,
    afterSeq: afterSeq,
    data: data,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    't': t,
    'wallClockMs': wallClockMs,
    'afterSeq': afterSeq,
    'data': data,
  };
}

class MissingDependency {
  const MissingDependency(
    this.dependency,
    this.reason, {
    this.blocking = false,
  });

  factory MissingDependency.fromJson(Map<String, Object?> json) =>
      MissingDependency(
        json['dependency'] as String,
        json['reason'] as String,
        blocking: json['blocking'] as bool? ?? false,
      );

  final String dependency;
  final String reason;

  /// A blocking gap makes the capsule ineligible rather than partial.
  final bool blocking;

  Map<String, Object?> toJson() => {
    'dependency': dependency,
    'reason': reason,
    if (blocking) 'blocking': true,
  };
}

class Eligibility {
  const Eligibility(this.status, this.missing);

  factory Eligibility.fromJson(Map<String, Object?> json) =>
      Eligibility(EligibilityStatus.values.byName(json['status'] as String), [
        for (final m in (json['missing'] as List?) ?? const [])
          MissingDependency.fromJson((m as Map).cast<String, Object?>()),
      ]);

  final EligibilityStatus status;
  final List<MissingDependency> missing;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'missing': [for (final m in missing) m.toJson()],
  };
}

/// Collects gaps from the core and from every integration.
class EligibilityBuilder {
  final List<MissingDependency> _missing = [];

  void missing(String dependency, String reason, {bool blocking = false}) {
    // Bounds of the capsule format; reasons often embed error messages.
    if (dependency.length > 200) dependency = dependency.substring(0, 200);
    if (reason.length > 2000) reason = reason.substring(0, 2000);
    if (_missing.length >= 200) return;
    if (_missing.any((m) => m.dependency == dependency && m.reason == reason)) {
      return;
    }
    _missing.add(MissingDependency(dependency, reason, blocking: blocking));
  }

  Eligibility build() {
    final status = _missing.any((m) => m.blocking)
        ? EligibilityStatus.ineligible
        : _missing.isEmpty
        ? EligibilityStatus.eligible
        : EligibilityStatus.partial;
    return Eligibility(status, List.unmodifiable(_missing));
  }
}

class AppInfo {
  const AppInfo({
    required this.version,
    required this.build,
    this.id,
    this.name,
    this.flavor,
  });

  factory AppInfo.fromJson(Map<String, Object?> j) => AppInfo(
    id: j['id'] as String?,
    name: j['name'] as String?,
    version: j['version'] as String,
    build: j['build'] as String,
    flavor: j['flavor'] as String?,
  );

  final String? id;
  final String? name;
  final String version;
  final String build;
  final String? flavor;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'build': build,
    'flavor': flavor,
  };
}

class PlatformInfo {
  const PlatformInfo({
    required this.os,
    required this.osVersion,
    required this.locale,
    required this.screenWidth,
    required this.screenHeight,
    required this.pixelRatio,
    required this.dartVersion,
  });

  factory PlatformInfo.fromJson(Map<String, Object?> j) {
    final screen = (j['screen'] as Map?)?.cast<String, Object?>() ?? const {};
    return PlatformInfo(
      os: j['os'] as String,
      osVersion: j['osVersion'] as String? ?? '',
      locale: j['locale'] as String? ?? '',
      screenWidth: (screen['width'] as num?)?.toDouble() ?? 0,
      screenHeight: (screen['height'] as num?)?.toDouble() ?? 0,
      pixelRatio: (screen['pixelRatio'] as num?)?.toDouble() ?? 1,
      dartVersion: j['dartVersion'] as String? ?? '',
    );
  }

  final String os;
  final String osVersion;
  final String locale;
  final double screenWidth;
  final double screenHeight;
  final double pixelRatio;
  final String dartVersion;

  Map<String, Object?> toJson() => {
    'os': os,
    'osVersion': osVersion,
    'locale': locale,
    'screen': {
      'width': screenWidth,
      'height': screenHeight,
      'pixelRatio': pixelRatio,
    },
    'dartVersion': dartVersion,
  };
}

/// The runtime that captured a capsule (v1 extension, SDK 0.3+). Capsules
/// written before it existed have no `runtime`; [RuntimeInfo.infer] derives
/// one from the SDK name.
class RuntimeInfo {
  const RuntimeInfo({
    required this.name,
    this.version,
    this.language,
    this.frameworks = const [],
  });

  factory RuntimeInfo.fromJson(Map<String, Object?> j) => RuntimeInfo(
    name: j['name'] as String,
    version: j['version'] as String?,
    language: j['language'] as String?,
    frameworks: [
      for (final f in (j['frameworks'] as List?) ?? const []) f as String,
    ],
  );

  /// `flutter`, `android`, `ios` or `web`. Other values are allowed and
  /// mean a runtime this reader does not know.
  final String name;

  /// Runtime version, e.g. the Dart version, Android API level, iOS
  /// version or browser version.
  final String? version;

  /// `dart`, `kotlin`, `swift`, `javascript`.
  final String? language;

  /// UI frameworks the SDK saw, e.g. `compose`, `views`, `uikit`, `swiftui`, `react`.
  final List<String> frameworks;

  static const knownRuntimes = {'flutter', 'android', 'ios', 'web'};

  /// The runtime of a capsule without a `runtime` field, from `sdk.name`.
  static String infer(String sdkName) => switch (sdkName) {
    'bug_capsule_flutter' => 'flutter',
    'bugcapsule-android' => 'android',
    'bugcapsule-ios' => 'ios',
    '@bugcapsule/web' => 'web',
    _ => 'flutter',
  };

  Map<String, Object?> toJson() => {
    'name': name,
    if (version != null) 'version': version,
    if (language != null) 'language': language,
    if (frameworks.isNotEmpty) 'frameworks': frameworks,
  };
}

class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.startedAt,
    required this.wallClockAtAnchorMs,
    required this.seed,
    required this.durationMs,
  });

  factory SessionInfo.fromJson(Map<String, Object?> j) => SessionInfo(
    id: j['id'] as String,
    startedAt: DateTime.parse(j['startedAt'] as String),
    wallClockAtAnchorMs: j['wallClockAtAnchorMs'] as int,
    seed: j['seed'] as int,
    durationMs: j['durationMs'] as int,
  );

  final String id;
  final DateTime startedAt;
  final int wallClockAtAnchorMs;
  final int seed;
  final int durationMs;

  Map<String, Object?> toJson() => {
    'id': id,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'wallClockAtAnchorMs': wallClockAtAnchorMs,
    'seed': seed,
    'durationMs': durationMs,
  };
}

class CapsuleManifest {
  const CapsuleManifest({
    required this.capsuleId,
    required this.createdAt,
    required this.mode,
    required this.app,
    required this.sdkName,
    required this.sdkVersion,
    required this.stateSchemaVersion,
    required this.platform,
    required this.session,
    required this.eligibility,
    required this.integrations,
    required this.eventCount,
    required this.droppedEvents,
    required this.checkpointKind,
    this.gitSha,
    this.dirty,
    this.failure,
    this.labels = const {},
    this.redactionKeys = const [],
    this.redactionHeaders = const [],
    this.runtime,
    this.capabilities = const {},
    this.monitoring,
    this.dependencies = const [],
    this.journalGapMs,
  });

  factory CapsuleManifest.fromJson(Map<String, Object?> j) {
    final source = (j['source'] as Map?)?.cast<String, Object?>() ?? const {};
    final sdk = (j['sdk'] as Map?)?.cast<String, Object?>() ?? const {};
    final stats = (j['stats'] as Map?)?.cast<String, Object?>() ?? const {};
    final failure = j['failure'] as Map?;
    final redaction =
        (j['redaction'] as Map?)?.cast<String, Object?>() ?? const {};
    final runtime = j['runtime'] as Map?;
    final monitoring = j['monitoring'] as Map?;
    return CapsuleManifest(
      capsuleId: j['capsuleId'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      mode: CaptureMode.values.byName(j['mode'] as String),
      app: AppInfo.fromJson((j['app'] as Map).cast<String, Object?>()),
      gitSha: source['gitSha'] as String?,
      dirty: source['dirty'] as bool?,
      sdkName: sdk['name'] as String? ?? 'unknown',
      sdkVersion: sdk['version'] as String? ?? 'unknown',
      stateSchemaVersion: j['stateSchemaVersion'] as int? ?? 1,
      platform: PlatformInfo.fromJson(
        (j['platform'] as Map).cast<String, Object?>(),
      ),
      session: SessionInfo.fromJson(
        (j['session'] as Map).cast<String, Object?>(),
      ),
      failure: failure == null
          ? null
          : FailureRecord.fromJson(failure.cast<String, Object?>()),
      eligibility: Eligibility.fromJson(
        (j['eligibility'] as Map).cast<String, Object?>(),
      ),
      integrations: [
        for (final i in (j['integrations'] as List?) ?? const []) i as String,
      ],
      eventCount: stats['eventCount'] as int? ?? 0,
      droppedEvents: stats['droppedEvents'] as int? ?? 0,
      checkpointKind: CheckpointKind.values.byName(
        stats['checkpointKind'] as String? ?? 'launch',
      ),
      labels: {
        for (final e in ((j['labels'] as Map?) ?? const {}).entries)
          '${e.key}': e.value as String,
      },
      redactionKeys: [
        for (final k in (redaction['extraKeys'] as List?) ?? const [])
          k as String,
      ],
      redactionHeaders: [
        for (final k in (redaction['extraHeaders'] as List?) ?? const [])
          k as String,
      ],
      runtime: runtime == null
          ? null
          : RuntimeInfo.fromJson(runtime.cast<String, Object?>()),
      capabilities: {
        for (final e in ((j['capabilities'] as Map?) ?? const {}).entries)
          '${e.key}': e.value as String,
      },
      monitoring: monitoring == null
          ? null
          : CapsuleMonitoring.fromJson(monitoring.cast<String, Object?>()),
      dependencies: [
        for (final d in (j['dependencies'] as List?) ?? const [])
          CapsuleDependency.fromJson((d as Map).cast<String, Object?>()),
      ],
      journalGapMs: stats['journalGapMs'] as int?,
    );
  }

  final String capsuleId;
  final DateTime createdAt;
  final CaptureMode mode;
  final AppInfo app;
  final String? gitSha;
  final bool? dirty;
  final String sdkName;
  final String sdkVersion;
  final int stateSchemaVersion;
  final PlatformInfo platform;
  final SessionInfo session;
  final FailureRecord? failure;
  final Eligibility eligibility;
  final List<String> integrations;
  final int eventCount;
  final int droppedEvents;
  final CheckpointKind checkpointKind;
  final Map<String, String> labels;

  /// Redaction keys/headers the capture used beyond the defaults (from the
  /// app config and remote config). Replay applies the same rules, so that
  /// request keys computed from redacted bodies match the recording.
  final List<String> redactionKeys;
  final List<String> redactionHeaders;

  /// Null for capsules written before the field existed; see [runtimeName].
  final RuntimeInfo? runtime;

  /// What the capturing SDK can record and replay, e.g.
  /// `{"input.pointer.replay": "supported", "lifecycle.replay": "partial"}`.
  /// Values: `supported`, `partial`, `unsupported`.
  final Map<String, String> capabilities;

  /// The monitoring `event` sent for this capsule's failure (monitoring-v1
  /// §4.3), linking the capsule to an issue. Null when monitoring was off.
  final CapsuleMonitoring? monitoring;

  /// Interaction dependencies (capsule-v2 §2). A capsule with any is
  /// written as spec v2.
  final List<CapsuleDependency> dependencies;

  /// Crash capsules: the crash time minus the time of the last event the
  /// journal flushed, when the crash time is known (`stats.journalGapMs`).
  final int? journalGapMs;

  /// Dependencies replay must serve; preflight blocks when one is missing.
  Iterable<CapsuleDependency> get requiredDependencies =>
      dependencies.where((d) => d.required);

  /// The capturing runtime, inferred for capsules without `runtime`.
  String get runtimeName => runtime?.name ?? RuntimeInfo.infer(sdkName);

  Map<String, Object?> toJson() => {
    'capsuleId': capsuleId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'mode': mode.name,
    'app': app.toJson(),
    'source': {'gitSha': gitSha, 'dirty': dirty},
    'sdk': {'name': sdkName, 'version': sdkVersion},
    'stateSchemaVersion': stateSchemaVersion,
    'platform': platform.toJson(),
    'session': session.toJson(),
    'failure': failure?.toJson(),
    'eligibility': eligibility.toJson(),
    'integrations': integrations,
    'stats': {
      'eventCount': eventCount,
      'droppedEvents': droppedEvents,
      'checkpointKind': checkpointKind.name,
      'journalGapMs': ?journalGapMs,
    },
    'labels': labels,
    if (redactionKeys.isNotEmpty || redactionHeaders.isNotEmpty)
      'redaction': {
        'extraKeys': redactionKeys,
        'extraHeaders': redactionHeaders,
      },
    if (runtime != null) 'runtime': runtime!.toJson(),
    if (capabilities.isNotEmpty) 'capabilities': capabilities,
    if (monitoring != null) 'monitoring': monitoring!.toJson(),
    // Spec v2 requires the field (a crash capsule is v2 without any).
    if (dependencies.isNotEmpty || failure?.kind == FailureKind.crash)
      'dependencies': [for (final d in dependencies) d.toJson()],
  };
}

/// `manifest.monitoring = {eventId, traceId?, release, environment}`.
class CapsuleMonitoring {
  const CapsuleMonitoring({
    required this.eventId,
    this.traceId,
    this.release,
    this.environment,
  });

  factory CapsuleMonitoring.fromJson(Map<String, Object?> j) =>
      CapsuleMonitoring(
        eventId: j['eventId'] as String,
        traceId: j['traceId'] as String?,
        release: j['release'] as String?,
        environment: j['environment'] as String?,
      );

  final String eventId;
  final String? traceId;
  final String? release;
  final String? environment;

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'traceId': ?traceId,
    'release': ?release,
    'environment': ?environment,
  };
}

class Capsule {
  const Capsule({
    required this.manifest,
    required this.checkpoint,
    required this.events,
  });

  final CapsuleManifest manifest;
  final Checkpoint checkpoint;
  final List<BugCapsuleEvent> events;

  /// 2 when the capsule has interaction dependencies or is a crash capsule
  /// (failure kind `crash` exists in v2 only), else 1: sessions that use
  /// only v1 features stay readable by v1 tools.
  int get specVersion =>
      manifest.dependencies.isEmpty &&
          manifest.failure?.kind != FailureKind.crash
      ? 1
      : 2;

  Iterable<BugCapsuleEvent> eventsOfType(String type) =>
      events.where((e) => e.type == type);
}
