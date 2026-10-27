# bug_capsule_native

Native crash reporting for [BugCapsule](https://bugcapsule.com) in Flutter
apps. Dart can't see a crash in native code: a plugin's C/C++ or Swift code,
the Flutter engine, an ANR, the system killing the app. This package hands
those to the BugCapsule SDK through the BugCapsule Android and iOS SDKs, so
they show up in the same issues and sessions as your Dart errors.

| Android | iOS |
|---|---|
| NDK signal crashes (with the crashed run's breadcrumbs, user and tags) | Signals and Mach exceptions, every thread |
| ANRs (main thread blocked 5 s) | App hangs (2 s) |
| Android 11+: ANRs the system killed the app for, native crashes with every thread from the tombstone (12+), low-memory kills in the foreground | MetricKit crash and hang diagnostics (iOS 14+) |

## Install

```yaml
dependencies:
  bug_capsule: ^0.4.1-beta.7
  bug_capsule_native: ^0.1.0
```

That's all: Flutter registers the plugin before `main`, and `BugCapsule.init`
starts it. Crashes are reported on the next launch, with the release they
happened in. They go through `beforeSend` and redaction like any other
event, and the crashed session counts as `crashed` in crash-free rates.

```dart
MonitoringOptions(
  enableNativeCrashHandling: true,          // default
  enableAppHangTracking: true,              // default
  appHangTimeout: Duration(seconds: 3),     // default: 5 s Android, 2 s iOS
)
```

**Crash capsules.** When the session that crashed was recording, the crash
also gets a capsule: `bug_capsule` keeps a crash journal per process while it
records and, on the next launch, builds a capsule from the journal of the
process the crash is about. Which journal: the one the crash's own scope
names (Android, and iOS crash reports, attach the crashed process's scope,
where the SDK mirrors its journal id); otherwise, when the previous run
crashed, the previous process's journal if the crash falls within its
lifetime; otherwise none, and the event comes alone.

**iOS needs Swift Package Manager**, which brings in the BugCapsule iOS SDK:
`flutter config --enable-swift-package-manager`. With CocoaPods the plugin
builds but reports no native crashes on iOS (it logs why). Minimums: iOS 15,
Android API 23.

**Readable native frames.** Upload your native symbols for every release:
the BugCapsule Gradle plugin uploads unstripped `.so` files, and the iOS SDK's
`bugcapsule-upload-dsyms.sh` uploads dSYMs. See
[Release symbols](https://docs.bugcapsule.com/symbols.html).

## License

Bug Capsule proprietary license, see [LICENSE](LICENSE).
