import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Run with `flutter run --release -t integration_test/release_guard.dart`.
/// An explicit replay URL must never arm the replay engine in a release binary.
Future<void> main() async {
  if (!kReleaseMode) throw StateError('This gate must run as a release binary');
  var appStarted = false;
  await BugCapsule.init(
    config: const BugCapsuleConfig(
      appVersion: 'release-guard',
      appBuild: '1',
      mode: CaptureMode.qa,
      replayUrl: 'http://127.0.0.1:1/a/release-guard',
    ),
    appRunner: () {
      appStarted = true;
      runApp(const Directionality(textDirection: TextDirection.ltr, child: Text('release guard')));
    },
  );
  if (!appStarted || BugCapsule.isReplaying) throw StateError('Release replay guard failed');
  // ignore: avoid_print
  print('BUGCAPSULE_RELEASE_GUARD_PASSED');
}
