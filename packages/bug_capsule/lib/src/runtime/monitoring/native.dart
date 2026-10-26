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

/// What earlier runs left behind, returned by [NativeCrashReporter.start].
class NativeCrashStart {
  const NativeCrashStart({
    required this.lastRunCrashed,
    required this.events,
    this.handlerInstalled = false,
  });

  /// The previous run ended in a native crash: its session is `crashed`.
  final bool lastRunCrashed;

  /// monitoring-v1 `event` JSON, one per failure of an earlier run, with
  /// that run's release, environment and scope.
  final List<String> events;

  /// The native signal / exception handler is installed.
  final bool handlerInstalled;
}

/// Native crash capture for the hub; see the library comment.
abstract class NativeCrashReporter {
  /// Set by `bug_capsule_native` (its plugin registration); the hub starts
  /// it when `MonitoringOptions.enableNativeCrashHandling` is true.
  static NativeCrashReporter? instance;

  /// Installs the native handlers once and returns what earlier runs left.
  Future<NativeCrashStart> start(NativeCrashSettings settings);

  /// The current scope (redacted, event-shaped JSON: `level`, `fingerprint`,
  /// `tags`, `user`, `extra`, `contexts`, `breadcrumbs`) for the next crash
  /// record.
  void updateScope(String scopeJson);

  /// Events captured while the app runs (hangs), as event JSON.
  Stream<String> get events;
}
