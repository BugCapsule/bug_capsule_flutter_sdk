# BugCapsule runtime contracts — v1 (Flutter, Android, iOS, web)

[`capsule-v1.md`](capsule-v1.md) defines the capsule format. This document
defines how each runtime fills it, the replay protocol between the
`bugcapsule` CLI and an app, and the conformance fixtures every
implementation runs. It changes nothing for existing Flutter capsules.

| Runtime | SDK (`manifest.sdk.name`) | Language | Replay mechanism |
|---|---|---|---|
| `flutter` | `bug_capsule_flutter` | Dart | in-app engine; `flutter run` / simulator launch |
| `android` | `bugcapsule-android` | Kotlin (Java-friendly API) | in-app engine driven by an AndroidJUnitRunner instrumentation (`am instrument`) |
| `ios` | `bugcapsule-ios` | Swift | in-app engine started by an XCUITest (`xcodebuild test-without-building`) |
| `web` | `@bugcapsule/web` | TypeScript | in-page engine driven by a Playwright (Chromium) runner |

## 1. Compatibility

All additions use the v1 extension rules: readers ignore fields and event
types they do not know, so `specVersion` stays `1`.

* **Old readers, new capsules.** The 0.2 backend, CLI and Flutter SDK accept
  capsules from the new SDKs (unknown manifest fields and event types are
  ignored; every known field keeps its v1 meaning and type).
* **New readers, old capsules.** A capsule without `manifest.runtime` is a
  Flutter capsule when `sdk.name` is `bug_capsule_flutter` (or absent).
* **New validation.** When present, `manifest.runtime` and
  `manifest.capabilities` must have the types below. The Dart reader, the
  backend and the three new readers apply the same rule; shared fixtures
  (`fixtures/capsule-v1/{valid,invalid}`) cover it.

A change that cannot be expressed this way needs `specVersion: 2` and a
compatibility test against every fixture in `fixtures/capsule-v1/valid`.

## 2. Runtime metadata

```json
"runtime": {"name": "android", "version": "35", "language": "kotlin", "frameworks": ["views", "compose"]},
"capabilities": {"input.pointer.replay": "supported", "lifecycle.replay": "partial"}
```

| Field | Type | Notes |
|---|---|---|
| `runtime.name` | string (1-50) | `flutter`, `android`, `ios`, `web`. Unknown names are allowed. |
| `runtime.version` | string? (≤200) | Dart version, Android API level, iOS version, browser name + version. |
| `runtime.language` | string? (≤50) | `dart`, `kotlin`, `swift`, `javascript`. |
| `runtime.frameworks` | string[]? (≤20 × 1-50) | UI frameworks seen: `views`, `compose`, `uikit`, `swiftui`, `react`. |
| `capabilities` | map<string,string> (≤200, keys ≤100, values ≤100) | `supported`, `partial`, `unsupported` or `explicit` (works when the app uses the explicit hook). |

`platform` keeps its v1 fields. Per runtime:

| Runtime | `platform.os` | `osVersion` | `screen` unit | Extra |
|---|---|---|---|---|
| flutter | `ios`, `android`, … | OS version | logical px | `dartVersion` |
| android | `android` | `Build.VERSION.RELEASE` + API | dp (window) | |
| ios | `ios` | `UIDevice.systemVersion` | points (key window) | |
| web | `web` | browser + version | CSS px (viewport) | `userAgent` (string) |

### Capability vocabulary

| Key | Meaning |
|---|---|
| `input.pointer.capture` / `input.pointer.replay` | touches/clicks recorded / re-injected |
| `input.semantic.replay` | registered actions invoked by id |
| `text.replay` | tracked text restored by id |
| `lifecycle.replay` | foreground/background replayed (`partial` = synthetic events) |
| `network.<client>` | `okhttp`, `urlsession`, `fetch`, `xhr`, `dio` exchanges captured and served |
| `storage.<store>` | `shared_preferences`, `datastore`, `user_defaults`, `local_storage`, `session_storage`, `indexeddb` |
| `navigation.<kind>` | `jetpack`, `uikit`, `explicit`, `history`, `react_router` |
| `clock.virtual` / `random.seeded` | `explicit`: only through the SDK clock / random hooks |
| `crash.uncaught` | uncaught exceptions persisted (`partial`: best effort, upload on next launch) |
| `errors.uncaught` | uncaught errors that do not end the process are captured (Flutter, web) |
| `state.registered` / `integration.<name>` | app-registered state serializers / an integration that was set up |

