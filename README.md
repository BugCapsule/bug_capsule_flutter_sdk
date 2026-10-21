# BugCapsule Flutter SDK

BugCapsule turns a Flutter failure that QA saw into a portable `.bugcapsule` capsule a developer can **replay on a simulator**, **verify after a fix**, and keep as a **regression test**.

```
QA hits a bug ─► capsule auto-captured & uploaded ─► bugcapsule run <id>   ─► REPRODUCED 3/3
                                                    fix the code
                                                    bugcapsule verify <id> ─► FIXED 0/5
                                                    bugcapsule regress add ─► runs in CI
```

The capsule holds what replay needs: a storage checkpoint, recorded touches and semantic actions, typed text, lifecycle changes, every HTTP exchange with its latency, BLoC activity, and the failure assertion. All of it is redacted on the device. Replay re-runs the real app code against that recording: network calls are served from the capsule with the same timing, so races and data-dependent bugs come back.

## Packages

| Package | What it does |
|---|---|
| [`bug_capsule_core`](packages/bug_capsule_core) | Pure Dart: capsule model ([spec v1](spec/capsule-v1.md)), flight recorder, codec, redaction, network matching |
| [`bug_capsule_flutter`](packages/bug_capsule_flutter) | `BugCapsule.init`, capture (touches, lifecycle, errors, checkpoints), upload, kill switch, replay engine, QA overlay |
| [`bug_capsule_bloc`](packages/bug_capsule_bloc) | BLoC/Cubit transitions, state snapshots and restore |
| [`bug_capsule_dio`](packages/bug_capsule_dio) | Transport-level HTTP capture and deterministic replay with endpoint normalization |
| [`bug_capsule_go_router`](packages/bug_capsule_go_router) | Navigation capture and route restore |
| [`bug_capsule_storage`](packages/bug_capsule_storage) | SharedPreferences snapshot/restore (allowlist) |
| [`bug_capsule_cli`](packages/bug_capsule_cli) | `bugcapsule inspect / run / verify / regress / list / pull / push / share / capture` |
| [`example/bug_capsule_demo`](example/bug_capsule_demo) | Shop app with planted "cannot reproduce" bugs |

