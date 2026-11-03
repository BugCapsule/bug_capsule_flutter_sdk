# Upgrading the Flutter SDK

Before any upgrade, read [Installation and upgrades](https://docs.bugcapsule.com/installation.html)
for how to keep your regression suite green across versions.

## To 0.4.1-beta.7 and later (capsule spec v2)

- Capsules that record WebSockets, platform channels or native adapters are
  written as spec v2. Older CLIs and backends reject them (`specVersion 2 is
  newer than this reader`); update the CLI everywhere it runs (CI included)
  before you add these integrations. Capsules without them stay v1.
- Replay of a v2 capsule needs the same adapters in the build. A missing one
  ends the attempt `incompatible` with `dependency.unsupported`.
- `bugcapsule verify` sends reason codes with each run; BugCapsule never
  marks a capsule fixed by a run with interaction divergences.

## To 0.4 (one package)

The twelve packages (`bug_capsule_core`, `bug_capsule_flutter`,
`bug_capsule_bloc`, `bug_capsule_dio`, …, `bug_capsule_cli`) are now one
package, `bug_capsule`. The API is unchanged; only the dependency and the
imports change.

- In `pubspec.yaml`, replace the twelve legacy split core/integration dependencies with
  `bug_capsule` (`flutter pub add bug_capsule:0.4.1-beta.12`).
- Replace imports from those twelve legacy packages with
  `import 'package:bug_capsule/bug_capsule.dart';`.
- CLI: `dart pub global deactivate bug_capsule_cli`, then
  `npm install -g @bugcapsule/cli@0.4.0-beta.6`.
- Capsules still report `sdk.name: bug_capsule_flutter`, so BugCapsule and
  older CLIs read them as before.

## From 0.1

- `BugCapsule.resetForTest()` now returns a `Future` (await it in tests).
- The upload outbox is now bounded; files left by 0.1 are kept and count
  toward the limits.
- CLI 0.2 reports verdicts with `validAttempts`. BugCapsule no longer moves a
  capsule to `fixed` (or `not_reproduced`) on results from CLI 0.1, which
  could not tell an errored attempt from a passing one; update the CLI.

## Bundled integrations in Flutter 0.4.1-beta.12

1. Upgrade `bug_capsule` to `^0.4.1-beta.12` with Flutter 3.41+ and Dart 3.10+.
2. Remove `bug_capsule_firebase`, `bug_capsule_geolocator`,
   `bug_capsule_google_maps` and `bug_capsule_stripe` from your pubspec.
3. Change imports to `package:bug_capsule/firebase.dart`, `geolocator.dart`,
   `google_maps.dart` and `stripe.dart`. Integration constructors and adapter
   identifiers are unchanged; keep registering the ones your app uses.
4. Remove `bug_capsule_shorebird` and its imports/configuration. Signed updates
   use `bug_capsule_patch`, `BugCapsulePatchBinding` and `PatchUpdater`.
   `BugCapsulePatchHotfix` reports that engine's status to Emergency Recovery.
   Existing installed binaries are not migrated by this dependency change.
5. Keep `bug_capsule_native` and `bug_capsule_patch` as separate dependencies.
6. Rebuild native applications: Firebase plugins now enter every core SDK
   consumer's dependency graph. Apply their native platform requirements. The
   location, Maps and Stripe adapters still require their real plugins when
   those features are used. No service is initialized just by importing the SDK.

Previously published adapter versions remain available for older applications.
Do not combine them with the bundled integration classes in the same app.
