# BugCapsule Flutter SDK

BugCapsule records what led up to a bug in your Flutter app and saves it as a
portable `.bugcapsule` file. A developer can **replay** that file on a
simulator against the real app code, **verify** a fix against it, and keep it
as a **regression test**. The same SDK also reports errors, release health,
performance traces and user feedback, and links each error to the capsule that
replays it.

```
QA hits a bug      ─► capsule captured, redacted on the device, uploaded
bugcapsule run     ─► REPRODUCED 3/3
fix the code
bugcapsule verify  ─► FIXED 5/5
bugcapsule regress ─► runs in CI from now on
```

A capsule holds what replay needs: a storage checkpoint, recorded touches and
actions, typed text, lifecycle changes, every HTTP exchange with its timing,
state-management activity, and the failure itself. Replay runs your real app
code against that recording, with network responses served at their recorded
timing, so races and data-dependent bugs come back.

📖 Full documentation: **[docs.bugcapsule.com/flutter](https://docs.bugcapsule.com/flutter.html)** ·
📦 [pub.dev/packages/bug_capsule](https://pub.dev/packages/bug_capsule)

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Connect your app](#connect-your-app)
- [Make bugs replayable](#make-bugs-replayable)
- [Replay, verify and keep a regression test](#replay-verify-and-keep-a-regression-test)
- [Monitoring](#monitoring)
- [Privacy](#privacy)
- [Going to production](#going-to-production)
- [Limitations](#limitations)
- [Demo app](#demo-app)
- [Upgrading](#upgrading)
- [More documentation](#more-documentation)
- [Support and license](#support-and-license)

## Requirements

- A BugCapsule project. Sign in at [app.bugcapsule.com](https://app.bugcapsule.com).
- Flutter 3.35+ and Dart 3.9+.
- An iOS simulator (or Android emulator) and `git` for replay.

## Install

Current Flutter SDK release: [0.4.1-beta.8](https://pub.dev/packages/bug_capsule/versions/0.4.1-beta.8).
This release hides the capture overlay by default and in all Flutter release
builds, and adds a safe message for widget build failures while preserving
background error reporting. Rebuild your app after upgrading.

```bash
flutter pub add bug_capsule:^0.4.1-beta.8
```

Everything ships in this one package, with one import:

```dart
import 'package:bug_capsule/bug_capsule.dart';
```

The package depends on every library it integrates with, so your app's
versions must fall in these ranges even for libraries you don't use:
`bloc` ^9, `riverpod` ^3, `get` ^4.6, `mobx` ^2.3, `dio` ^5.9, `http` ^1.5,
`go_router` 14 to 18, `shared_preferences` ^2.5. Code you don't use is
tree-shaken out of release builds.

> **Versions.** SDK tokens and connection status are available starting with `0.4.1-beta.2`.
> Existing explicit backend configuration remains supported.

## Connect your app

### 1. Get an SDK token

In the dashboard, open **Project settings → Keys → SDK tokens** and generate a
token. It looks like `bcsdk.v1.…` and is shown once, so copy it right away.

The SDK token is the only value your app needs. It holds your BugCapsule
address and a send-only credential: it can upload capsules and monitoring data
and read capture settings, nothing else. That makes it safe to ship in the
app. You can rotate or revoke it in the dashboard at any time.

### 2. Initialize first thing in `main`

```dart
import 'package:bug_capsule/bug_capsule.dart';

void main() => BugCapsule.init(
      config: const BugCapsuleConfig(token: 'bcsdk.v1.…'),
      appRunner: () => runApp(const MyApp()),
    );
```

That is a complete connection. `appVersion` and `appBuild` are optional; set
them (or the `BUGCAPSULE_APP_VERSION` / `BUGCAPSULE_APP_BUILD` dart-defines)
so capsules and releases carry your real version.

**It never breaks your app.** A token that can't be used doesn't throw or
wait: `init` prints one `[bugcapsule] …` line saying what to fix and the app
runs without uploads. Being offline is never fatal either: capsules wait in an
on-device outbox and go out once BugCapsule is reachable.

### 3. Check the connection

```dart
final status = BugCapsule.status;
status.connection.state;                   // connected, connecting, offline, rejected, …
status.connection.message;                 // what to do, when something is wrong
status.connection.configFetchedAt;         // set once BugCapsule accepted the token
status.connection.firstCapsuleAcceptedAt;  // set once a capsule reached your project
status.instrumentation.missing;            // e.g. [network, navigation, app_state]
```

| `state` | Meaning | What to do |
|---|---|---|
| `not_configured` | No token and no backend: capture stays on the device. | Pass a token. |
| `invalid_token` / `unsupported_token_version` | The token can't be used; `message` says why. | Paste the full `bcsdk.v1.…` token, or update the SDK. |
| `connecting` | No configuration fetched yet in this session. | Wait a moment. |
| `connected` | The configuration was fetched. | Nothing. |
| `offline` | BugCapsule can't be reached; data is kept and retried. | Check the device's network. |
| `rejected` | The token was refused (`reason`: `token_revoked`, `token_expired`, `token_unknown`, …). Capture and uploads stop for this session. | Generate a new token. |
| `disabled` | `enabled: false`, or capture is switched off for the project. | — |

### Connect with an address and ingest key

For self-hosted setups, older SDK versions, or apps that already pass an
address explicitly:

```dart
config: const BugCapsuleConfig(
  backend: BugCapsuleBackendConfig(url: 'https://api.bugcapsule.com', ingestKey: 'bci_…'),
),
```

`backend` wins when both are set (the SDK prints that the token was ignored).
The ingest key is public like the token. **Never put a `bcs_…` secret key in
an app.**

## Make bugs replayable

Being connected is not the same as faithful replay. Replay also needs your
app's network, navigation and state. Add the integrations that match your app;
`BugCapsule.status.instrumentation.missing` tells you what is left.

| Replay needs | Add |
|---|---|
| Network | `BugCapsuleDio` or `BugCapsuleHttp` |
| Navigation | `BugCapsuleGoRouter` |
| App state | `BugCapsuleBloc`, `BugCapsuleRiverpod`, `BugCapsuleNotifiers`, `BugCapsuleGetx`, `BugCapsuleMobx`, `BugCapsuleSharedPreferences` |

A typical BLoC + Dio + GoRouter app:

```dart
final bugCapsuleDio = BugCapsuleDio(rules: [
  // Fields that change on every run must not affect request matching.
  EndpointRule('POST', '/api/checkout', ignoreBodyFields: {'timestamp', 'nonce'}),
]);
final bugCapsuleRouter = BugCapsuleGoRouter();

void main() => BugCapsule.init(              // first line of main, before ensureInitialized
      config: const BugCapsuleConfig(
        token: 'bcsdk.v1.…',
        appVersion: '1.4.0',
        appBuild: '52',
        mode: CaptureMode.qa,                // or the BUGCAPSULE_MODE dart-define
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

// Where you create Dio and GoRouter:
bugCapsuleDio.attach(dio);                   // after any custom adapter
final router = GoRouter(initialLocation: bugCapsuleRouter.initialLocation('/'), routes: [...]);
bugCapsuleRouter.attach(router);

// Optional QA capture button:
MaterialApp.router(builder: (context, child) => BugCapsuleOverlay(child: child!), ...);
```

Build QA builds with the commit, so replay can check out the same code:

```bash
flutter build ipa --dart-define=BUGCAPSULE_GIT_SHA=$(git rev-parse HEAD) --dart-define=BUGCAPSULE_MODE=qa
```

### Other state management and HTTP clients

They can be combined, for example Riverpod with `package:http`.

| Library | Integration | Setup |
|---|---|---|
| `flutter_bloc` / `bloc` | `BugCapsuleBloc` | A global `BlocObserver`; no per-bloc setup. |
| `riverpod` / `flutter_riverpod` / `hooks_riverpod` 3.x | `BugCapsuleRiverpod` | Add its `observer` to `ProviderScope`. Notifier providers restore on their own; `riverpod_generator` providers need a `restore:` callback. |
| `provider`, `ChangeNotifier`, `ValueNotifier` | `BugCapsuleNotifiers` | Wrap each model in `track(...)`. |
| `get` (GetX) | `BugCapsuleGetx` | `trackRx(...)` for `.obs` values, `track(...)` for `GetBuilder` controllers. |
| `mobx` / `flutter_mobx` | `BugCapsuleMobx` | Records on its own; `track(...)` stores you want restored. |
| `dio`, `retrofit` | `BugCapsuleDio` | `attach(dio)` |
| `http`, `chopper`, anything that takes an `http.Client` | `BugCapsuleHttp` | `client(inner)` |

```dart
// Riverpod 3
final bugCapsuleRiverpod = BugCapsuleRiverpod(states: [
  BugCapsuleRiverpodState<Cart>(cartProvider, toJson: (c) => c.toJson(), fromJson: Cart.fromJson),
]);
// appRunner: () => runApp(ProviderScope(observers: [bugCapsuleRiverpod.observer], child: const MyApp())),

// Provider / ChangeNotifier
final bugCapsuleNotifiers = BugCapsuleNotifiers();
ChangeNotifierProvider(
  create: (_) => bugCapsuleNotifiers.track(CartModel(), id: 'cart',
      toJson: (m) => m.toJson(), restore: (m, json) => m.replaceWith(CartModel.fromJson(json))),
  child: ...,
);

// GetX
final bugCapsuleGetx = BugCapsuleGetx();
class CartController extends GetxController {
  final coupon = bugCapsuleGetx.trackRx(''.obs, id: 'cart.coupon');   // primitives need no serializer
}

// MobX
final bugCapsuleMobx = BugCapsuleMobx();
final cart = bugCapsuleMobx.track(CartStore(), id: 'cart',
    toJson: (s) => s.toJson(), restore: (s, json) => s.replaceWith(json));

// package:http, Chopper, generated clients
final bugCapsuleHttp = BugCapsuleHttp(rules: [EndpointRule('POST', '/api/checkout', ignoreBodyFields: {'nonce'})]);
final client = bugCapsuleHttp.client();                 // or bugCapsuleHttp.client(existingClient)

// Then list them: integrations: [bugCapsuleRiverpod, bugCapsuleHttp, ...]
```

### WebSockets, platform channels and native SDKs

These integrations make the capsule spec v2: replay needs the same adapters
in the build, and the CLI checks that before the app starts. Each recorded
interaction is replayed offline. Replay never reaches the real socket,
plugin or SDK, also when a fixture is missing. A verify with missing, extra
or mismatched interactions is never reported as fixed.

| Dependency | Integration | Setup |
|---|---|---|
| WebSockets (`web_socket_channel` 3, `dart:io` `WebSocket`) | `BugCapsuleWebSocket` | Open sockets with `connect(uri)` (a `WebSocketChannel`) or `connectIo(url)`. Binary frames are kept as sizes only unless `captureBinary: true`. |
| Platform channels (MethodChannel, EventChannel, BasicMessageChannel) | `BugCapsulePlatformChannels` | List the channels and their codecs. Plugins on the default messenger are covered because `BugCapsule.init` creates the binding. |
| Firebase Auth and Firestore, geolocator, Google Maps, Stripe | `bug_capsule_firebase`, `bug_capsule_geolocator`, `bug_capsule_google_maps`, `bug_capsule_stripe` | Separate packages; see each README for the tested versions and operations. |
| Any other SDK | `NativeAdapter` | Wrap the operations your app uses with `call(...)` and `subscribe(...)`; check it with `AdapterConformance` from `package:bug_capsule/testing.dart`. |

```dart
final sockets = BugCapsuleWebSocket();
final channels = BugCapsulePlatformChannels(channels: [
  PlatformChannel.method('plugins.example.com/battery'),
  PlatformChannel.event('plugins.example.com/charging'),
]);
// integrations: [sockets, channels, ...]

final quotes = sockets.connect(Uri.parse('wss://quotes.example.com/v1'));
```

Native adapters replay what the app saw (a Firestore snapshot, a location
fix, the outcome of a payment sheet). They do not reproduce native
rendering, map tiles or provider behaviour, and never make a real charge.
The project's capture settings can turn off one adapter without touching
HTTP capture.

### Hooks that make more bugs reproducible

| Add this | Why |
|---|---|
| `onPressed: BugCapsule.action('cart.checkout', () => ...)` | Replay can invoke the action by id, even when the developer's screen differs from QA's. |
| `BugCapsule.trackText('login.email', controller)` | Typed text is replayed. Sensitive ids (`password`, `otp`, …) are redacted; use `sensitive: true` for every obscured field. |
| `BugCapsule.check('cart_total_non_negative', total >= 0)` / `BugCapsule.fail(id)` | Wrong behaviour that doesn't throw becomes a failure replay can check. |
| `clock.now()` (package `clock`) instead of `DateTime.now()` | Replay returns the recorded time. |
| `BugCapsule.random` instead of `Random()` | Seeded per session, same seed in replay. |

Every capsule reports its **eligibility** (`eligible`, `partial` or
`ineligible`) and says exactly what is missing: no git SHA, no failure
assertion, response bodies not captured, a BLoC without a serializer, and so
on.

## Replay, verify and keep a regression test

### Install the CLI

The standalone CLI and native plugin have their own version numbers; they do
not need to match the Flutter SDK version.

Install the multi-runtime CLI with npm (Node.js 20 or newer):

```sh
npm install -g @bugcapsule/cli@0.4.0-beta.3
bugcapsule --version
bugcapsule login
```

No Dart or Flutter installation is needed for the CLI. On first use it downloads
and verifies a standalone executable for macOS (Apple Silicon or Intel), Linux
(ARM64 or x64), or Windows x64. Later runs use the cached executable, including
offline inspection. Direct executable downloads are available in the
[CLI release](https://github.com/BugCapsule/bug_capsule_flutter_sdk/releases/tag/v0.4.1-beta.7).

Replay needs the toolchain of the app being tested: Flutter for Flutter apps,
Android SDK/JDK for Android, Xcode on macOS for iOS, or Node/Playwright for web.
Existing Flutter projects can still use `dart run bug_capsule:bugcapsule`.
If an old Dart installation owns the `bugcapsule` command, deactivate it with
`dart pub global deactivate bug_capsule` before installing the npm CLI.

### Run it

```bash
bugcapsule list                                   # capsules in your project
bugcapsule inspect <id|file|share-url>            # failure, eligibility, network, timeline
bugcapsule run <id> -d <simulator> -n 3          # replays on the capsule's commit (temporary git worktree)
bugcapsule verify <id> -n 5                       # replays your working tree; FIXED when the bug is gone
bugcapsule regress add <id>                       # keep it as a regression test
bugcapsule regress run                            # in CI: exit 1 when a regression fails
bugcapsule gate --release com.shop.app@1.5.0+60 --platform android   # release gate in CI
bugcapsule share <id>                             # expiring download link
bugcapsule capture --on | --off | --sample-rate 0.05   # kill switch and production sampling
```

Flutter apps that use the defaults need no `bugcapsule.json`. Replay is never
armed in release builds.

### Verdicts

| `bugcapsule run` | `bugcapsule verify` | Exit code |
|---|---|---|
| `REPRODUCED`: every attempt hit the original failure | `FIXED`: every attempt ran cleanly | 0 |
| `NOT REPRODUCED`: every attempt ran cleanly | `STILL FAILING`: the failure came back, no clean attempt | 1 |
| `FLAKY`: some attempts reproduced, some didn't | `FLAKY` | 2 |
| `INCONCLUSIVE` / `INCOMPATIBLE`: anything else | `INCONCLUSIVE` / `INCOMPATIBLE` | 3 |

An attempt only counts as clean when every recorded input was replayed and
nothing important diverged (an unregistered action, a request without a
recorded response, a missing restore, …). Attempts that never ran count
against the total, so one clean attempt plus one error is `INCONCLUSIVE`,
never `FIXED`. Details: [How verdicts work](https://docs.bugcapsule.com/verdicts.html) ·
[CLI reference](https://docs.bugcapsule.com/cli.html).

A crash capsule reproduces when the app dies with the same crash (same
signal, Mach exception, ANR or out-of-memory kill); a different crash is
`INCONCLUSIVE` with reason code `failure.different`. `run` and `verify` record
each run with the release of the build under test (read from the pubspec,
the APK or the app's `Info.plist`; `--release` overrides).

### Release gate

`bugcapsule gate` blocks a release that brings a fixed bug back. It asks
BugCapsule which capsules the release must not reproduce (fixes it claims,
and bugs fixed earlier), builds the app once, verifies each one, records the
runs and a gate report on the release, prints a table and writes JUnit XML:

```bash
BUGCAPSULE_TOKEN=bcv_… bugcapsule gate --release com.shop.app@1.5.0+60 \
  --platform android --attempts 3 --junit build/bugcapsule-gate.xml
```

Exit codes: 0 passed, 1 a capsule reproduced, 2 flaky (`--fail-on`, default
`reproduced,flaky`), 3 a capsule could not run (only with `error` in
`--fail-on`), 64 usage. `--json` prints the result as JSON. The service
token needs the `capsules.read` and `replay.submit` scopes. A GitHub Actions
example is in [docs/cli-runtimes.md](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/docs/cli-runtimes.md#release-gate).

## Monitoring

Monitoring is on by default and runs next to capsules:

| Signal | What you get |
|---|---|
| Errors | `FlutterError.onError`, `PlatformDispatcher.onError` and zone errors under `BugCapsule.runZonedGuarded`; stack frames, breadcrumbs, user and tags. Repeated errors are rate-limited. |
| Native crashes (with `bug_capsule_native`) | Crashes in native code (your plugins', the engine's), ANRs and app hangs, and Android's and iOS's records of how the app died, with every thread and the breadcrumbs of the run that crashed. |
| Release health | One session per foreground run; crash-free rates per release, counted against the release that ran. |
| Performance | App start, screen transactions with slow and frozen frames, HTTP spans, `traceparent` / `baggage` propagation. |
| User feedback | A form, a sheet, shake to report, or your own UI. |

When a capsule is written for an error, the error links to it, so each issue
lists the capsules that replay it.

```dart
void main() => BugCapsule.runZonedGuarded(() => BugCapsule.init(
      config: BugCapsuleConfig(
        token: 'bcsdk.v1.…',
        appId: 'com.shop.app',                         // release defaults to com.shop.app@<version>+<build>
        monitoring: MonitoringOptions(
          tracesSampleRate: 0.2,
          tracePropagationTargets: ['api.shop.com'],   // URLs that get traceparent / baggage
          beforeSend: (event, hint) => event,          // return null to drop an event
        ),
      ),
      integrations: [bugCapsuleDio, bugCapsuleRouter],
      appRunner: () => runApp(const MyApp()),
    ));

BugCapsule.setUser(const MonitoringUser(id: 'u_123'));
BugCapsule.captureException(error, stackTrace: stack);
showBugCapsuleFeedback(context, eventId: BugCapsule.lastEventId());
```

`MonitoringOptions.disabled` turns monitoring off; capsules keep working.
More: [docs.bugcapsule.com/monitoring](https://docs.bugcapsule.com/monitoring.html).

**Native crashes.** Dart can't see a crash in native code. Add
`bug_capsule_native` and nothing else: it registers itself and
`BugCapsule.init` starts it.

```yaml
dependencies:
  bug_capsule: ^0.4.1-beta.8
  bug_capsule_native: ^0.1.0-beta.1
```

Native crashes are reported on the next launch, in the same issues and
sessions as Dart errors, and go through `beforeSend`. The session that crashed
counts as `crashed`. Turn it off with
`MonitoringOptions(enableNativeCrashHandling: false)`; tune hangs with
`enableAppHangTracking` and `appHangTimeout`. On iOS the plugin needs Swift
Package Manager (`flutter config --enable-swift-package-manager`); with
CocoaPods it builds but reports no native crashes on iOS.

**Crash capsules.** A crash that kills the process leaves no time to write a
capsule, so while a session records, the SDK keeps a crash journal on disk:
the flight recorder's checkpoints and events, flushed at least every 250 ms
from a background isolate, at most twice `maxCapsuleBytes`. On the next
launch the crash's event gets a capsule built from that journal (failure
kind `crash`, linked through `capsuleId`), which `bugcapsule run` replays and
checks for the same crash. Crash capsules don't count against
`maxCapsulesPerSession`. Turn the journal off with
`BugCapsuleConfig(crashJournal: false)`.

**Readable stack traces.** For obfuscated or `--split-debug-info` builds,
upload symbols for every release:

```bash
OBF_ID=$(bugcapsule symbols new-id)
flutter build apk --release --obfuscate --split-debug-info=build/symbols \
  --extra-gen-snapshot-options=--save-obfuscation-map=build/obfuscation.json \
  --dart-define=BUGCAPSULE_OBFUSCATION_ID=$OBF_ID
bugcapsule symbols upload --split-debug-info build/symbols \
  --obfuscation-map build/obfuscation.json --obfuscation-id $OBF_ID --release com.shop.app@1.4.0+52
```

## Privacy

Redaction runs on the device before anything is stored or uploaded:
sensitive keys in bodies, storage and state; sensitive headers; credentials in
URLs; and tokens, JWTs, API keys and card numbers in free text.

Tighten it with `redactKeys`, `redactPatterns`, `beforeRecord` /
`beforeCheckpoint`, `BugCapsuleDio(exclude: ...)` / `BugCapsuleHttp(exclude: ...)`
for endpoints you must not record, and `BugCapsuleGoRouter(sanitizeLocation: ...)`
for secrets in paths. Your project settings can also add redaction keys, turn
off body capture, lower sampling or switch capture off remotely.

Redaction is pattern-based. It does **not** find personal data that isn't a
credential (names, emails, addresses) or secrets in URL paths. Inspect real
capsules with `bugcapsule inspect` before a wider rollout. More:
[Privacy and redaction](https://docs.bugcapsule.com/privacy.html).

## Going to production

Production capture works, but it is the riskiest mode. Before rollout:

1. **Test the kill switch.** `bugcapsule capture --on` stops capture for every
   device at its next config refresh (5 minutes by default), and deletes
   queued capsules. `bugcapsule capture --off` resumes it.
2. **Set sampling.** A production session records with probability
   `productionSampleRate` (default `0.1`), capped by your project's rate.
3. **Review redaction** with a real login and payment flow.
4. **Decide on bodies.** Turn off `captureNetworkBodies` (also possible
   remotely) for endpoints you can't send.
5. **Measure** cold start, frame times and memory on a low-end device with and
   without BugCapsule.
6. **Upload symbols** for every release build.

Capture never crashes the app: if setup fails the app starts without it, and
storage errors drop the capsule. Release builds never enter replay mode. Full
details: [docs/how-it-works.md](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/docs/how-it-works.md) and the
[production checklist](https://docs.bugcapsule.com/production.html).

## Limitations

- `DateTime.now()`, `Timer`s and animations are not virtualized; only
  `clock.now()` and `BugCapsule.random` are deterministic.
- WebSockets, platform channels and native SDKs are captured only through
  their integrations: sockets opened another way, channels that are not
  listed, background isolates, extra engines, FFI and platform views are not.
  HTTP is captured for Dio and `package:http` clients only.
- Redux has no integration yet.
- Pointer replay assumes the same logical screen size; otherwise the CLI scales
  coordinates and falls back to semantic actions where they exist.
- Replay on Android (`flutter run` + `adb reverse`) is implemented but not yet
  tested end to end. iOS simulators are the tested path.

Full list: [docs/how-it-works.md#limitations](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/docs/how-it-works.md#limitations).

## Demo app

A minimal [published example](https://pub.dev/packages/bug_capsule/example)
shows initialization, navigation monitoring, and manual capsule capture.

[`example/bug_capsule_demo`](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/example/bug_capsule_demo) is a shop app with
five planted "can't reproduce" bugs. With an SDK token and the CLI logged in:

```bash
cd example/bug_capsule_demo
flutter run -d <simulator> --dart-define=BUGCAPSULE_GIT_SHA=$(git rev-parse HEAD) \
  --dart-define=BUGCAPSULE_TOKEN=bcsdk.v1.…
```

| Bug | How to trigger | What replay needs |
|---|---|---|
| Profile/recommendations race | Tap **Refresh picks** until it crashes (~1 in 4) | Recorded response timing |
| Legacy cart cache | **Simulate upgrade from v0.9**, restart, open the cart | Storage from the launch checkpoint |
| Negative total | Open the cart until the subtotal is under $100, apply `SAVE100` | Typed text, server cart, custom assertion |
| Discontinued item | Open the cart until "unavailable" shows, check out | The server response with `price: null` |
| Orders stuck loading | Open **My orders** until it spins for more than 4 s | The recorded `202` and a watchdog assertion |

Then `bugcapsule list`, `bugcapsule run <id>`, fix the bug and
`bugcapsule verify <id>`. A step-by-step walkthrough is in
[docs/onboarding.md](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/docs/onboarding.md).

## Upgrading

**To 0.4 (one package).** The twelve `bug_capsule_*` packages are now one
package, `bug_capsule`, with the same API:

- Replace every `bug_capsule_*` dependency with `bug_capsule`.
- Replace every `package:bug_capsule_*/…` import with
  `import 'package:bug_capsule/bug_capsule.dart';`.
- CLI: `dart pub global deactivate bug_capsule_cli`, then
  [install the CLI](#install-the-cli) again.

Older upgrades: [docs/upgrading.md](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/docs/upgrading.md).

## More documentation

| Topic | Where |
|---|---|
| Flutter SDK guide | [docs.bugcapsule.com/flutter](https://docs.bugcapsule.com/flutter.html) |
| Quickstart (30 minutes, capture to verified fix) | [docs.bugcapsule.com/quickstart](https://docs.bugcapsule.com/quickstart.html) |
| CLI reference | [docs.bugcapsule.com/cli](https://docs.bugcapsule.com/cli.html) |
| Replaying Android, iOS and web capsules with the CLI | [docs/cli-runtimes.md](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/docs/cli-runtimes.md) |
| Capsule format | [spec/capsule-v1.md](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/spec/capsule-v1.md) |
| How capture, uploads and replay work | [docs/how-it-works.md](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/docs/how-it-works.md) |
| Feature matrix across SDKs | [docs.bugcapsule.com/feature-matrix](https://docs.bugcapsule.com/feature-matrix.html) |
| Troubleshooting | [docs.bugcapsule.com/troubleshooting](https://docs.bugcapsule.com/troubleshooting.html) |
| Working on this repository | [docs/development.md](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/docs/development.md) |

## Support and license

Questions or access requests: [contact@bugcapsule.com](mailto:contact@bugcapsule.com).

This SDK and its bundled CLI are available under the MIT License. See [LICENSE](https://github.com/BugCapsule/bug_capsule_flutter_sdk/blob/main/LICENSE).

## Optional capsule screenshots (unreleased)

Opt-in PNG frames are stored inside capsules and displayed against event time.
See [capture, privacy, limits and platform examples](spec/screenshots-v1.md).
