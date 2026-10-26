# How the Flutter SDK works

Reference details behind the [README](../README.md): production behaviour,
monitoring internals, replay verdicts and the full list of limitations. The
capsule format is in [spec/capsule-v1.md](../spec/capsule-v1.md).

## Production behaviour

1. **Kill switch.** `bugcapsule capture --on` disables capture. BugCapsule
   refuses uploads from that moment. Devices see it at their next
   config refresh: after `configTtlSeconds` (default 5 min), when the app
   returns to the foreground, or before any upload attempt with a config older
   than its TTL. They then stop recording, drop the buffer, delete queued and
   saved captures, and keep the switch across launches even offline. An upload
   already on the wire finishes. Re-enabling applies from the next app launch.
2. **Remote config.** Fetched after startup, then refreshed on its TTL with
   exponential backoff (30 s to 30 min, `Retry-After` honoured) and on
   resume. It is cached per address and credential, so a staging config never
   applies to production. With no cached config (first launch, offline),
   debug/QA builds record and production builds sample at the app's cap, but
   **nothing is uploaded until a config fetch succeeds**; a cached config older
   than `maxStaleConfig` (7 days) also stops uploads. A refused credential (a
   revoked, expired or unknown SDK token, or an inactive ingest key) stops
   capture and uploads for the session; the SDK prints the reason once and
   `BugCapsule.status` reports `rejected`. New body and redaction settings
   apply to the running session, including events already buffered.
3. **Sampling.** A production session records with probability
   `min(productionSampleRate, project sampleRate)`, decided at launch. Lowering
   the remote rate mid-session keeps a recording session with probability
   new/old, so the share of recording sessions follows the new rate; raising it
   applies from the next launch and never above the app's cap (default 0.1).
   Sessions that aren't sampled install no recorders.
