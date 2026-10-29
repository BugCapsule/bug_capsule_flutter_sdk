## Unreleased

- Emergency recovery (feature guards): `BugCapsule.emergency` fetches signed emergency policies (ES256, verified against the trust anchor in `EmergencyConfig`), caches and re-verifies them across launches, refreshes them in the foreground with backoff, and answers `evaluate`, `isFeatureAllowed` and `getPolicy` synchronously. Per-key failure modes (`failOpen` by default, `failClosed`, `useLastValidPolicy`), anti-replay of older revisions, receipts, `changes` and `status`. Android and iOS only; works with capture disabled or remotely switched off; allows everything during capsule replay. Implements `spec/emergency-client-v1.md`. Adds a dependency on `pointycastle`.
- Emergency recovery: hotfix adapters and runtime reports (`spec/emergency-client-v1.md` §7.6, §7.7). `EmergencyConfig.hotfixProvider` takes a `HotfixProvider` (`checkAvailability`, `downloadAvailablePatch`, `getStatus`, with `HotfixStatus`, `HotfixState`, `HotfixAvailability` and the sealed `HotfixResult`); `BugCapsule.emergency.hotfix` calls it and reports every status it returns to the BugCapsule backend as a `RUNTIME` receipt (highest accepted revision, never the same status twice in a row and at most one per 60 s, coalesced to the latest; `APPLIED` and `FAILED` receipts carry the latest one). Invalid statuses are logged and not sent; nothing is reported during capsule replay. The SDK never restarts the app or reports a downloaded patch as active. The Shorebird adapter is the new `bug_capsule_shorebird` package.
- Crash capsules keep at most 98 app labels, so the two crash labels fit and an app with 99 or more labels no longer loses its crash capsule to validation.

## 0.4.1-beta.7 — 2026-10-27

- Distribute standalone CLI executables for macOS, Linux and Windows, also available through `@bugcapsule/cli` on npm. Installing the CLI no longer requires Dart or Flutter.
- Add opt-in inline screenshots and timeline support.