The backend (upload, triage, kill switch, share links) lives in [draz26648/bug_capsule_backend](https://github.com/draz26648/bug_capsule_backend).

## Integrate (about 20 lines)

```yaml
dependencies:
  bug_capsule_flutter: {git: {url: https://github.com/draz26648/bug_capsule_flutter_sdk, path: packages/bug_capsule_flutter}}
  bug_capsule_bloc:    {git: {url: https://github.com/draz26648/bug_capsule_flutter_sdk, path: packages/bug_capsule_bloc}}
  bug_capsule_dio:     {git: {url: https://github.com/draz26648/bug_capsule_flutter_sdk, path: packages/bug_capsule_dio}}
  bug_capsule_go_router: {git: {url: https://github.com/draz26648/bug_capsule_flutter_sdk, path: packages/bug_capsule_go_router}}
  bug_capsule_storage: {git: {url: https://github.com/draz26648/bug_capsule_flutter_sdk, path: packages/bug_capsule_storage}}
```

```dart
final bugCapsuleDio = BugCapsuleDio(rules: [
  // Fields that differ on every run must not affect request matching.
  EndpointRule('POST', '/api/checkout', ignoreBodyFields: {'timestamp', 'nonce'}),
]);
final bugCapsuleRouter = BugCapsuleGoRouter();

void main() => BugCapsule.init(                     // first line of main, before ensureInitialized
      config: const BugCapsuleConfig(
        appVersion: '1.4.0',
        appBuild: '52',
        mode: CaptureMode.qa,                  // or BUGCAPSULE_MODE dart-define
        backend: BugCapsuleBackendConfig(url: 'https://bugcapsule.example.com', ingestKey: 'bci_...'),
      ),
      integrations: [
        BugCapsuleBloc(states: [
          BugCapsuleState<CartBloc, CartState>(toJson: (s) => s.toJson(), fromJson: CartState.fromJson),
        ]),
        bugCapsuleDio,
        bugCapsuleRouter,
        BugCapsuleSharedPreferences(),
      ],
      appRunner: () => runApp(const MyApp()),
    );

// where you build Dio and GoRouter:
bugCapsuleDio.attach(dio);                                         // after any custom adapter
final router = GoRouter(initialLocation: bugCapsuleRouter.initialLocation('/'), routes: [...]);
bugCapsuleRouter.attach(router);

// QA capture button:
MaterialApp.router(builder: (context, child) => BugCapsuleOverlay(child: child!), ...);
```

Build with the commit pinned so replay can check out the same code:

```bash
flutter build ipa --dart-define=BUGCAPSULE_GIT_SHA=$(git rev-parse HEAD) --dart-define=BUGCAPSULE_MODE=qa
```

### Make more bugs eligible

| Hook | Why |
|---|---|
| `onPressed: BugCapsule.action('cart.checkout', () => ...)` | Semantic replay when the developer's screen differs from QA's |
| `BugCapsule.trackText('login.email', controller)` | Typed text is replayed; sensitive ids (`password`, `otp`, …) are redacted, and `sensitive: true` redacts any field (use it for every obscured field) |
| `BugCapsule.check('cart_total_non_negative', total >= 0)` / `BugCapsule.fail(id)` | Wrong behaviour that doesn't throw becomes a checkable failure |
| `clock.now()` (package `clock`) instead of `DateTime.now()` | Replay restores the recorded wall clock |
| `BugCapsule.random` instead of `Random()` | Seeded per session, the same seed on replay |

Every capsule reports its **eligibility** (`eligible` / `partial` / `ineligible`) and lists exactly which dependency is missing (no git SHA, no failure assertion, response bodies not captured, BLoC without a serializer, …). Ineligible capsules are kept but never counted toward the reproduction rate.

## The CLI

```bash
dart pub global activate --source git https://github.com/draz26648/bug_capsule_flutter_sdk --git-path packages/bug_capsule_cli
bugcapsule login --url http://127.0.0.1:8787 --secret-key bcs_... --ingest-key bci_...

bugcapsule list                                   # capsules on the backend
bugcapsule inspect <id|file|share-url>            # failure, eligibility, network, timeline
bugcapsule run <id> -d "iPhone 18 Pro" -n 3       # replay on the capsule's commit (temporary git worktree)
bugcapsule verify <id> -n 5                       # replay on your working tree; FIXED when it no longer fails
bugcapsule regress add <id> && bugcapsule regress run  # keep it as a regression test (exit 1 on failure, for CI)
bugcapsule share <id>                             # expiring public link
bugcapsule capture --on | --off | --sample-rate 0.05   # remote kill switch and production sampling
```

### Verdicts

`run` and `verify` judge every attempt, then the batch:

* An attempt **reproduced** when the original failure assertion fired.
* An attempt is **clean** only when it ran to the end as recorded: it has a
  failure assertion to check, every recorded input was dispatched, no other
  failure fired, and nothing *material* diverged. Material: unregistered
  actions, untracked text fields, failed or missing restoration (an
  integration that captured data is missing or failed to restore), requests
  without a recorded response, responses replayed without their body, reused
  responses, dispatch errors, values that were redacted on the device and
  replayed as placeholders (a missing token or OTP can send the app down
  another path), and any divergence this version does not know. Expected
  differences do not count: a changed commit (`build.gitSha`), a different
  screen size, and recorded responses the replay never asked for. To verify
  flows behind a login, keep the login state out of the deny list for QA
  builds (e.g. a test account whose token you allow) or exclude it from the
  failing flow.
* Anything else is **invalid**: errors, incompatible capsules, no assertion.

| `bugcapsule run` (replay) | `bugcapsule verify` | exit |
|---|---|---|
| `REPRODUCED` every requested attempt reproduced | `FIXED` every requested attempt clean | 0 |
| `NOT REPRODUCED` every requested attempt clean | `STILL FAILING` reproduced, no clean attempt | 1 |
| `FLAKY` both reproduced and clean attempts | `FLAKY` | 2 |
| `INCONCLUSIVE` / `INCOMPATIBLE` anything else | `INCONCLUSIVE` / `INCOMPATIBLE` | 3 |

Attempts that never ran count against the requested number, so one clean
attempt plus one error is `INCONCLUSIVE`, never `FIXED`. The verdict is
recorded on the backend with the number of valid attempts; the backend moves a
capsule to `fixed` only for a verify where every requested attempt was valid
(and rejects contradictory results). `bugcapsule regress run` treats `INCONCLUSIVE`
as a failure.

On an iOS simulator the CLI builds once, then launches the installed app for each attempt. It hands over the replay request through a file in the app's sandbox, because environment variables don't reach the app on recent simulator runtimes. Other devices use `flutter run` with a dart-define for each attempt.

## Try the demo (≈10 minutes)

```bash
# backend: see bug_capsule_backend/README.md, then
bugcapsule login --url http://127.0.0.1:8787 --secret-key bcs_... --ingest-key bci_...
cd example/bug_capsule_demo
flutter run -d <simulator> --dart-define=BUGCAPSULE_GIT_SHA=$(git rev-parse HEAD) \
  --dart-define=BUGCAPSULE_BACKEND_URL=http://127.0.0.1:8787 --dart-define=BUGCAPSULE_INGEST_KEY=bci_...
```

| Bug | How to trigger | What replay needs |
|---|---|---|
| Profile/recommendations race | tap **Refresh picks** until it crashes (~1 in 4) | recorded response latencies |
| Legacy cart cache | **Simulate upgrade from v0.9**, restart, open cart | storage from the launch checkpoint |
| Negative total | open cart until subtotal < $100, apply `SAVE100` | typed text + server cart + custom assertion |
| Discontinued item | open cart until "unavailable" shows, checkout | the server response with `price: null` |
| Orders stuck loading | open **My orders** until it spins > 4s | the recorded `202` + watchdog assertion |

Then `bugcapsule list`, `bugcapsule run <id>`, fix the bug, `bugcapsule verify <id>`.

Measured on an iPhone 18 Pro simulator (iOS 27, Flutter 3.47.7): the race, legacy-cache and coupon capsules each reproduced 3/3 with pointer replay. The race and legacy-cache capsules also reproduced 1/1 with semantic replay; the legacy-cache one ran on a freshly installed app. A fix for the race verified as `FIXED 2/2`.

## Production checklist

Production capture works, but it is the riskiest mode. Before rollout:

1. **Kill switch.** `bugcapsule capture --on` disables capture. The backend refuses uploads from that moment (`403`). Devices see it at their next config refresh: after `configTtlSeconds` (default 5 min), when the app returns to the foreground, or before any upload attempt with a config older than its TTL. They then stop recording, drop the buffer, delete queued and saved captures, and keep the switch across launches even offline. An upload already on the wire finishes. Re-enabling applies from the next app launch. Test it before you need it.
2. **Remote config.** Fetched after startup, then refreshed on its TTL with exponential backoff (30 s to 30 min, `Retry-After` honoured) and on resume. It is cached per backend URL and ingest key, so a staging config never applies to production. With no cached config (first launch, offline), debug/QA builds record and production builds sample at the app's cap, but **nothing is uploaded until a config fetch succeeds**; a cached config older than `maxStaleConfig` (7 days) also stops uploads. A rejected ingest key (rotated) stops capture for the session. New body and redaction settings apply to the running session, including events already buffered.
3. **Sampling.** A production session records with probability `min(productionSampleRate, backend sampleRate)`, decided at launch. Lowering the remote rate mid-session keeps a recording session with probability new/old, so the share of recording sessions follows the new rate; raising it applies from the next launch and never above the app's cap (default 0.1). Sessions that aren't sampled install no recorders.
4. **Redaction.** Applied on the device to events and checkpoints alike, and again to everything integrations record. See the spec's [Redaction](spec/capsule-v1.md#redaction) section for exactly what is caught and what is not. Add `redactKeys`, `redactPatterns`, `beforeRecord` / `beforeCheckpoint` hooks, `BugCapsuleDio(exclude: ...)` for endpoints you must not record and `BugCapsuleGoRouter(sanitizeLocation: ...)` for secrets in paths; then inspect real capsules (`bugcapsule inspect`) before widening the rollout.
5. **Bodies.** Turn off `captureNetworkBodies` (remotely too) for endpoints you can't send; capsules then become `partial`. HTTP capture never buffers whole bodies: bytes stream to the app unchanged and only a bounded prefix is kept (`maxBodyBytes`, 256 KiB; binary 64 KiB). With bodies off nothing is kept for the recording; request bodies up to 64 KiB are still hashed (never stored) so replay can match requests.
6. **Device storage.** At most 20 saved captures and an upload outbox of 10 capsules / 10 MiB / 7 days (`BugCapsuleConfig.outboxLimits`), oldest evicted first; failed uploads back off from 30 s to 1 h. Disk-full and corrupt files drop the capsule, never the app.
7. **Isolation.** If storage, an integration's setup or anything else in capture setup fails, the app starts without capture. SDK errors are never thrown into the app's error handlers or callbacks.
8. **Performance.** Measure cold start, frame times and memory on a low-end Android device with and without BugCapsule ([plan](docs/release-and-device-test-plan.md)). Pointer and HTTP capture and redaction run on the UI isolate; capsule encoding runs in a background isolate.
9. **Release builds never enter replay mode** (`BUGCAPSULE_REPLAY_URL` and replay request files are ignored when `kReleaseMode`).

## Known limitations (v0.2)

- Replay keeps recorded timing, except that idle gaps between inputs longer than 1.5 s shrink to about 0.3 s when the recording and the replayed app are both idle (no pending response, no recent BLoC activity, no pressed pointer; running animations get up to 2 s to finish). Recorded network latency is never shortened. `--no-compress-idle` replays in real time. App `Timer`s are not tracked, so a timer whose effect is not recorded (say, a plain `setState`) can be skipped over; use `--no-compress-idle` if replay depends on one.
- `DateTime.now()`, `Timer`s and animations are not virtualized; only `clock.now()` and `BugCapsule.random` are deterministic.
- Platform channels, native SDKs (Firebase, maps, payments), WebSockets and the `http` package are not captured. Bugs that depend on them are partial at best.
- BLoC state injection from periodic checkpoints matches instances by creation order (`CartBloc#0`). BLoCs that dispatch events in their constructor can overwrite restored state. Launch-checkpoint replay (the default for sessions within the 5-minute window) re-executes the session instead and avoids this.
- Pointer replay assumes the same logical screen size; otherwise the CLI scales coordinates and falls back to semantic actions when they exist.
- The Android path (`flutter run` + `adb reverse`) is implemented but has not been exercised end to end yet.
- Redaction is pattern based. It does not recognise personal data that is not a credential (names, emails, addresses) or secrets in URL paths; use the hooks above.
- A request whose server answers before the request body was fully sent is keyed without its body hash; replay may then report it as unrecorded.
- Capsules captured by SDK 0.1 with body capture off were keyed without body hashes; replaying them with 0.2 reports those requests as unrecorded.

## Upgrading from 0.1

- `BugCapsuleSession` gained no members; `BugCapsule.resetForTest()` now returns a `Future` (await it in tests).
- The upload outbox is now bounded; files left by 0.1 are kept and count toward the limits.
- CLI 0.2 reports verdicts with `validAttempts`. The backend (0.2) no longer moves a capsule to `fixed` (or `not_reproduced`) on results from CLI 0.1, which could not tell an errored attempt from a passing one; update the CLI.

## Development

```bash
flutter pub get                       # pub workspace: all packages at once
(cd packages/bug_capsule_core && dart test) # model, codec, validator + shared fixtures, redaction, verdicts
(cd packages/bug_capsule_cli && dart test)
for p in bug_capsule_flutter bug_capsule_dio bug_capsule_bloc bug_capsule_go_router bug_capsule_storage; do (cd packages/$p && flutter test); done
(cd example/bug_capsule_demo && flutter test)
dart run bug_capsule_cli:bugcapsule --help
```

`spec/fixtures/capsule-v1` holds valid and malformed capsules that both this
SDK and the backend test against; change them here and copy them to the
backend's `test/fixtures/capsule-v1` (its test suite fails when they differ).

Release builds, real-device checks and the overhead budget:
[docs/release-and-device-test-plan.md](docs/release-and-device-test-plan.md).
End-to-end onboarding with the demo app: [docs/onboarding.md](docs/onboarding.md).