The CLI prints capabilities in `inspect`; replay reports
`capability.unsupported` (material) when a capsule needs one the replaying
runtime lacks.

## 3. Time

Event `t` is integer milliseconds since the session anchor, from a monotonic
clock; `wallClockAtAnchorMs` maps it to wall time.

| Runtime | Monotonic source | Anchor |
|---|---|---|
| flutter | `Stopwatch` | first rendered frame |
| android | `SystemClock.elapsedRealtime()` | first `Activity` window drawn (`ViewTreeObserver.OnDrawListener`) |
| ios | `ProcessInfo.systemUptime` | first key window `didBecomeVisible`, else first `didBecomeActive` |
| web | `performance.now()` | first animation frame after `BugCapsule.init()` resolves (1 s fallback in background tabs) |

Events before the anchor have negative `t`.

## 4. Events

v1 types keep their shape. Additions are optional fields and one new type.

### `lifecycle`

`state` uses the v1 vocabulary. Mapping:

| state | Flutter | Android (process) | iOS | web |
|---|---|---|---|---|
| `resumed` | resumed | first activity `onResume` | `didBecomeActive` | `visibilitychange` → visible, `pageshow` |
| `inactive` | inactive | last activity `onPause` | `willResignActive` | `blur` of the window *(not recorded by default)* |
| `hidden` | hidden | — | — | `visibilitychange` → hidden |
| `paused` | paused | last activity `onStop` | `didEnterBackground` | `pagehide` |
| `detached` | detached | — | `willTerminate` | — |

Replay: Flutter and Android drive the real lifecycle (Android moves the
`ActivityScenario` to the matching state). iOS posts the matching
`UIApplication` notifications and web dispatches `visibilitychange` with an
overridden `document.visibilityState`; both are `partial`.

### `pointer`

`{phase, pointer, x, y, kind, buttons?}` in the `screen` unit above, relative
to the window (Android: screen coordinates divided by density). Web adds an
optional `target` on `down`:

```json
"target": {"action": "cart.checkout", "selector": "[data-testid=\"checkout\"]", "tag": "button", "text": "Checkout"}
```

`action` is the closest `data-bugcapsule-action`, `selector` a stable
selector (`id`, `data-testid`, `data-bugcapsule-action`), `text` the first
40 characters of visible text (scrubbed). Password inputs and elements
marked `data-bugcapsule-sensitive` never contribute text.

Replay injects pointers at the recorded coordinates. When a `target` was
recorded, the web runner hit-tests first: a different element at the point
reports `pointer.mismatch`; a selector matching several elements reports
`selector.ambiguous`; a selector matching nothing reports
`selector.missing`. All three are material.

### `action`, `text`

As v1. Action ids and text ids are app-chosen strings (≤200). The web SDK
records `text` only for inputs registered with `trackInput` and never for
`type=password` or `data-bugcapsule-sensitive` elements (values become the
placeholder).

### `route`

`{location, source?, action?}`. `source`: `go_router`, `navigation`
(Jetpack), `uikit`, `explicit`, `history`, `react_router`. `action`:
`push`, `pop`, `replace`, `reset`. Diagnostic; navigation is reproduced by
replaying the inputs that caused it, and periodic checkpoints restore the
current route.

### `state` (new, diagnostic)

`{key, value?}` when an app-registered state object reports a change. Not
replayed; state comes back through checkpoints.

### `http`

As v1. `error.type` uses one vocabulary in every runtime:

| `error.type` | Android (OkHttp) | iOS (URLSession) | web | Flutter (Dio) |
|---|---|---|---|---|
| `connectionError` | `UnknownHostException`, `ConnectException`, other `IOException` | other `URLError` | `TypeError` from `fetch`, XHR `error` | `connectionError` |
| `connectionTimeout` | `SocketTimeoutException` while connecting | `.timedOut` before response | — | `connectionTimeout` |
| `receiveTimeout` | `SocketTimeoutException` while reading, `InterruptedIOException("timeout")` | `.timedOut` after response | XHR `timeout`, `AbortSignal.timeout` | `receiveTimeout` |
| `cancel` | `call.isCanceled()` | `.cancelled` | `AbortError` | `cancel` |

