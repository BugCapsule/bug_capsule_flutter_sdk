/// Native crash capture that a native SDK does for the app (monitoring-v1
/// §2.1): signals, NDK and Mach crashes, ANRs and app hangs, the operating
/// system's exit records. Dart cannot see these: the `bug_capsule_native`
/// package provides them through the Android and iOS SDKs' crash bridges
/// and registers itself as [NativeCrashReporter.instance] when it is a
/// dependency of the app.
library;

/// What the hub asks a [NativeCrashReporter] to start with.
class NativeCrashSettings {
  const NativeCrashSettings({
    required this.release,
    required this.environment,
    this.inAppIncludes = const [],
    this.appHangs = true,
    this.appHangTimeout,
  });

  final String? release;
  final String environment;

  /// Native packages / modules whose frames are app code (the app id by default).
  final List<String> inAppIncludes;

  /// Main-thread hangs: ANRs on Android, app hangs on iOS.
  final bool appHangs;

  /// Null: the platform's default (5 s on Android, 2 s on iOS).
  final Duration? appHangTimeout;
}

/// What [NativeCrashReporter.start] found out right away.
class NativeCrashStart {
  const NativeCrashStart({
    required this.lastRunCrashed,
    this.handlerInstalled = false,
  });

  /// The previous run ended in a native crash: its session is `crashed`.
  /// True for the first start in a process only (a second `BugCapsule.init`,
  /// another engine or a hot restart get false).
  final bool lastRunCrashed;

  /// The native signal / exception handler is installed.
  final bool handlerInstalled;
}

/// One event from the native SDK, as monitoring-v1 `event` JSON.
class NativeCrashEvent {
  const NativeCrashEvent(this.json, {required this.live});

  final String json;

  /// Captured in this run (a hang): it counts in the current session.
  /// False for a failure of an earlier run, with that run's release,
  /// environment and scope.
  final bool live;
}

/// Native crash capture for the hub; see the library comment.
abstract class NativeCrashReporter {
  /// Set by `bug_capsule_native` (its plugin registration); the hub starts
  /// it when `MonitoringOptions.enableNativeCrashHandling` is true.
  static NativeCrashReporter? instance;

  /// Installs the native handlers (once per process). Must answer quickly:
  /// earlier runs' failures come through [collectPending].
  Future<NativeCrashStart> start(NativeCrashSettings settings);

  /// Hands earlier runs' failures (and anything else the native SDK holds)
  /// to [events]. Does nothing while no one listens to [events], so nothing
  /// is taken from the native SDK and dropped.
  Future<void> collectPending();

  /// Stops handing on events (the hub is gone); the native handlers stay
  /// installed and keep what they capture for the next start.
  Future<void> stop();

  /// The current scope (redacted, event-shaped JSON: `level`, `fingerprint`,
  /// `tags`, `user`, `extra`, `contexts`, `breadcrumbs`) for the next crash
  /// record.
  void updateScope(String scopeJson);

  /// Events after [start]: hangs as they happen, and earlier runs' failures
  /// (from [collectPending], including what the system reports late, like
  /// MetricKit). Each event once.
  Stream<NativeCrashEvent> get events;
}
