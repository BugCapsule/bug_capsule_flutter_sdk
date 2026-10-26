/// Native crash reporting for BugCapsule (monitoring-v1 §2.1).
///
/// Add the package and it is on: Flutter registers [BugCapsuleNative] on
/// Android and iOS before `main`, and `BugCapsule.init` starts it. Crashes
/// in native code (the app's, the Flutter engine's, plugins'), ANRs and app
/// hangs, and the system's records of how the app died are captured by the
/// BugCapsule Android and iOS SDKs' crash bridges and sent with the Dart
/// errors, in the same session. Turn it off with
/// `MonitoringOptions(enableNativeCrashHandling: false)`.
library;

import 'dart:async';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The platform side of [NativeCrashReporter]; see the library comment.
class BugCapsuleNative
    with WidgetsBindingObserver
    implements NativeCrashReporter {
  BugCapsuleNative({
    MethodChannel channel = const MethodChannel('dev.bugcapsule/native_crash'),
    EventChannel liveEvents = const EventChannel(
      'dev.bugcapsule/native_crash/events',
    ),
  }) : _channel = channel,
       _liveEvents = liveEvents;

  /// Called by Flutter's plugin registrant (`dartPluginClass`).
  static void registerWith() {
    NativeCrashReporter.instance ??= BugCapsuleNative();
  }

  final MethodChannel _channel;
  final EventChannel _liveEvents;
  final StreamController<NativeCrashEvent> _events =
      StreamController.broadcast();

  /// Ids of events already handed on: hangs reach the live stream and stay
  /// pending in the native SDK until taken, so they would come twice.
  final Set<String> _delivered = {};
  StreamSubscription<Object?>? _live;
  bool _started = false;

  @override
  Stream<NativeCrashEvent> get events => _events.stream;

  @override
  Future<NativeCrashStart> start(NativeCrashSettings settings) async {
    final result = await _channel.invokeMapMethod<String, Object?>('start', {
      'release': settings.release,
      'environment': settings.environment,
      'inAppIncludes': settings.inAppIncludes,
      'appHangs': settings.appHangs,
      'appHangTimeoutMs': settings.appHangTimeout?.inMilliseconds,
    });
    if (!_started) {
      _started = true;
      _live = _liveEvents.receiveBroadcastStream().listen(
        (e) {
          if (e is String && _first(e)) {
            _events.add(NativeCrashEvent(e, live: true));
          }
        },
        onError: (Object e) =>
            debugPrint('[bugcapsule] native event stream failed: $e'),
      );
      WidgetsBinding.instance.addObserver(this);
    }
    return NativeCrashStart(
      lastRunCrashed: result?['lastRunCrashed'] == true,
      handlerInstalled: result?['handlerInstalled'] == true,
    );
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    await _live?.cancel();
    _live = null;
  }

  @override
  void updateScope(String scopeJson) {
    _channel.invokeMethod<void>('updateScope', scopeJson).catchError((
      Object e,
    ) {
      debugPrint('[bugcapsule] could not update the native crash scope: $e');
    });
  }

  /// Failures the system reports late (MetricKit on iOS) wait in the native
  /// SDK: collect them when the app comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(collectPending());
  }

  /// Hands on events the native SDK holds that were not handed on yet:
  /// only while the hub listens, so nothing is taken from the native SDK
  /// (which deletes what it hands out) and dropped.
  @override
  Future<void> collectPending() async {
    if (!_started || !_events.hasListener) return;
    try {
      final pending =
          await _channel.invokeListMethod<Object?>('takePending') ?? const [];
      for (final e in pending) {
        if (e is String && _first(e)) {
          _events.add(NativeCrashEvent(e, live: false));
        }
      }
    } catch (e) {
      debugPrint('[bugcapsule] could not read pending native events: $e');
    }
  }

  bool _first(String json) {
    final match = RegExp(r'"eventId"\s*:\s*"([^"]+)"').firstMatch(json);
    final id = match?.group(1);
    return id == null || _delivered.add(id);
  }
}