During replay a recorded error is raised with the runtime's native type
after the recorded `durationMs`, cancellation of the app's request stops
the delay and raises the native cancellation error, and real client
timeouts still apply.

Body capture follows capsule-v1: a bounded prefix (`maxBodyBytes`, default
256 KiB; binary 64 KiB) is kept while the app receives the stream
unchanged. Per runtime: OkHttp taps the `ResponseBody` source; URLSession
forwards each chunk from its protocol to the client; web reads a `clone()`
of the response up to the limit then cancels the clone (the app's stream is
untouched; until the app reads it, the browser buffers the unread part of
the original). `text/event-stream` responses are recorded as `omitted` when
headers arrive. Request bodies that can be read only once (OkHttp
`isOneShot`, fetch `ReadableStream`, URLSession `httpBodyStream`) are keyed
without a hash and recorded as `omitted`.

## 5. Failures

`signature = <kind>:<type>:<normalized message>` (capsule-v1). Sources:

| Runtime | `type` | `message` |
|---|---|---|
| flutter | `runtimeType` | `toString()` |
| android | `Throwable.javaClass.simpleName` | `message ?: ""` |
| ios (Error) | `String(describing: type(of: error))` | `String(describing: error)` |
| ios (NSException) | `exception.name.rawValue` | `exception.reason ?? ""` |
| web | `error.name` (else constructor name, else `Error`) | `error.message` (non-Error values: `String(value)`) |

Assertions (`fail`/`check`) are `assertion:<id>:` in every runtime.

**Automatic capture boundaries** (documented per SDK, never claimed more widely):

* Android: uncaught JVM exceptions on any thread (the previous default
  handler is always called afterwards). The capsule is written
  synchronously to app-private storage and uploaded on the next launch.
  Native crashes, ANRs and `System.exit` are not captured.
* iOS: `NSException`s through a chained `NSSetUncaughtExceptionHandler`
  (best effort, written synchronously, uploaded on next launch) and errors
  the app reports. Swift runtime traps (`fatalError`, force unwraps, array
  bounds), signals, OOM and watchdog terminations are not captured.
* Web: `error` and `unhandledrejection` events; errors swallowed by app or
  framework error boundaries are not seen unless the app reports them
  (`BugCapsule.reportError`, the React `BugCapsuleErrorBoundary`).

## 6. Network matching

Exactly capsule-v1 *Network matching*, in every runtime, checked by
`fixtures/conformance/request-keys.json`:

1. Redact the URL (`redactUrl`) and decode + redact the body (JSON, form
   fields, text; binary bodies are not hashed; multipart is never hashed).
2. `METHOD host path` (host lower-case without port, empty path `/`), then
   `?` and the query parameters minus ignored names, **decoded** (`+` is a
   space), sorted by name in UTF-16 code-unit order, values in their
   original order, joined `name=value` with `&`.
