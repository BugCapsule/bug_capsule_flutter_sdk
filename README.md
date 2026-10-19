# Repro Flutter SDK

Repro turns a Flutter failure that QA saw into a portable `.repro` capsule a developer can **replay on a simulator**, **verify after a fix**, and keep as a **regression test**.

```
QA hits a bug ─► capsule auto-captured & uploaded ─► repro run <id>   ─► REPRODUCED 3/3
                                                    fix the code
                                                    repro verify <id> ─► FIXED 0/5
                                                    repro regress add ─► runs in CI
```

The capsule holds what replay needs: a storage checkpoint, recorded touches and semantic actions, typed text, lifecycle changes, every HTTP exchange with its latency, BLoC activity, and the failure assertion. All of it is redacted on the device. Replay re-runs the real app code against that recording: network calls are served from the capsule with the same timing, so races and data-dependent bugs come back.

## Packages

| Package | What it does |
|---|---|
| [`repro_core`](packages/repro_core) | Pure Dart: capsule model ([spec v1](spec/capsule-v1.md)), flight recorder, codec, redaction, network matching |
| [`repro_flutter`](packages/repro_flutter) | `Repro.init`, capture (touches, lifecycle, errors, checkpoints), upload, kill switch, replay engine, QA overlay |
| [`repro_bloc`](packages/repro_bloc) | BLoC/Cubit transitions, state snapshots and restore |
| [`repro_dio`](packages/repro_dio) | Transport-level HTTP capture and deterministic replay with endpoint normalization |
| [`repro_go_router`](packages/repro_go_router) | Navigation capture and route restore |
| [`repro_storage`](packages/repro_storage) | SharedPreferences snapshot/restore (allowlist) |
| [`repro_cli`](packages/repro_cli) | `repro inspect / run / verify / regress / list / pull / push / share / capture` |
| [`example/repro_demo`](example/repro_demo) | Shop app with planted "cannot reproduce" bugs |

