# BugCapsule feature matrix (October 2026, SDK 0.3 / Flutter package 0.4)

Legend: **T** implemented and tested (automated tests and/or the recorded
end-to-end run) · **I** implemented, not tested here · **P** partial (works
with a documented limitation) · **—** not implemented / planned.

E2E column sources: Android, iOS and web runs were recorded on 2026-10-21
against the local backend (see each SDK's README / evidence file; Android and
iOS main capsules were also re-run independently through the CLI). Flutter
E2E figures are the ones measured earlier in the Flutter README; the Flutter
unit suites (257 tests) were re-run this session, its device E2E was not.

## Capture

| Feature | Flutter | Android | iOS | Web |
|---|---|---|---|---|
| Bounded flight recorder (20k events / 5 min, launch + periodic checkpoints) | T | T | T | T |
| Manual capture (`capture`) | T | T | T | T |
| Automatic capture: uncaught errors | T (zone, FlutterError, PlatformDispatcher) | T (JVM uncaught, chained handler) | P (NSException via chained handler; Swift traps/signals not captured) | T (`error`, `unhandledrejection`) |
| Crash capsule persisted, uploaded next launch | n/a (Dart errors do not end the process) | T | T | n/a (errors do not end the page) |
| Assertions `check` / `fail`, `reportError` | T | T | T | T |
| Pointer capture | T | T (Window.Callback, dp) | T (explicit `BugCapsuleWindow` / `recordTouches`) | T (Pointer Events, target descriptor) |
| Semantic actions | T | T (Views + Compose) | T (UIKit + SwiftUI) | T (core + React) |
| Tracked text, sensitive fields | T | T (password input types forced) | T (`isSecureTextEntry` forced) | T (password inputs, `data-bugcapsule-sensitive`) |
| Key events | — | T (Back, `key` event) | — | — (tracked inputs only) |
| Navigation | T (GoRouter) | T (Jetpack Navigation) | T (UINavigationController proxy, explicit, SwiftUI) | T (History API; React Router listener) |
| Lifecycle | T | T | T | T (visibility, pagehide/pageshow) |
| State | T (BLoC, Riverpod, Provider, GetX, MobX) | T (registered serializers, ViewModels) | T (registered state objects) | T (registered serializers, React hook) |
| Storage checkpoints (allowlisted) | T (SharedPreferences) | T (SharedPreferences, Preferences DataStore) | T (UserDefaults) | T (localStorage, sessionStorage); I (IndexedDB adapters: unit-level only) |
| HTTP capture | T (Dio, package:http) | T (OkHttp; Retrofit through it) | T (URLSession via URLProtocol); I (Alamofire through an instrumented configuration, documented, not tested) | T (fetch, XMLHttpRequest) |
| Bounded body capture, streams untouched | T | T | T | T (`clone()` read up to the limit) |
| In-flight requests at capture (`http.pending`) | — | T | T | — |
| Redaction before persistence (shared conformance fixtures) | T | T | T | T |
| Remote config, kill switch, sampling | T | T | T | T |
| Rejected ingest key (401/403 on config) | stops capture, purges queue | stops capture, **keeps** queue | stops capture | stops capture, purges queue |
| Offline outbox (10 / 10 MiB / 7 days, backoff, Retry-After) | T | T | T | T (IndexedDB, cross-tab safe) |
| Runtime + capability metadata in capsules | T | T | T | T |

## Replay

| Feature | Flutter | Android | iOS | Web |
|---|---|---|---|---|
| Runs the real app code | T | T (instrumentation, in-process engine) | T (XCUITest launches the app, in-app engine) | T (Playwright, in-page engine) |
| Pointer replay | T | T (`sendPointerSync`) | — (`input.pointer.replay: unsupported`, material `pointer.unsupported`) | T (trusted Playwright input; mismatch/ambiguity reported) |
| Semantic action replay | T | T | T | T |
| Tracked text replay | T | T | T | T |
| Lifecycle replay | T | T (ActivityScenario states) | P (posted notifications) | P (synthetic visibility events) |
| Checkpoint restoration before app code | T | T (runner `onCreate`, before `Application.onCreate`) | T (in `BugCapsule.start()`) | T (init script + `init()`) |
| Late / failed restoration reported | T | T | T | T |
| Deterministic network replay (key + occurrence, latency, errors, cancel) | T | T | T | T (fetch + XHR) |
| Strict network (unrecorded never reaches real services) | T | T | T | T (+ runner blocks escaped requests) |
| Idle compression | T | T | T | T |
| Clock / random hooks (explicit only) | T | T | T | T |
| Production replay protection | T (release builds) | T (androidTest runner + debuggable) | T (`#if DEBUG` + launch argument) | T (`allowReplay` + runner bindings) |
| Attempt isolation | relaunch | `pm clear` | uninstall | fresh browser context |
| Physical devices | P (iOS needs `--lan`) | I (adb device path, not tested) | — (simulator only; signing/devicectl planned) | n/a |
| Browsers | n/a | n/a | n/a | T Chromium; I capture in Firefox/Safari (untested); — replay elsewhere |
| Cross-runtime replay | — | — | — | — (CLI reports INCOMPATIBLE) |

## CLI and backend

| Feature | Flutter | Android | iOS | Web |
|---|---|---|---|---|
| `inspect` / `run` / `verify` / `regress add` / `regress run` | T | T | T | T |
| Source-revision replay (git worktree pin) | T | I (generic; E2E used a scratch git copy) | I (generic; not exercised) | T (scratch git copy: pinned REPRODUCED, working tree FIXED) |
| Prebuilt artifacts | — | I (`--apk`, `--test-apk`) | I (`--xctestrun`) | T (`--app-url`) |
| Per-attempt token, attemptId, stale-report rejection, Origin refusal | T | T | T | T |
| Timeouts, Ctrl-C cleanup | T | T | T | T |
| Backend upload, runs, triage, sharing | T | T | T | T (CORS) |
| Backend runtime index / filter | T | T | T | T |

## Recorded end-to-end results (this session)

| Step | Android (Pixel_6_2, API 35) | iOS (iPhone 18 Pro sim, iOS 27) | Web (Chromium 153) |
|---|---|---|---|
| Capture + upload | race crash, null price, legacy cart, coupon | coupon assertion, race NSException, legacy cart | race, legacy cart, discontinued item, coupon |
| `run` | REPRODUCED 3/3 (independent re-run 2/2) | REPRODUCED 3/3 | REPRODUCED 3/3 |
| `verify` without fix | STILL FAILING 3/3 | STILL FAILING 3/3 | STILL FAILING 3/3 |
| `verify` with isolated fix | FIXED 3/3 (independent re-run 2/2) | FIXED 3/3 | FIXED 3/3 |
| Restoration control (checkpoint removed) | — | NOT REPRODUCED 0/1 | NOT REPRODUCED 0/2 |
| `regress run` | fail without fix, pass with fix | fail without fix, pass with fix | fail without fix, pass with fix |
| Offline capture → restart → upload | T (airplane mode) | T (unreachable backend) | T (blocked uploads, reload) |

Known verdict behaviour shared by all runtimes: a fix that makes the app send
requests the recording never saw yields INCONCLUSIVE, never FIXED (strict
network); observed for the web discontinued-item fix and the Android
null-price/legacy fixes.