- Crash capsules: while a session records, a crash journal (header, checkpoints and events, flushed at least every 250 ms from a background isolate, mirroring the flight recorder's eviction, at most 2 × `maxCapsuleBytes`) is kept per process. On the next launch, a native crash of an earlier run (with `bug_capsule_native`) gets a capsule built from its process's journal: failure kind `crash`, the `crash.native` gap, `labels.source = crash_journal`, `manifest.monitoring` set to the event, and the event carries its `capsuleId`. Crash capsules don't count against `maxCapsulesPerSession`; journals no crash claims are deleted at launch, and any older than 7 days. New `BugCapsuleConfig.crashJournal` (default on).
- Capsule format v2 accepts failure kind `crash` (with `failure.crash`: mechanism, signal, in-app frame); crash capsules are always written as v2.
- `bugcapsule gate`: the release gate for CI. Fetches what a release must not reproduce, builds once, verifies each capsule, records the runs with the release, posts the gate report, prints a table and writes JUnit XML (`--junit`) or JSON (`--json`). `--fail-on reproduced,flaky,error` sets which outcomes fail (exit 1 reproduced, 2 flaky, 3 could not run); credentials from `BUGCAPSULE_TOKEN` / `--token` (a service token with `capsules.read` and `replay.submit`). A plan the backend truncated (10 capsules per issue, 200 in all) is gated as sent, with a warning and `truncated` in the JSON and JUnit.
- `bugcapsule run` and `verify` send the release of the build under test with each run (Flutter: pubspec version and app id; Android: the installed APK's `versionName` / `versionCode`; iOS: `CFBundleShortVersionString` / `CFBundleVersion` and bundle id), `--release` and `--environment` override.
- Replay maps an app process death during an attempt to the verdict (crash capsules: same crash type reproduces; another type is inconclusive with reason code `failure.different`; another in-app frame adds `failure.different_frame`). Flutter launchers read the process exit, Android the instrumentation result, `dumpsys activity exit-info` and the crash log, iOS the XCTest output and the simulator's crash report. Runners can report a `crash` object in their result.

- Native crash reporting through the new `bug_capsule_native` package: crashes of the previous run (signals, NDK and Mach crashes, Android exit records, MetricKit) become events with that run's release and breadcrumbs, go through `beforeSend`, and make its session `crashed`; hangs while running count in the session. The redacted scope is mirrored to the native handler. New `MonitoringOptions.enableNativeCrashHandling`, `enableAppHangTracking` and `appHangTimeout`; `NativeCrashReporter` for the native side.
- A session recovered on the next launch reports the release and environment it ran with, not the current ones, so an app update no longer moves a crash to the new release.
- `ErrorEvent.fromJson` (and `fromJson` on its parts).

- `BugCapsule.refreshRemoteConfig()` now always returns a config fetched after the call. Before, a call made while another fetch was running (such as the one `init` starts) returned that older answer, so a just-flipped kill switch or body setting could be missed.
- Capsule spec v2 (`spec/capsule-v2.md`): required replay dependencies, payload recording modes, lossless typed values and reason codes for verification. The codec reads v1 and v2 and writes v2 only for capsules with interaction dependencies.
- `BugCapsuleWebSocket`: record and replay `web_socket_channel` and `dart:io` WebSockets offline, with recorded ordering and timing, send checks and reconnect attempts.
- `BugCapsulePlatformChannels`: record and replay allowlisted MethodChannel, EventChannel and BasicMessageChannel traffic in both directions. `BugCapsule.init` creates a binding that wraps the default messenger; a late setup is reported as `channel.late` / `dependency.late`.
- `NativeAdapter` for third-party SDKs, and `package:bug_capsule/testing.dart` with `InteractionHarness` and `AdapterConformance`.
- Replay preflight blocks capsules whose required adapters are missing (`dependency.unsupported`) or cannot be restored (`dependency.unrestorable`). Idle compression never skips past a due delivery.
- `bugcapsule inspect` lists dependencies, adapter versions, coverage and gaps; `verify` reports and uploads reason codes.
- Project capture settings can turn off one adapter's capture and lower the interaction payload limit.

## 0.4.1-beta.6 — 2026-10-25

- `bugcapsule login` signs in through the browser, like `firebase login`: it shows a code, opens the dashboard to approve it for one project, and saves a personal token. `--no-browser` prints the address to open on another device (SSH). `--url` defaults to the saved login, then `https://api.bugcapsule.com`. A BugCapsule server without browser sign-in gets a message to use `--token` instead.
- New `bugcapsule logout` revokes the CLI's personal token and removes it from `~/.bugcapsule/config.json`.
- `--token`, `--secret-key` and `--ingest-key` keep working; passing an SDK token (`bcsdk.v1…`, `bct_…`) to `--token` now says it belongs in the app.

## 0.4.1-beta.5 — 2026-10-25

- Keep the CLI version and captured SDK version in sync with the published package version.
- Add a release gate that rejects mismatched version metadata.

## 0.4.1-beta.4 — 2026-10-25

- Let Android instrumentation finish ActivityScenario cleanup before starting another replay attempt, and stop the test APK process during attempt isolation. This prevents subsequent attempts failing to attach on Android 14.

## 0.4.1-beta.3 — 2026-10-25

- License the Flutter SDK and bundled CLI under the MIT License.
- Apply the Dart formatter to the package sources, tests, and tools.

- Shorten the package description to meet pub.dev's metadata requirements.
- Include a Flutter example in the published package with initialization,
  navigation monitoring, and manual capsule capture.

## 0.4.1-beta.2 — 2026-10-25

- Publish the full developer README on pub.dev and check it matches the repository README.
- Wait for queued outbox operations during shutdown, including token-rejection cleanup.

- Single-token setup: `BugCapsuleConfig(token: 'bcsdk.v1.…')` with the SDK token from the dashboard; `appVersion` / `appBuild` are optional. `parseConnectionToken` parses tokens offline (connection token v1, shared test vectors). An explicit `backend` keeps working and wins over a token.
- `BugCapsule.status`: connection state (`connected`, `offline`, `rejected`, `invalid_token`, …), the backend's refusal reason, configuration-fetched and first-data confirmations, and which replay instrumentation is still missing.
- A refused credential (revoked, expired or unknown token) is logged once with the backend's explanation and stops capture and uploads for the session.

## 0.4.1-beta.1

- Public beta packaging of the validated 0.4.0 SDK and multi-runtime CLI.
- Updated package repository metadata and prerelease version.

## 0.4.0

- Unify the Flutter integrations and multi-runtime replay CLI in `bug_capsule`.
- Add monitoring, offline outbox, remote configuration and replay validation.
- Test kill-switch cancellation at a deterministic encoding boundary.
- Find Android adb from SDK paths when the replay CLI runs outside a configured PATH.

- Apply the Bug Capsule Proprietary License to the package and CLI; prior written permission is required for use or distribution.
