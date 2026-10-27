## Unreleased

- Crash capsules: with `bug_capsule` recording, a native crash of an earlier run gets a capsule built from the crash journal of the process that crashed. The Dart VM runs in the app's process, so the journal is keyed by the same pid the native side sees; the plugin needs no change for it.

## 0.1.0-dev.1

- First release. Registers itself as the BugCapsule hub's native crash reporter on Android and iOS and runs the BugCapsule Android SDK's `CrashBridge` (NDK crashes, ANRs, `ApplicationExitInfo`) and the iOS SDK's `BugCapsuleCrashBridge` (signals, Mach exceptions, app hangs, MetricKit). Needs BugCapsule Android `0.4.1-beta.5` and iOS `0.4.1-beta.3`.