3. Body (only when complete and ≤ 64 KiB): JSON text is parsed; apply the
   endpoint rule's `matchBodyFields` then `ignoreBodyFields` (plain name =
   any depth, dotted = that path); hash the canonical JSON (keys sorted by
   UTF-16 code units, no whitespace, strings escaped as JSON with only `"`
   `\` and control characters escaped) with the two FNV-1a passes; append
   `#<16 hex>`.
4. Keys longer than 8,000 characters keep their first 7,980 characters plus
   `~<hash of the whole key>`.

Numbers: integers print as integers; decimals print in shortest
round-trip form. Runtimes whose JSON parser turns `1.0` into `1` hash such
a body differently from Dart; capture and replay always run in the same
runtime, so matching is unaffected. Fixtures avoid that case.

`occurrence` is the 0-based count of earlier requests with the same key,
assigned when the request starts. Replay serves fixtures in occurrence
order; a request beyond the recorded count gets the last fixture again and
`network.reused`. An unrecorded request fails with the runtime's
connection error and `network.unrecorded` (strict, the default);
`--lenient-network` sends it to the real network but still reports it.
The web runner also blocks every browser request that bypasses the SDK's
hooks to a non-app origin and reports `network.escaped`.

## 7. Checkpoints and restoration

Each `checkpoint.data` key belongs to one integration:

| Key | Runtime | Shape |
|---|---|---|
| `shared_preferences` | flutter | `{key: {type, value}}` |
| `shared_preferences` | android | `{file: {key: {type, value}}}`, types `bool`, `int`, `long`, `float`, `string`, `stringSet` |
| `datastore` | android | `{name: {key: {type, value}}}` (Preferences DataStore) |
| `user_defaults` | ios | `{key: {type, value}}`, types `bool`, `int`, `double`, `string`, `stringArray`, `data` (base64), `date` (epoch ms) |
| `local_storage`, `session_storage` | web | `{key: string}` |
| `indexeddb` | web | `{adapterName: <adapter JSON>}` from app-registered adapters |
| `state` | android, ios, web | `{key: <serializer JSON>}` from registered state serializers |
| `navigation` / `history` | android, ios / web | `{route, backStack?}` / `{location}` |
| `go_router`, `bloc`, `riverpod`, `notifier`, `getx`, `mobx` | flutter | as capsule-v1 |

Only allowlisted storage keys are captured; values pass through redaction
like events. Restoration happens **before the app reads the store**:

* Android: the replay runner restores in `Instrumentation.onCreate`, before
  `Application.onCreate`; state restorers run when they register.
* iOS: in `BugCapsule.start()` (first line of `application(_:didFinishLaunching…)`
  / `App.init`), before app code reads `UserDefaults`.
* Web: in `await BugCapsule.init()` before the app renders; storage
  restore also runs in the runner's init script before any page script.

Divergences: `restore.<integration>` (restorer threw), `restore.missing`
(captured data with no integration to restore it), `restore.late` (a
registered restorer registered after the replay's first input, or a store
was read before restoration finished), `restore.missingIntegration`, and
`storage.redacted` / `state.redacted` when a placeholder had to be
restored. All are material.

## 8. Redaction

capsule-v1 *Redaction* applies unchanged, checked by
`fixtures/conformance/redaction.json` (keys, headers, free text, URLs,
JSON, tracked text). Runtime notes:

* Regex word boundaries are ASCII (`[A-Za-z0-9_]`) in every runtime. Kotlin
  and Swift spell them as lookarounds because their `\b` is Unicode-aware.
* Web never records password inputs, cookies, or storage outside the
  allowlist; `data-bugcapsule-sensitive` marks any element sensitive.
* Android `trackText(..., sensitive = true)` is required for fields with
  `inputType` password variations (the SDK also forces it for them).
* iOS `UITextField.isSecureTextEntry` fields are always redacted.

## 9. Eligibility and divergences

Eligibility as capsule-v1. New `missing` dependencies:
`capability.<key>` (a capability the capsule needs is `unsupported` in the
capturing SDK, e.g. iOS pointer-only flows), `crash.persisted` (written by
the crash handler: events after the crash point are absent).

Divergence catalogue (types not marked expected are **material**: an
attempt with one cannot count as clean):

| Type | Expected? | Emitted by |
|---|---|---|
| `build.gitSha` | expected | all |
| `screen.size` | expected | flutter, android |
| `network.unused` | expected | all |
| `network.unrecorded`, `network.reused`, `network.noBody`, `network.escaped` | material | all / web (escaped) |
| `action.unregistered`, `text.untracked`, `text.redacted` | material | all |
| `pointer.mismatch`, `selector.ambiguous`, `selector.missing` | material | web |
| `pointer.unsupported` | material | ios (pointer-only capsules) |
| `lifecycle.unsupported` | material | any runtime that cannot drive a recorded state |
| `restore.*`, `storage.redacted`, `state.redacted`, `route.redacted`, `bloc.unrestored`, `riverpod.unrestored`, `notifier.unrestored`, `getx.unrestored`, `mobx.unrestored` | material | all / flutter (state managers) |
| `integration.missing` | material | all |
| `capability.unsupported` | material | all |
| `dispatch.error`, `failure.other` | material | all |
| `runtime.mismatch` | material (reported with outcome `incompatible`) | CLI |

## 10. Replay protocol (v1.1)

The CLI starts a loopback HTTP server (`127.0.0.1`, random port; `--lan`
binds all interfaces for physical devices) and gives the app a per-attempt
base URL:

```
BUGCAPSULE_REPLAY_URL = http://127.0.0.1:<port>/a/<token>
GET  <base>/settings   → ReplaySettings JSON
GET  <base>/capsule    → .bugcapsule bytes
POST <base>/result     → ReplayReport JSON  (204; 409 wrong attemptId; 410 attempt closed)
```

* `token`: 32 random bytes (base64url), new for every attempt. Requests for
  another token get 404; the server answers only while the attempt is armed
  and rejects a report after the attempt closed (timeout, cancel, a report
  already accepted) with 410, so a late report from a killed attempt can
  never count for the next one.
* `ReplaySettings` gains `attemptId` (UUID) and `runtime`. New SDKs echo
  `attemptId` (and `runtime`) in the report; a mismatch is rejected (409).
  Flutter 0.2 apps, which do not echo it, are bound by the token alone.
* Requests carrying an `Origin` header are refused (403): no web page can
  talk to the server. The web runner talks to it from Node and to the page
  through Playwright bindings.
* Fallback channel: a line `BUGCAPSULE_RESULT::{json}` on the app's stdout
  (Flutter), in the instrumentation status (`am instrument -r`, key
  `bugcapsule_result`) on Android, and in the XCUITest output on iOS. It is
  only accepted from the process launched for the armed attempt.

Per runtime transport of the base URL and **production protection**:

| Runtime | How the app gets the URL | Why a production build cannot be driven |
|---|---|---|
| flutter | dart-define / env / sandbox request file | ignored when `kReleaseMode` |
| android | instrumentation argument `bugcapsuleReplayUrl` read by `BugCapsuleReplayRunner` | replay arms only from the runner class, which ships in the `androidTest` artifact; also refused unless `FLAG_DEBUGGABLE` |
| ios | `XCUIApplication.launchEnvironment["BUGCAPSULE_REPLAY_URL"]` | read only in `DEBUG` builds (`#if DEBUG`) and only when `XCTestConfigurationFilePath` / the replay launch argument from the UI test is present |
| web | Playwright init script + bindings (`__bugcapsuleReplay`) | only when the app passes `allowReplay: true` (wire it to a dev/test build flag); never from URL, storage or messages |

Attempt isolation: Android `pm clear` before each attempt, iOS uninstall /
fresh install of the test host app's data container, web a fresh browser
context per attempt. The CLI enforces a per-attempt timeout, kills the
attempt's processes on timeout or Ctrl-C, removes `adb reverse` rules, and
treats every missing report as an `error` attempt.

## 11. Verdicts

Unchanged (`bug_capsule_core/lib/src/verdict.dart`); the CLI computes them
for every runtime. `fixtures/conformance/verdicts.json` pins attempt
classification and batch verdicts, including that unknown divergence types
are material and that missing attempts count against the request.

## 12. Cross-runtime replay

Not implemented. A capsule replays only in the runtime that captured it
(`runtime` or the inferred runtime must equal the project's runtime); the
CLI otherwise reports `INCOMPATIBLE` with `runtime.mismatch` without
launching anything. Semantic actions and network fixtures are portable in
principle, but no runtime pair has been verified.

## 13. Conformance fixtures

Generated from the Dart reference by
`packages/bug_capsule_core/tool/generate_conformance.dart`
(`--check` fails when stale; `conformance_test.dart` does the same in CI):

| File | What every implementation asserts |
|---|---|
| `fixtures/capsule-v1/valid/*.json` | decodes, and re-encodes to a valid document |
| `fixtures/capsule-v1/invalid/*.json` | rejected with an error naming `errorPath` |
| `fixtures/conformance/request-keys.json` | `expectedKey` for each request |
| `fixtures/conformance/signatures.json` | failure signature normalization |
| `fixtures/conformance/redaction.json` | key/header classification, text scrubbing, URL, header, JSON and text redaction |
| `fixtures/conformance/verdicts.json` | attempt status and batch verdict (CLI) |

The SDK repositories vendor a copy under `spec-fixtures/` and fail their
tests when it differs from this directory (when it is checked out next to
them). Copy with `tool/sync_spec.sh` from this repository.
