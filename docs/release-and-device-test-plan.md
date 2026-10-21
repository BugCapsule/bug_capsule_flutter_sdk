# Release build and device test plan

What has to pass before an SDK version goes to a pilot customer, and what CI
covers versus what needs a person with devices.

## What CI covers (every pull request)

| Check | Where (`packages/bug_capsule/`) |
|---|---|
| Analyzer clean on the package and the demo | `ci.yml` analyze |
| Capsule model, codec, structural validator, shared fixtures (valid and malformed) | `test/core` |
| Redaction: free text, embedded JSON, URLs, headers, failure messages | `test/core` |
| Verdict rules: mixed, incomplete, zero attempts, missing assertions, material divergences | `test/core`, `test/cli` |
| CLI output, exit codes and backend payload agree | `test/cli` |
| Startup isolation (storage failure, integration setup failure, capture disabled) | `test/runtime` |
| Remote config TTL/backoff/resume/scoping on a fake clock; kill switch during capture and upload; sampling; late body/redaction changes | `test/runtime` |
| Outbox quotas, eviction, crash leftovers, corrupt files, disk errors, concurrent enqueue/flush | `test/runtime` |
| Dio streaming: first chunk before completion, bounded retention, bodies off, cancellation, errors, long-lived streams, uploads with progress, key consistency | `test/integrations` |
| Route redaction in events and checkpoints; storage and BLoC redaction and restore divergences | `test/integrations` |
| Demo app boots under BugCapsule and writes a decodable, redacted capsule | `example/bug_capsule_demo` test |

Weekly and on demand (`workflow_dispatch`): release builds of the demo app for
Android (`apk --release`) and iOS (`ios --release --no-codesign`).

## Before every release (manual, about two hours)

Use the demo app and, once available, a design partner's app. Record results
in the release notes. Devices: one recent iPhone, one low-end Android
(2-3 GB RAM, Android 10-12), simulators for the replay steps.

1. **Release build.** `flutter build ipa` / `flutter build appbundle` with
   `BUGCAPSULE_MODE=production`, `BUGCAPSULE_GIT_SHA`. Confirm: the app starts with the
   backend unreachable, with the ingest key revoked, and with
   `BugCapsuleConfig(enabled: false)`; replay requests are ignored
   (`BUGCAPSULE_REPLAY_URL` dart-define and a planted `replay_request.json`).
2. **Overhead budget** (low-end Android, release, median of 5 runs, BugCapsule on
   with sampling forced to 1.0 vs. BugCapsule disabled):
   * cold start: within +5 % or +80 ms;
   * frame build/raster p90 on a scrolling list with HTTP traffic: within +1 ms;
   * memory (PSS) after 10 minutes of use: within +25 MB;
   * capsule write: no dropped frames while encoding (background isolate);
   * a 50 MB download through Dio: app memory does not grow by the download size.
   Use `flutter run --profile` + DevTools, and `adb shell dumpsys meminfo`.
   A miss blocks the release for production mode; QA mode may ship with a note.
3. **Kill switch on a device.** Record a session, `bugcapsule capture --on`,
   background and foreground the app: recording stops within one resume,
   nothing more is uploaded, the outbox directory is empty. Kill the app,
   start it offline: still disabled. `bugcapsule capture --off`, restart: recording
   resumes.
4. **Offline and quota.** Airplane mode, trigger 15 failures across 3
   sessions: the outbox stays at 10 files / 10 MiB; reconnect: uploads drain,
   oldest first, with backoff on 503.
5. **Redaction review.** Capture with a real login flow and a payment-like
   form. `bugcapsule inspect --json` the capsule and search it for the test
   account's password, tokens, card number and email. Expected: credentials
   absent; emails and names are present unless the app added rules (document
   what the app must configure).
6. **Replay and verify.** For each demo bug: capture on device, `bugcapsule run`
   (expect `REPRODUCED 3/3` on the iOS simulator), fix, `bugcapsule verify -n 5`
   (expect `FIXED`), then break the replay on purpose (rename a
   `BugCapsule.action` id) and confirm `verify` says `INCONCLUSIVE` and exits 3.
7. **Android replay path.** `bugcapsule run` against an Android emulator end to end
   (this path is implemented but has not been exercised; until it passes,
   the supported matrix is iOS simulator replay only).

## Supported matrix for the pilot

| | Supported | Not yet |
|---|---|---|
| Flutter | 3.35 – 3.47 stable | beta/master |
| Capture | iOS 16+, Android 10+ physical devices and simulators/emulators | web, desktop |
| Replay | iOS simulator (macOS host) | Android emulator (unverified), physical devices |
| Integrations | Dio 5.9+, bloc 9, go_router 14-18, shared_preferences 2.5 | `http` package, WebSockets, platform channels, Riverpod/Provider state |
