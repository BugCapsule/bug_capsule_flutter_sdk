## 0.1.0-beta.2 — 2026-11-03

- iOS: registers as `BugCapsuleStorageProtection`, which excludes the BugCapsule storage root from iCloud and device backups (`NSURLIsExcludedFromBackupKey`) and sets `completeUntilFirstUserAuthentication` on it and its files (new method `protectStorage` on the existing channel). Android needs nothing: the root is already in `noBackupFilesDir`.
- Crash capsules: with `bug_capsule` recording, a native crash of an earlier run gets a capsule built from the crash journal of the process that crashed. The Dart VM runs in the app's process, so the journal is keyed by the same pid the native side sees; the plugin needs no change for it.

## 0.1.0-beta.1

- First release. Registers itself as the BugCapsule hub's native crash reporter on Android and iOS and runs the BugCapsule Android SDK's `CrashBridge` (NDK crashes, ANRs, `ApplicationExitInfo`) and the iOS SDK's `BugCapsuleCrashBridge` (signals, Mach exceptions, app hangs, MetricKit). Needs BugCapsule Android `0.4.1-beta.5` and iOS `0.4.1-beta.3`.
