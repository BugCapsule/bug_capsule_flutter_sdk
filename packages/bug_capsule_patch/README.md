# BugCapsule Patch for Flutter

Optional signed patch runtime for registered application logic and surfaces on
Android and iOS. Native libraries ship in your application binary. This package
does not replace arbitrary Dart code, install plugins or change permissions.

```yaml
dependencies:
  bug_capsule: ^0.4.1-beta.10
  bug_capsule_patch: ^0.1.0-dev.1
```

Requires Dart3.9+, Flutter3.35+, AndroidAPI23+ or iOS15+. The package includes
Android arm64-v8a, armeabi-v7a and x86_64 libraries, iOSarm64, and iOS simulator
arm64/x86_64. This is a prerelease; use an isolated test application first.

Register typed PatchModule contracts and compiled fallback implementations,
then create a BugCapsulePatchBinding using your immutable base build ID,
application/environment, installation ID and pinned root public keys. Pass
the binding to BugCapsuleConfig. Use PatchUpdater with HttpPatchTransport and
a scoped delivery credential to check, verify and stage signed artifacts.
Activation occurs at the next app launch. Call markHealthy only after checking
the application is usable; flush receipts to report actual runtime events.
Never embed personal management credentials or signing private keys in an app.

The base capability inventory must match the registered backend base and
signed artifact exactly. Capture/replay binds the exact patch identity and
rejects incompatible or missing runtime state. Store distribution policies
and qualification apply separately; package installation is not store approval.

See [patch workflow](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/docs/patch-cli.md)
and the repository patch lab for a runnable test application. Release packages
contain NATIVE-PROVENANCE.json with native source commit and per-file hashes.
The repository uses workspace path dependencies for development; the staged
hosted package uses a versioned bug_capsule dependency.