4. **Redaction.** Applied on the device to events and checkpoints alike, and
   again to everything integrations record. See the spec's
   [Redaction](../spec/capsule-v1.md#redaction) section for exactly what is
   caught and what is not.
5. **Bodies.** With `captureNetworkBodies` off (also remotely), capsules become
   `partial`. HTTP capture never buffers whole bodies: bytes stream to the app
   unchanged and only a bounded prefix is kept (`maxBodyBytes`, 256 KiB;
   binary 64 KiB). With bodies off nothing is kept; request bodies up to
   64 KiB are still hashed (never stored) so replay can match requests.
6. **Device storage.** At most 20 saved captures and an upload outbox of
   10 capsules / 10 MiB / 7 days (`BugCapsuleConfig.outboxLimits`), oldest
   evicted first; failed uploads back off from 30 s to 1 h. Disk-full and
   corrupt files drop the capsule, never the app.
7. **Isolation.** If storage, an integration's setup or anything else in
   capture setup fails, the app starts without capture. SDK errors are never
   thrown into the app's error handlers or callbacks.
8. **Performance.** Pointer and HTTP capture and redaction run on the UI
   isolate; capsule encoding runs in a background isolate. Measure on a
   low-end Android device ([test plan](release-and-device-test-plan.md)).
9. **Release builds never enter replay mode** (`BUGCAPSULE_REPLAY_URL` and
   replay request files are ignored when `kReleaseMode`).
10. **Monitoring** is on by default and independent of capsule sampling: every
    production session sends sessions and (sampled) error events. Set
    `errorSampleRate` / `tracesSampleRate` and `tracePropagationTargets`
    deliberately, check `beforeSend` output and upload symbols for every
    release build. `monitoringEnabled: false` in the project settings stops
    it without touching capsules.

## Monitoring details

Error events, sessions, transactions and feedback are sent as envelopes with
the same SDK token or ingest key. Every item goes through the capsule
redaction rules on the device before it is queued.

| Signal | How |
|---|---|
| Errors | `FlutterError.onError` (`flutter_error`), `PlatformDispatcher.onError` (`platform_dispatcher`), uncaught errors of the main isolate and zone errors under `BugCapsule.runZonedGuarded` (`uncaught`). Unhandled errors are `fatal` (`crashOnUnhandled`). One error sent through several handlers is sent once; the same error repeating (say, in `build` every frame) is sent at most 10 times a minute. |
| Stack traces | Parsed into frames, oldest call first; `inApp` for your package (detected from the caller of `BugCapsule.init`, or `inAppIncludes`). AOT builds with `--split-debug-info` send `instructionAddr` frames and an `elf` debug image with the build id; `--obfuscate` builds add a `dart_obfuscation` image from `--dart-define=BUGCAPSULE_OBFUSCATION_ID`. Both are symbolicated with the files from `bugcapsule symbols upload`. |
| Breadcrumbs | Derived from the flight recorder's events: routes, actions, HTTP exchanges, lifecycle, logs, errors and state changes (nothing is instrumented twice). |
| Capsules | When a capsule is written for a failure, its event carries `capsuleId` and the capsule carries `manifest.monitoring.eventId`. |
| Sessions | One per foreground run; a new one after 30 s in the background. `crashed` after a fatal event, `abnormal` when the app was killed in the foreground (detected at the next launch). |
| Screens | `navigation` transactions named after the route pattern (`/product/:id`) from `BugCapsuleGoRouter`, or `BugCapsuleNavigatorObserver` for `Navigator` apps, with `time_to_initial_display` and slow / frozen frame counts. |
| App start | An `app.start.cold` transaction from `BugCapsule.init` to the first rasterized frame. |
| HTTP | `http.client` spans for `BugCapsuleDio` and `BugCapsuleHttp` requests under the active span, and `traceparent` / `baggage` headers for `tracePropagationTargets`. The headers are added for the transport only: capsules record your headers, request keys never include headers, and replay adds none. |

More API:

```dart
BugCapsule.setTag('tenant', 'acme');
BugCapsule.captureMessage('payment provider slow', level: EventLevel.warning);
BugCapsule.withScope((scope) { scope.setFingerprint(['checkout-timeout']); BugCapsule.captureException(e); });

await BugCapsule.startSpan('load cart', 'task', (span) async {   // active for its zone
  span.startChild('db', description: 'read cart').finish();
  await dio.get('/cart');                                          // child http.client span
});

BugCapsuleFeedbackForm(onSubmitted: (id) => Navigator.pop(context));
await BugCapsule.captureFeedback(message: 'Checkout did nothing', email: 'ana@example.com');
// Shake to report, with the accelerometer of the sensor plugin you use (e.g. sensors_plus):
BugCapsuleShakeToReport(accelerometer: accelerometerEventStream().map((e) => [e.x, e.y, e.z]), child: child);
```

In QA mode submitting feedback also writes a capsule
(`captureCapsuleWithFeedback`). `getTraceparent()` / `getBaggage()` serve
custom HTTP clients and `continueTrace(traceparent, baggage)` joins an
incoming trace; `flush()`, `close()`, `startSession()` / `endSession()` and
`addIsolateErrorListener(isolate)` cover the rest of the API.

Your project settings can change `monitoringEnabled`, `errorSampleRate`,
`tracesSampleRate`, `sessionTracking`, `maxBreadcrumbs` and
`tracePropagationTargets` remotely; the kill switch stops monitoring too.
Envelopes wait in their own outbox (30 envelopes / 5 MiB / 7 days,
`MonitoringOptions.outboxLimits`) with the capsule outbox's backoff and
`Retry-After` handling, and are sent only once a remote config fetch has
succeeded.

## Crash journal and crash capsules

A crash that ends the process (a native signal or Mach exception, an ANR the
system killed the app for, a low-memory kill) leaves no time to write a
capsule. While a session records, the SDK therefore mirrors the flight
recorder to `<storage>/journal/<pid>/`:

* `header.json`: the capsule manifest fields known while the app runs (app,
  platform, session, integrations, redaction, labels, interaction adapters),
  rewritten when they change;
* `checkpoints/<afterSeq>.json`: the launch checkpoint while the whole
  session is still within the recorder's window, and the newest periodic
  checkpoint;
* `events/<firstSeq>.jsonl`: the recorded (already redacted) events, a new
  file at each checkpoint.

The UI isolate only hands events to a writer isolate, which writes them in
one batch at least every 250 ms, and at once on a checkpoint, a failure and
going to the background. The journal follows the recorder's eviction and
stays under twice `maxCapsuleBytes` (the oldest events file goes first). New
redaction rules from the backend rewrite it; a session that stops recording
deletes it.

On the next launch, `bug_capsule_native` hands over the crashes of earlier
runs. For each one, the SDK picks the journal of the process that crashed
(the journal id the crash's mirrored scope carries; else, when the previous
run crashed, the previous process's journal if the crash falls within its
lifetime) and builds a capsule from it before sending the event: the launch
checkpoint when everything after it is on disk, else the newest periodic
one; failure kind `crash` with the signal or exception type; the
`crash.native` gap; `labels.source = crash_journal`. The event carries the
capsule's id. Journals no crash claims are deleted after the launch's
pending crashes are handled, and any older than 7 days.

## Verdicts in detail

`run` and `verify` judge every attempt, then the batch:

- An attempt **reproduced** when the original failure assertion fired.
- An attempt is **clean** only when it ran to the end as recorded: it has a
  failure assertion to check, every recorded input was dispatched, no other
  failure fired, and nothing *material* diverged. Material: unregistered
  actions, untracked text fields, failed or missing restoration, requests
  without a recorded response, responses replayed without their body, reused
  responses, dispatch errors, values that were redacted on the device and
  replayed as placeholders (a missing token or OTP can send the app down
  another path), and any divergence this version does not know. Expected
  differences do not count: a changed commit (`build.gitSha`), a different
  screen size, and recorded responses the replay never asked for. To verify
  flows behind a login, keep the login state out of the deny list for QA
  builds (for example a test account whose token you allow) or exclude it
  from the failing flow.
- Anything else is **invalid**: errors, incompatible capsules, no assertion.

The verdict is recorded with the number of valid attempts. A capsule moves to
`fixed` only for a verify where every requested attempt was valid.
`bugcapsule regress run` treats `INCONCLUSIVE` as a failure.

On an iOS simulator the CLI builds once, then launches the installed app for
each attempt. It hands over the replay request through a file in the app's
sandbox, because environment variables don't reach the app on recent
simulator runtimes. Other devices use `flutter run` with a dart-define for
each attempt.

## CLI credentials

A personal token (`bcp_…`) acts as you within its scopes, in one project, and
stops working when it expires, is revoked, or you leave the project. In CI
use a service token (`bcv_…`) in `BUGCAPSULE_TOKEN`. `BUGCAPSULE_URL`,
`BUGCAPSULE_TOKEN`, `BUGCAPSULE_SECRET_KEY` and `BUGCAPSULE_INGEST_KEY`
override `~/.bugcapsule/config.json`; a token wins over a secret key. Projects
without people and roles still accept `--secret-key bcs_…`. CLI 0.4.0 has no
`--token` flag: pass the token as `--secret-key` there.

## Limitations

- Replay keeps recorded timing, except that idle gaps between inputs longer
  than 1.5 s shrink to about 0.3 s when the recording and the replayed app are
  both idle (no pending response, no recent BLoC activity, no pressed pointer;
  running animations get up to 2 s to finish). Recorded network latency is
  never shortened. `--no-compress-idle` replays in real time. App `Timer`s are
  not tracked, so a timer whose effect is not recorded (say, a plain
  `setState`) can be skipped over; use `--no-compress-idle` if replay depends
  on one.
- `DateTime.now()`, `Timer`s and animations are not virtualized; only
  `clock.now()` and `BugCapsule.random` are deterministic.
- WebSockets, platform channels and native SDKs are captured only through
  `BugCapsuleWebSocket`, `BugCapsulePlatformChannels` and native adapters
  (capsule spec v2). Not covered: sockets opened with other constructors,
  Socket.IO and other protocols on top of WebSockets, ping/pong frames,
  channels that are not listed, framework channels (`flutter/*`), background
  isolates (`BackgroundIsolateBinaryMessenger`), additional engines, plugins
  with their own messenger, Pigeon and other custom codecs (recorded as
  metadata with a `codec.unsupported` gap), FFI, platform views, textures and
  native work that never crosses a channel. A connection or subscription open
  at a periodic checkpoint cannot be restored: such a capsule is ineligible
  (`interactions.restore`) and replay reports `dependency.unrestorable`.
  EventChannels need the binding BugCapsule creates (Flutter sends their
  `listen` through the default messenger). HTTP is captured
  for Dio and `package:http` clients only (`dart:io` `HttpClient` used
  directly, `cupertino_http` / `cronet_http` without an `http.Client` wrapper,
  and GraphQL subscriptions are not).
- Redux has no integration yet; its state is re-executed by replay but not
  checkpointed or restored.
- Riverpod, `ChangeNotifier`, GetX and MobX state injection from periodic
  checkpoints has the same limits as BLoC: instances are matched by
  initialization order (`cart#0`), and an `AsyncNotifier` whose `build`
  finishes after the restore overwrites the restored state.
- BLoC state injection from periodic checkpoints matches instances by creation
  order (`CartBloc#0`). BLoCs that dispatch events in their constructor can
  overwrite restored state. Launch-checkpoint replay (the default for sessions
  within the 5-minute window) re-executes the session instead and avoids this.
- GetX: `update([ids])` is not seen, only `update()`.
- Pointer replay assumes the same logical screen size; otherwise the CLI
  scales coordinates and falls back to semantic actions when they exist.
- The Android replay path (`flutter run` + `adb reverse`) is implemented but
  has not been exercised end to end yet.
- Redaction is pattern based. It does not recognise personal data that is not
  a credential (names, emails, addresses) or secrets in URL paths; use the
  hooks in the README.
- A request whose server answers before the request body was fully sent is
  keyed without its body hash; replay may then report it as unrecorded.
- Monitoring: app start is measured from `BugCapsule.init` (the first Dart
  code) to the first frame, not from process start, and only cold starts are
  reported. State-management breadcrumbs appear only in sessions that record a
  capsule (route, action, HTTP, lifecycle, log and error breadcrumbs always
  do). Trace headers are added only while a span is active (a screen
  transaction or `startSpan`). `enableUserInteractionTracing` covers
  `BugCapsule.action` callbacks only. Device model and manufacturer are not
  collected from Dart.
- Capsules captured by SDK 0.1 with body capture off were keyed without body
  hashes; replaying them with 0.2 or later reports those requests as
  unrecorded.