The backend (upload, triage, kill switch, share links) lives in [draz26648/repro_backend](https://github.com/draz26648/repro_backend).

## Integrate (about 20 lines)

```yaml
dependencies:
  repro_flutter: {git: {url: https://github.com/draz26648/repro_flutter_sdk, path: packages/repro_flutter}}
  repro_bloc:    {git: {url: https://github.com/draz26648/repro_flutter_sdk, path: packages/repro_bloc}}
  repro_dio:     {git: {url: https://github.com/draz26648/repro_flutter_sdk, path: packages/repro_dio}}
  repro_go_router: {git: {url: https://github.com/draz26648/repro_flutter_sdk, path: packages/repro_go_router}}
  repro_storage: {git: {url: https://github.com/draz26648/repro_flutter_sdk, path: packages/repro_storage}}
```

```dart
final reproDio = ReproDio(rules: [
  // Fields that differ on every run must not affect request matching.
  EndpointRule('POST', '/api/checkout', ignoreBodyFields: {'timestamp', 'nonce'}),
]);
final reproRouter = ReproGoRouter();

void main() => Repro.init(                     // first line of main, before ensureInitialized
      config: const ReproConfig(
        appVersion: '1.4.0',
        appBuild: '52',
        mode: CaptureMode.qa,                  // or REPRO_MODE dart-define
        backend: ReproBackendConfig(url: 'https://repro.example.com', ingestKey: 'rpi_...'),
      ),
      integrations: [
        ReproBloc(states: [
          ReproState<CartBloc, CartState>(toJson: (s) => s.toJson(), fromJson: CartState.fromJson),
        ]),
        reproDio,
        reproRouter,
        ReproSharedPreferences(),
      ],
      appRunner: () => runApp(const MyApp()),
    );

// where you build Dio and GoRouter:
reproDio.attach(dio);                                         // after any custom adapter
final router = GoRouter(initialLocation: reproRouter.initialLocation('/'), routes: [...]);
reproRouter.attach(router);

// QA capture button:
MaterialApp.router(builder: (context, child) => ReproOverlay(child: child!), ...);
```

Build with the commit pinned so replay can check out the same code:

```bash
flutter build ipa --dart-define=REPRO_GIT_SHA=$(git rev-parse HEAD) --dart-define=REPRO_MODE=qa
```

### Make more bugs eligible

| Hook | Why |
|---|---|
| `onPressed: Repro.action('cart.checkout', () => ...)` | Semantic replay when the developer's screen differs from QA's |
| `Repro.trackText('login.email', controller)` | Typed text is replayed; sensitive ids (`password`, `otp`, …) are redacted |
| `Repro.check('cart_total_non_negative', total >= 0)` / `Repro.fail(id)` | Wrong behaviour that doesn't throw becomes a checkable failure |
| `clock.now()` (package `clock`) instead of `DateTime.now()` | Replay restores the recorded wall clock |
| `Repro.random` instead of `Random()` | Seeded per session, the same seed on replay |

Every capsule reports its **eligibility** (`eligible` / `partial` / `ineligible`) and lists exactly which dependency is missing (no git SHA, no failure assertion, response bodies not captured, BLoC without a serializer, …). Ineligible capsules are kept but never counted toward the reproduction rate.

## The CLI

```bash
dart pub global activate --source git https://github.com/draz26648/repro_flutter_sdk --git-path packages/repro_cli
repro login --url http://127.0.0.1:8787 --secret-key rps_... --ingest-key rpi_...

repro list                                   # capsules on the backend
repro inspect <id|file|share-url>            # failure, eligibility, network, timeline
repro run <id> -d "iPhone 18 Pro" -n 3       # replay on the capsule's commit (temporary git worktree)
repro verify <id> -n 5                       # replay on your working tree; FIXED when it no longer fails
repro regress add <id> && repro regress run  # keep it as a regression test (exit 1 on failure, for CI)
repro share <id>                             # expiring public link
repro capture --on | --off | --sample-rate 0.05   # remote kill switch and production sampling
```

`run`/`verify` exit codes: `0` expected outcome, `1` opposite, `2` flaky, `3` incompatible or error. Results are recorded on the backend, so a capsule moves `new → reproduced → fixed`.

On an iOS simulator the CLI builds once, then launches the installed app for each attempt. It hands over the replay request through a file in the app's sandbox, because environment variables don't reach the app on recent simulator runtimes. Other devices use `flutter run` with a dart-define for each attempt.

## Try the demo (≈10 minutes)

```bash
# backend: see repro_backend/README.md, then
repro login --url http://127.0.0.1:8787 --secret-key rps_... --ingest-key rpi_...
cd example/repro_demo
flutter run -d <simulator> --dart-define=REPRO_GIT_SHA=$(git rev-parse HEAD) \
  --dart-define=REPRO_BACKEND_URL=http://127.0.0.1:8787 --dart-define=REPRO_INGEST_KEY=rpi_...
```

| Bug | How to trigger | What replay needs |
|---|---|---|
| Profile/recommendations race | tap **Refresh picks** until it crashes (~1 in 4) | recorded response latencies |
| Legacy cart cache | **Simulate upgrade from v0.9**, restart, open cart | storage from the launch checkpoint |
| Negative total | open cart until subtotal < $100, apply `SAVE100` | typed text + server cart + custom assertion |
| Discontinued item | open cart until "unavailable" shows, checkout | the server response with `price: null` |
| Orders stuck loading | open **My orders** until it spins > 4s | the recorded `202` + watchdog assertion |

Then `repro list`, `repro run <id>`, fix the bug, `repro verify <id>`.

Measured on an iPhone 18 Pro simulator (iOS 27, Flutter 3.47.7): the race, legacy-cache and coupon capsules each reproduced 3/3 with pointer replay. The race and legacy-cache capsules also reproduced 1/1 with semantic replay; the legacy-cache one ran on a freshly installed app. A fix for the race verified as `FIXED 2/2`.

## Production checklist

Production capture works, but it is the riskiest mode. Before rollout:

1. **Kill switch.** `repro capture --on` stops capture and uploads on the next config refresh (cached config is read at startup and refreshed in the background, `configTtlSeconds`). Test it before you need it.
2. **Sampling.** A production session records with probability `min(productionSampleRate, backend sampleRate)`. The app's cap defaults to 0.1, so the backend can lower sampling (`repro capture --sample-rate 0.01`) without a release but never raise it past what shipped. Sessions that aren't sampled install no recorders.
3. **Redaction.** Auth headers, cookies, and keys containing `password`/`token`/`secret`/`otp`/`pin`/`cvv`/`card…` are replaced on the device. Add your own with `redactKeys`, and inspect real capsules (`repro inspect`) before widening the rollout.
4. **Bodies.** Turn off `captureNetworkBodies` for endpoints you can't send (capsules then become `partial`).
5. **Performance.** Measure cold start, frame times and memory on a low-end Android device with and without Repro. Pointer and HTTP capture run on the UI isolate; capsule encoding runs in a background isolate.
6. **Release builds never enter replay mode** (`REPRO_REPLAY_URL` and replay request files are ignored when `kReleaseMode`).

## Known limitations (v0.1)

- Replay keeps recorded timing, except that idle gaps between inputs longer than 1.5 s shrink to about 0.3 s when the recording and the replayed app are both idle (no pending response, no recent BLoC activity, no pressed pointer; running animations get up to 2 s to finish). Recorded network latency is never shortened. `--no-compress-idle` replays in real time. App `Timer`s are not tracked, so a timer whose effect is not recorded (say, a plain `setState`) can be skipped over; use `--no-compress-idle` if replay depends on one.
- `DateTime.now()`, `Timer`s and animations are not virtualized; only `clock.now()` and `Repro.random` are deterministic.
- Platform channels, native SDKs (Firebase, maps, payments), WebSockets and the `http` package are not captured. Bugs that depend on them are partial at best.
- BLoC state injection from periodic checkpoints matches instances by creation order (`CartBloc#0`). BLoCs that dispatch events in their constructor can overwrite restored state. Launch-checkpoint replay (the default for sessions within the 5-minute window) re-executes the session instead and avoids this.
- Pointer replay assumes the same logical screen size; otherwise the CLI scales coordinates and falls back to semantic actions when they exist.
- The Android path (`flutter run` + `adb reverse`) is implemented but has not been exercised end to end yet.

## Development

```bash
flutter pub get                       # pub workspace: all packages at once
(cd packages/repro_core && dart test)
(cd packages/repro_dio && flutter test)
dart run repro_cli:repro --help
```
