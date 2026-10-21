# BugCapsule Flutter SDK

BugCapsule turns a Flutter failure that QA saw into a portable `.bugcapsule` capsule a developer can **replay on a simulator**, **verify after a fix**, and keep as a **regression test**.

```
QA hits a bug ─► capsule auto-captured & uploaded ─► bugcapsule run <id>   ─► REPRODUCED 3/3
                                                    fix the code
                                                    bugcapsule verify <id> ─► FIXED 0/5
                                                    bugcapsule regress add ─► runs in CI
```

The capsule holds what replay needs: a storage checkpoint, recorded touches and semantic actions, typed text, lifecycle changes, every HTTP exchange with its latency, state-management activity (BLoC, Riverpod, Provider/ChangeNotifier, GetX, MobX), and the failure assertion. All of it is redacted on the device. Replay re-runs the real app code against that recording: network calls are served from the capsule with the same timing, so races and data-dependent bugs come back.

## Package

Everything ships in one package, [`bug_capsule`](packages/bug_capsule), with one import:

```dart
import 'package:bug_capsule/bug_capsule.dart';
```

| Part | What it does |
|---|---|
| Runtime | `BugCapsule.init`, capture (touches, lifecycle, errors, checkpoints), upload, kill switch, replay engine, QA overlay |
| Monitoring | Error events, release health (sessions), tracing (screens, app start, frames, HTTP spans, `traceparent`), user feedback form ([monitoring-v1](https://github.com/draz26648/bug_capsule_backend/blob/main/docs/monitoring-v1.md)) |
| Core | Capsule model ([spec v1](spec/capsule-v1.md)), flight recorder, codec, redaction, network matching |
| `BugCapsuleBloc` | BLoC/Cubit transitions, state snapshots and restore |
| `BugCapsuleRiverpod` | Riverpod 3 provider activity, state snapshots and restore |
| `BugCapsuleNotifiers` | Provider / `ChangeNotifier` / `ValueNotifier` changes, state snapshots and restore |
| `BugCapsuleGetx` | GetX controller updates and `Rx` changes, state snapshots and restore |
| `BugCapsuleMobx` | MobX observable writes, actions and reaction errors; store snapshots and restore |
| `BugCapsuleDio` | Transport-level HTTP capture and deterministic replay with endpoint normalization (also covers Retrofit) |
| `BugCapsuleHttp` | The same for `package:http` clients (also covers Chopper and other `http.Client` based APIs) |
| `BugCapsuleGoRouter` | Navigation capture and route restore |
| `BugCapsuleSharedPreferences` | SharedPreferences snapshot/restore (allowlist) |
| `bugcapsule` CLI | `bugcapsule inspect / run / verify / regress / list / pull / push / share / capture / symbols` |

[`example/bug_capsule_demo`](example/bug_capsule_demo) is a shop app with planted "cannot reproduce" bugs.

The package depends on every library it integrates with, so your app's
versions must fall in these ranges even for libraries you don't use with
BugCapsule: `bloc` ^9, `riverpod` ^3, `get` ^4.6, `mobx` ^2.3, `dio` ^5.9,
`http` ^1.5, `go_router` 14 to 18, `shared_preferences` ^2.5. Code you don't
use is tree-shaken out of release builds.

The backend (upload, triage, kill switch, share links) lives in [draz26648/bug_capsule_backend](https://github.com/draz26648/bug_capsule_backend).

## Integrate (about 20 lines)

```yaml
dependencies:
  bug_capsule: {git: {url: https://github.com/draz26648/bug_capsule_flutter_sdk, path: packages/bug_capsule}}
```

```dart
import 'package:bug_capsule/bug_capsule.dart';

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

### Other state management and HTTP clients

They come with the same package; use the ones that match your app. They can be combined (e.g. Riverpod with `package:http`).


```dart
// Riverpod 3: register providers whose state replay should restore, and add the observer.
final bugCapsuleRiverpod = BugCapsuleRiverpod(states: [
  BugCapsuleRiverpodState<Cart>(cartProvider, toJson: (c) => c.toJson(), fromJson: Cart.fromJson),
]);
// appRunner: () => runApp(ProviderScope(observers: [bugCapsuleRiverpod.observer], child: const MyApp())),

// Provider / ChangeNotifier / ValueNotifier: track each model where you create it.
final bugCapsuleNotifiers = BugCapsuleNotifiers();
ChangeNotifierProvider(
  create: (_) => bugCapsuleNotifiers.track(CartModel(), id: 'cart',
      toJson: (m) => m.toJson(), restore: (m, json) => m.replaceWith(CartModel.fromJson(json))),
  child: ...,
);

// GetX: track Rx values and GetBuilder controllers where you create them.
final bugCapsuleGetx = BugCapsuleGetx();
class CartController extends GetxController {
  final coupon = bugCapsuleGetx.trackRx(''.obs, id: 'cart.coupon');   // primitives need no serializer
  final items = bugCapsuleGetx.trackRx(<CartItem>[].obs, id: 'cart.items',
      toJson: (items) => {'items': [for (final i in items) i.toJson()]},
      fromJson: (json) => [for (final i in json['items'] as List) CartItem.fromJson(i as Map<String, Object?>)]);
}

// MobX: observable writes, actions and reaction errors are recorded on their own;
// track stores whose state replay should restore (restore runs inside an action).
final bugCapsuleMobx = BugCapsuleMobx();
final cart = bugCapsuleMobx.track(CartStore(), id: 'cart', toJson: (s) => s.toJson(), restore: (s, json) => s.replaceWith(json));

// package:http (and Chopper, graphql, generated clients): wrap the client.
final bugCapsuleHttp = BugCapsuleHttp(rules: [EndpointRule('POST', '/api/checkout', ignoreBodyFields: {'nonce'})]);
final client = bugCapsuleHttp.client();                  // or bugCapsuleHttp.client(existingClient)
final chopper = ChopperClient(client: bugCapsuleHttp.client(), ...);

// and list them: integrations: [bugCapsuleRiverpod, bugCapsuleNotifiers, bugCapsuleGetx, bugCapsuleMobx, bugCapsuleHttp, ...]
```

| Library | Integration | Notes |
|---|---|---|
| `flutter_bloc` / `bloc` | `BugCapsuleBloc` | global `BlocObserver`, no per-bloc setup |
| `riverpod` / `flutter_riverpod` / `hooks_riverpod` 3.x | `BugCapsuleRiverpod` | `NotifierProvider`, `AsyncNotifierProvider`, `StreamNotifierProvider` (and families) restore on their own; providers generated by `riverpod_generator` need a `restore:` callback and a registration to be checkpointed |
| `provider`, `ChangeNotifier`, `ValueNotifier`, any `Listenable` | `BugCapsuleNotifiers` | wrap each model in `track(...)`; `restore:` puts state back |
| `get` (GetX) | `BugCapsuleGetx` | `trackRx(...)` for `.obs` values, `track(...)` for `GetBuilder` controllers; `update([ids])` is not seen, only `update()` |
| `mobx` / `flutter_mobx` | `BugCapsuleMobx` | spy-based: no setup for recording; `track(...)` stores to checkpoint and restore them |
| `dio`, `retrofit` | `BugCapsuleDio` | `attach(dio)` |
| `http`, `chopper`, anything taking an `http.Client` | `BugCapsuleHttp` | `client(inner)`; same request keys and capsule events as Dio |

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

## Monitoring: errors, release health, tracing, feedback

A capsule is a heavy recording of one failure. Next to capsules the SDK sends
the light, high-volume signals of
[monitoring-v1](https://github.com/draz26648/bug_capsule_backend/blob/main/docs/monitoring-v1.md):
error events (grouped into issues), sessions (crash-free rates per release),
transactions (performance) and user feedback, as envelopes to
`POST /v1/envelope` with the same ingest key. It is on by default. Every item
goes through the capsule redaction rules on the device before it is queued.

```dart
void main() => BugCapsule.runZonedGuarded(() => BugCapsule.init(
      config: BugCapsuleConfig(
        appId: 'com.shop.app',                 // release defaults to com.shop.app@1.4.0+52
        appVersion: '1.4.0',
        appBuild: '52',
        backend: const BugCapsuleBackendConfig(url: '...', ingestKey: 'bci_...'),
        monitoring: MonitoringOptions(
          tracesSampleRate: 0.2,                       // default: the backend's rate, else 0
          tracePropagationTargets: ['api.shop.com'],  // URLs that get traceparent / baggage
          beforeSend: (event, hint) => event,          // last look; return null to drop
        ),
      ),
      integrations: [bugCapsuleDio, bugCapsuleRouter],
      appRunner: () => runApp(const MyApp()),
    ));
```

What happens without more code:

| Signal | How |
|---|---|
| Errors | `FlutterError.onError` (`flutter_error`), `PlatformDispatcher.onError` (`platform_dispatcher`), uncaught errors of the main isolate and zone errors under `BugCapsule.runZonedGuarded` (`uncaught`). Unhandled errors are `fatal` (`crashOnUnhandled`). One error sent through several handlers is sent once; the same error repeating (say, in `build` every frame) is sent at most 10 times a minute. |
| Stack traces | Parsed into frames, oldest call first; `inApp` for your package (detected from the caller of `BugCapsule.init`, or `inAppIncludes`). AOT builds with `--split-debug-info` send `instructionAddr` frames and an `elf` debug image with the build id; `--obfuscate` builds add a `dart_obfuscation` image from `--dart-define=BUGCAPSULE_OBFUSCATION_ID`. The backend symbolicates both with the files from `bugcapsule symbols upload`. |
| Breadcrumbs | Derived from the flight recorder's events: routes, actions, HTTP exchanges, lifecycle, logs, errors and state changes (nothing is instrumented twice). |
| Capsules | When a capsule is written for a failure, its event carries `capsuleId` and the capsule carries `manifest.monitoring.eventId`, so the issue lists the capsules that replay it. |
| Sessions | One per foreground run; a new one after 30 s in the background. `crashed` after a fatal event, `abnormal` when the app was killed in the foreground (detected at the next launch). |
| Screens | `navigation` transactions named after the route pattern (`/product/:id`) from `BugCapsuleGoRouter`, or `BugCapsuleNavigatorObserver` for `Navigator` apps, with `time_to_initial_display` and slow / frozen frame counts. |
| App start | An `app.start.cold` transaction from `BugCapsule.init` to the first rasterized frame. |
| HTTP | `http.client` spans for `BugCapsuleDio` and `BugCapsuleHttp` requests under the active span, and `traceparent` / `baggage` headers for `tracePropagationTargets`. The headers are added for the transport only: capsules record your headers, request keys never include headers, and replay adds none. |

```dart
BugCapsule.setUser(const MonitoringUser(id: 'u_123', segment: 'pro'));
BugCapsule.setTag('tenant', 'acme');
BugCapsule.captureException(error, stackTrace: stack, tags: {'flow': 'checkout'});
BugCapsule.captureMessage('payment provider slow', level: EventLevel.warning);
BugCapsule.withScope((scope) { scope.setFingerprint(['checkout-timeout']); BugCapsule.captureException(e); });

await BugCapsule.startSpan('load cart', 'task', (span) async {   // active for its zone
  span.startChild('db', description: 'read cart').finish();
  await dio.get('/cart');                                          // child http.client span
});

// User feedback: a form, a sheet, or your own UI.
showBugCapsuleFeedback(context, eventId: BugCapsule.lastEventId());
BugCapsuleFeedbackForm(onSubmitted: (id) => Navigator.pop(context));
await BugCapsule.captureFeedback(message: 'Checkout did nothing', email: 'ana@example.com');
// Shake to report, with the accelerometer of the sensor plugin you use (e.g. sensors_plus):
BugCapsuleShakeToReport(accelerometer: accelerometerEventStream().map((e) => [e.x, e.y, e.z]), child: child);
```

In QA mode submitting feedback also writes a capsule (`captureCapsuleWithFeedback`).
`getTraceparent()` / `getBaggage()` serve custom HTTP clients and
`continueTrace(traceparent, baggage)` joins an incoming trace;
`flush()`, `close()`, `startSession()` / `endSession()` and
`addIsolateErrorListener(isolate)` cover the rest of the API.

The backend can change `monitoringEnabled`, `errorSampleRate`,
`tracesSampleRate`, `sessionTracking`, `maxBreadcrumbs` and
`tracePropagationTargets` in the remote config; the kill switch stops
monitoring too. Envelopes wait in their own outbox (30 envelopes / 5 MiB /
7 days, `MonitoringOptions.outboxLimits`) with the capsule outbox's backoff
and `Retry-After` handling, and are sent only once a remote config fetch has
succeeded. `MonitoringOptions.disabled` turns all of it off.

Release builds with symbols:

```bash
OBF_ID=$(bugcapsule symbols new-id)
flutter build apk --release --obfuscate --split-debug-info=build/symbols \
  --extra-gen-snapshot-options=--save-obfuscation-map=build/obfuscation.json \
  --dart-define=BUGCAPSULE_OBFUSCATION_ID=$OBF_ID
bugcapsule symbols upload --split-debug-info build/symbols \
  --obfuscation-map build/obfuscation.json --obfuscation-id $OBF_ID --release com.shop.app@1.4.0+52
```

Native crashes, ANRs and app hangs in plugins are reported by the BugCapsule
Android and iOS SDKs, not from Dart.

## The CLI

```bash
dart pub global activate --source git https://github.com/draz26648/bug_capsule_flutter_sdk --git-path packages/bug_capsule
# or, inside an app that depends on bug_capsule: dart run bug_capsule:bugcapsule <command>
bugcapsule login --url http://127.0.0.1:8787 --secret-key bcs_... --ingest-key bci_...

bugcapsule list                                   # capsules on the backend
bugcapsule inspect <id|file|share-url>            # failure, eligibility, network, timeline
bugcapsule run <id> -d "iPhone 18 Pro" -n 3       # replay on the capsule's commit (temporary git worktree)
bugcapsule verify <id> -n 5                       # replay on your working tree; FIXED when it no longer fails
bugcapsule regress add <id> && bugcapsule regress run  # keep it as a regression test (exit 1 on failure, for CI)
bugcapsule share <id>                             # expiring public link
bugcapsule capture --on | --off | --sample-rate 0.05   # remote kill switch and production sampling
bugcapsule symbols upload --split-debug-info build/symbols  # debug files for symbolication (secret key)
```

### Other runtimes (CLI 0.3)

The same CLI replays capsules from the native Android, native iOS and web
SDKs: `bugcapsule run|verify|regress` pick the runtime from `--runtime`,
`bugcapsule.json` or the project files, refuse capsules from another runtime
(`INCOMPATIBLE`), and drive an emulator instrumentation, an XCUITest or a
Playwright browser instead of `flutter run`. Every attempt gets its own token
and attempt id on the loopback replay server, and late reports are rejected.
See [docs/cli-runtimes.md](docs/cli-runtimes.md), the runtime contracts in
[spec/runtimes-v1.md](spec/runtimes-v1.md) and the
[feature matrix](docs/feature-matrix.md).

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
4. **Redaction.** Applied on the device to events and checkpoints alike, and again to everything integrations record. See the spec's [Redaction](spec/capsule-v1.md#redaction) section for exactly what is caught and what is not. Add `redactKeys`, `redactPatterns`, `beforeRecord` / `beforeCheckpoint` hooks, `BugCapsuleDio(exclude: ...)` / `BugCapsuleHttp(exclude: ...)` for endpoints you must not record and `BugCapsuleGoRouter(sanitizeLocation: ...)` for secrets in paths; then inspect real capsules (`bugcapsule inspect`) before widening the rollout.
5. **Bodies.** Turn off `captureNetworkBodies` (remotely too) for endpoints you can't send; capsules then become `partial`. HTTP capture never buffers whole bodies: bytes stream to the app unchanged and only a bounded prefix is kept (`maxBodyBytes`, 256 KiB; binary 64 KiB). With bodies off nothing is kept for the recording; request bodies up to 64 KiB are still hashed (never stored) so replay can match requests.
6. **Device storage.** At most 20 saved captures and an upload outbox of 10 capsules / 10 MiB / 7 days (`BugCapsuleConfig.outboxLimits`), oldest evicted first; failed uploads back off from 30 s to 1 h. Disk-full and corrupt files drop the capsule, never the app.
7. **Isolation.** If storage, an integration's setup or anything else in capture setup fails, the app starts without capture. SDK errors are never thrown into the app's error handlers or callbacks.
8. **Performance.** Measure cold start, frame times and memory on a low-end Android device with and without BugCapsule ([plan](docs/release-and-device-test-plan.md)). Pointer and HTTP capture and redaction run on the UI isolate; capsule encoding runs in a background isolate.
9. **Release builds never enter replay mode** (`BUGCAPSULE_REPLAY_URL` and replay request files are ignored when `kReleaseMode`).
10. **Monitoring.** On by default, independent of capsule sampling: every production session sends sessions and (sampled) error events. Set `errorSampleRate` / `tracesSampleRate` and `tracePropagationTargets` deliberately, check `beforeSend` output, upload symbols for every release build, and know that `monitoringEnabled: false` in the remote config stops it without touching capsules.

## Known limitations (v0.2)

- Replay keeps recorded timing, except that idle gaps between inputs longer than 1.5 s shrink to about 0.3 s when the recording and the replayed app are both idle (no pending response, no recent BLoC activity, no pressed pointer; running animations get up to 2 s to finish). Recorded network latency is never shortened. `--no-compress-idle` replays in real time. App `Timer`s are not tracked, so a timer whose effect is not recorded (say, a plain `setState`) can be skipped over; use `--no-compress-idle` if replay depends on one.
- `DateTime.now()`, `Timer`s and animations are not virtualized; only `clock.now()` and `BugCapsule.random` are deterministic.
- Platform channels, native SDKs (Firebase, maps, payments) and WebSockets are not captured. Bugs that depend on them are partial at best. HTTP is captured for Dio and `package:http` clients only (`dart:io` `HttpClient` used directly, `cupertino_http` / `cronet_http` without an `http.Client` wrapper, and GraphQL subscriptions are not).
- Redux has no integration yet; its state is re-executed by replay but not checkpointed or restored.
- Riverpod, `ChangeNotifier`, GetX and MobX state injection from periodic checkpoints has the same limits as BLoC: instances are matched by initialization order (`cart#0`), and an `AsyncNotifier` whose `build` finishes after the restore overwrites the restored state.
- BLoC state injection from periodic checkpoints matches instances by creation order (`CartBloc#0`). BLoCs that dispatch events in their constructor can overwrite restored state. Launch-checkpoint replay (the default for sessions within the 5-minute window) re-executes the session instead and avoids this.
- Pointer replay assumes the same logical screen size; otherwise the CLI scales coordinates and falls back to semantic actions when they exist.
- The Android path (`flutter run` + `adb reverse`) is implemented but has not been exercised end to end yet.
- Redaction is pattern based. It does not recognise personal data that is not a credential (names, emails, addresses) or secrets in URL paths; use the hooks above.
- A request whose server answers before the request body was fully sent is keyed without its body hash; replay may then report it as unrecorded.
- Monitoring: app start is measured from `BugCapsule.init` (the first Dart code) to the first frame, not from process start, and only cold starts are reported. State-management breadcrumbs appear only in sessions that record a capsule (route, action, HTTP, lifecycle, log and error breadcrumbs always do). Trace headers are added only while a span is active (a screen transaction or `startSpan`). `enableUserInteractionTracing` covers `BugCapsule.action` callbacks only. Device model and manufacturer are not collected from Dart (no device-info dependency).
- Capsules captured by SDK 0.1 with body capture off were keyed without body hashes; replaying them with 0.2 reports those requests as unrecorded.

## Upgrading to 0.4 (one package)

The twelve packages (`bug_capsule_core`, `bug_capsule_flutter`, `bug_capsule_bloc`,
`bug_capsule_dio`, …, `bug_capsule_cli`) are now one package, `bug_capsule`. The API
is unchanged; only the dependency and the imports change.

- In `pubspec.yaml`, replace every `bug_capsule_*` dependency with the single `bug_capsule` line above.
- Replace every `package:bug_capsule_*/…` import with `import 'package:bug_capsule/bug_capsule.dart';`.
- CLI: `dart pub global deactivate bug_capsule_cli`, then activate `bug_capsule` as shown in [The CLI](#the-cli).
- Capsules still report `sdk.name: bug_capsule_flutter`, so the backend and older CLIs read them as before.

## Upgrading from 0.1

- `BugCapsuleSession` gained no members; `BugCapsule.resetForTest()` now returns a `Future` (await it in tests).
- The upload outbox is now bounded; files left by 0.1 are kept and count toward the limits.
- CLI 0.2 reports verdicts with `validAttempts`. The backend (0.2) no longer moves a capsule to `fixed` (or `not_reproduced`) on results from CLI 0.1, which could not tell an errored attempt from a passing one; update the CLI.

## Development

```bash
flutter pub get                       # pub workspace: the package and the demo app
(cd packages/bug_capsule && flutter test)   # core, CLI, runtime and every integration
(cd example/bug_capsule_demo && flutter test)
(cd packages/bug_capsule && dart run bugcapsule --help)
```

`spec/fixtures/capsule-v1` holds valid and malformed capsules that both this
SDK and the backend test against; change them here and copy them to the
backend's `test/fixtures/capsule-v1` (its test suite fails when they differ).

Release builds, real-device checks and the overhead budget:
[docs/release-and-device-test-plan.md](docs/release-and-device-test-plan.md).
End-to-end onboarding with the demo app: [docs/onboarding.md](docs/onboarding.md).
