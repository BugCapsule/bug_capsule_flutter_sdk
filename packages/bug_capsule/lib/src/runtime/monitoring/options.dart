import '../../core/core.dart';
import '../backend.dart' show OutboxLimits;

/// Extra information handed to `beforeSend` with an event.
class EventHint {
  const EventHint({this.error, this.stackTrace, this.mechanism});

  /// The original error object, when the event came from one.
  final Object? error;
  final StackTrace? stackTrace;
  final Mechanism? mechanism;
}

/// What a `tracesSampler` decides on: the root transaction about to start.
class SamplingContext {
  const SamplingContext({
    required this.name,
    required this.op,
    this.parentSampled,
  });

  final String name;
  final String op;

  /// The decision of an incoming trace (`continueTrace`), if any.
  final bool? parentSampled;
}

typedef BeforeSendCallback =
    ErrorEvent? Function(ErrorEvent event, EventHint hint);

/// Receives the transaction payload (monitoring-v1 §8) and returns it,
/// possibly modified, or null to drop it.
typedef BeforeSendTransactionCallback =
    Map<String, Object?>? Function(Map<String, Object?> transaction);
typedef BeforeBreadcrumbCallback = Breadcrumb? Function(Breadcrumb breadcrumb);

/// Returns the sample rate (0-1) for a new trace, or null to use
/// `tracesSampleRate`.
typedef TracesSampler = double? Function(SamplingContext context);

/// Monitoring (errors, release health, tracing, feedback; monitoring-v1):
/// light, high-volume signals sent as envelopes next to capsules. Everything
/// is redacted on the device with the capsule rules before it is queued.
///
/// `BugCapsuleConfig(monitoring: MonitoringOptions.disabled)` turns all of it
/// off; the backend's `monitoringEnabled: false` stops sending.
class MonitoringOptions {
  const MonitoringOptions({
    this.enabled = true,
    this.release,
    this.environment,
    this.dist,
    this.errorSampleRate = 1.0,
    this.tracesSampleRate,
    this.tracesSampler,
    this.tracePropagationTargets = const [],
    this.enableAutoSessionTracking = true,
    this.sessionBackgroundTimeout = const Duration(seconds: 30),
    this.maxBreadcrumbs = 100,
    this.beforeSend,
    this.beforeSendTransaction,
    this.beforeBreadcrumb,
    this.inAppIncludes = const [],
    this.inAppExcludes = const [],
    this.attachStacktrace = true,
    this.sendDefaultPii = false,
    this.crashOnUnhandled = true,
    this.captureIsolateErrors = true,
    this.enableNativeCrashHandling = true,
    this.enableAppHangTracking = true,
    this.appHangTimeout,
    this.enableAppStartTracking = true,
    this.enableFramesTracking = true,
    this.enableUserInteractionTracing = false,
    this.idleTimeout = const Duration(seconds: 3),
    this.captureCapsuleWithFeedback,
    this.outboxLimits = const OutboxLimits(
      maxCount: 30,
      maxBytes: 5 * 1024 * 1024,
    ),
  });

  static const disabled = MonitoringOptions(enabled: false);

  final bool enabled;

  /// Default `<appId>@<appVersion>+<appBuild>` (`com.shop.app@1.4.0+52`).
  final String? release;

  /// Default `production`, `qa` or `development` from the capture mode.
  final String? environment;

  /// Build variant, sent as the `dist` tag.
  final String? dist;

  /// Share of error events sent. Fatal events and events linked to a
  /// capsule are always sent. The backend's `errorSampleRate` can lower it.
  final double errorSampleRate;

  /// Share of traces sampled (decided once at the root). Null: the
  /// backend's `tracesSampleRate`, else 0 (tracing off).
  final double? tracesSampleRate;
  final TracesSampler? tracesSampler;

  /// URLs that get `traceparent` / `baggage` headers: substrings, or
  /// `/regex/` patterns. Empty by default; the backend can replace the list.
  final List<String> tracePropagationTargets;

  /// One session per foreground run, ended after
  /// [sessionBackgroundTimeout] in the background.
  final bool enableAutoSessionTracking;
  final Duration sessionBackgroundTimeout;
  final int maxBreadcrumbs;

  /// Last look at an error event before it is redacted and queued; return
  /// null to drop it.
  final BeforeSendCallback? beforeSend;
  final BeforeSendTransactionCallback? beforeSendTransaction;
  final BeforeBreadcrumbCallback? beforeBreadcrumb;

  /// Dart package names whose frames are app code. Default: the package
  /// that calls `BugCapsule.init` (detected from the stack).
  final List<String> inAppIncludes;
  final List<String> inAppExcludes;

  /// Adds the current stack to `captureMessage` events.
  final bool attachStacktrace;

  /// Lets the server record the user's IP address (`{{auto}}`). Nothing else
  /// personal is collected automatically.
  final bool sendDefaultPii;

  /// Unhandled errors are `fatal` and end the session as `crashed`. When
  /// false they are `error` and the session is only errored.
  final bool crashOnUnhandled;

  /// Listens for uncaught errors of the main isolate (and of isolates passed
  /// to `BugCapsule.addIsolateErrorListener`).
  final bool captureIsolateErrors;

  /// Native crashes (signals, NDK and Mach crashes, OS exit records) of the
  /// app and its plugins, reported on the next launch. Needs the
  /// `bug_capsule_native` package; without it this does nothing.
  final bool enableNativeCrashHandling;

  /// Main-thread hangs (ANRs on Android, app hangs on iOS) with
  /// `bug_capsule_native`.
  final bool enableAppHangTracking;

  /// How long the main thread must be blocked to count as a hang. Null: 5 s
  /// on Android, 2 s on iOS.
  final Duration? appHangTimeout;

  /// An `app.start.cold` transaction from `BugCapsule.init` to the first
  /// rasterized frame.
  final bool enableAppStartTracking;

  /// Slow (> one refresh interval) and frozen (> 700 ms) frames as
  /// measurements of screen transactions.
  final bool enableFramesTracking;

  /// `ui.action.click` transactions for `BugCapsule.action` callbacks when no
  /// other transaction is running.
  final bool enableUserInteractionTracing;

  /// Screen and interaction transactions finish after this long without
  /// open child spans.
  final Duration idleTimeout;

  /// Submitting the feedback form also writes a capsule. Default: true in
  /// `qa` mode.
  final bool? captureCapsuleWithFeedback;

  /// Bounds on envelopes waiting for upload (default 30 / 5 MiB / 7 days).
  final OutboxLimits outboxLimits;
}
