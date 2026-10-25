# Upgrading the Flutter SDK

Before any upgrade, read [Installation and upgrades](https://docs.bugcapsule.com/installation.html)
for how to keep your regression suite green across versions.

## To 0.4 (one package)

The twelve packages (`bug_capsule_core`, `bug_capsule_flutter`,
`bug_capsule_bloc`, `bug_capsule_dio`, …, `bug_capsule_cli`) are now one
package, `bug_capsule`. The API is unchanged; only the dependency and the
imports change.

- In `pubspec.yaml`, replace every `bug_capsule_*` dependency with
  `bug_capsule` (`flutter pub add bug_capsule`).
- Replace every `package:bug_capsule_*/…` import with
  `import 'package:bug_capsule/bug_capsule.dart';`.
- CLI: `dart pub global deactivate bug_capsule_cli`, then
  `dart pub global activate bug_capsule`.
- Capsules still report `sdk.name: bug_capsule_flutter`, so BugCapsule and
  older CLIs read them as before.

## From 0.1

- `BugCapsule.resetForTest()` now returns a `Future` (await it in tests).
- The upload outbox is now bounded; files left by 0.1 are kept and count
  toward the limits.
- CLI 0.2 reports verdicts with `validAttempts`. BugCapsule no longer moves a
  capsule to `fixed` (or `not_reproduced`) on results from CLI 0.1, which
  could not tell an errored attempt from a passing one; update the CLI.
