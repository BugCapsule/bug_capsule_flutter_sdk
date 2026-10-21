# bugcapsule CLI: runtimes, project configuration and replay safety

Since CLI 0.3 the same commands replay capsules from every BugCapsule SDK:

| Runtime | SDK | How an attempt runs |
|---|---|---|
| `flutter` | [bug_capsule_flutter](../README.md) | `flutter build ios --simulator` + `simctl launch`, or `flutter run` per attempt (unchanged) |
| `android` | [bugcapsule-android](../../bug_capsule_android_sdk/README.md) | Gradle builds the app and its androidTest APK once; per attempt `pm clear` + `am instrument` with `BugCapsuleReplayRunner` on an emulator |
| `ios` | [bugcapsule-ios](../../bug_capsule_ios_sdk/README.md) | `xcodebuild build-for-testing` once; per attempt uninstall + `xcodebuild test-without-building` of the app's XCUITest replay test on a simulator |
| `web` | [@bugcapsule/web](../../bug_capsule_web_sdk/README.md) | the project's build/serve commands once; per attempt the Playwright runner opens a fresh Chromium context |

The workflow is unchanged: `bugcapsule inspect`, `run`, `verify`,
`regress add`, `regress run`, plus `login`, `list`, `pull`, `push`, `share`
and `capture`. Verdicts, exit codes and the result recorded on the backend are
computed by the same rules for every runtime
(`bug_capsule_core/lib/src/verdict.dart`).

## Which runtime

1. `--runtime flutter|android|ios|web`, else
2. `"runtime"` in `bugcapsule.json` at the project root (`-p`, default `.`), else
3. detection: `pubspec.yaml` → flutter, `settings.gradle(.kts)` → android,
   `*.xcodeproj`/`*.xcworkspace` → ios, `package.json` → web.

A capsule replays only in the runtime that captured it (`manifest.runtime`,
or `flutter` for capsules written before the field existed). Otherwise the
CLI reports **INCOMPATIBLE** (`runtime.mismatch`, exit 3) without building or
launching anything. Cross-runtime replay is not implemented.

## `bugcapsule.json`

```json
{
  "runtime": "android",
  "android": { "applicationId": "com.example.shop" },
  "timeouts": { "buildSeconds": 1200, "attemptSeconds": 120 }
}
```

| Key | Meaning |
|---|---|
| `runtime` | `flutter`, `android`, `ios` or `web` |
| `timeouts.buildSeconds` | budget for install/build steps (default 1200) |
| `timeouts.attemptSeconds` | budget per attempt (default: recorded duration + settle + 45 s); `--attempt-timeout` overrides |
| `flutter` | none needed: `-t`, `--flavor`, `--dart-define` as before |
| `android` | `applicationId` (required), `gradleDir`, `module` (default `app`), `moduleDir`, `variant` (default `debug`), `testApplicationId` (default `<applicationId>.test`), `runner`, `testClass`, `avd` (booted headless when no device is running), `gradleArgs` (list), `emulatorArgs` (list), `sdkDir`, `bootTimeoutSeconds` (default 300); env `BUGCAPSULE_ANDROID_GRADLE_ARGS` appends Gradle arguments for one run |
| `ios` | `project` or `workspace`, `scheme`, `replayTest` (`Target/Class/method`), `bundleId`, `configuration` (default `Debug`), `simulator`, `buildSettings` (map); env `BUGCAPSULE_IOS_BUILD_SETTINGS` (`K=V K2=V2`) adds build settings for one run |
| `web` | `url` (default `http://127.0.0.1:4317/`), `installCommand` + `installDir` (run when `node_modules` is missing, e.g. in a pinned worktree), `buildCommand`, `serveCommand`, `readyTimeoutSeconds` (60), `allowOrigins` (list of origins the page may load besides the app's), `runner` (command; default: the `@bugcapsule/web-replay` bin in `node_modules`), `headed`, `env` (map passed to every command), `browser` (only `chromium`) |

## Which code is replayed

* `run` builds the capsule's commit (`manifest.source.gitSha`) in a temporary
  git worktree when the project is a git checkout and the commit exists
  (`--no-pin` replays the working tree). Web projects reinstall dependencies
  there with `installCommand`.
* `verify` and `regress run` build the working tree.
* The build gets the commit it is made from (Flutter
  `--dart-define=BUGCAPSULE_GIT_SHA`, Android `-PbugcapsuleGitSha`, iOS
  build setting `BUGCAPSULE_GIT_SHA`, web env `BUGCAPSULE_GIT_SHA`), so the
  app reports it; a commit other than the capsule's is the expected
  `build.gitSha` divergence.
* Prebuilt artifacts skip the build and pinning: `--apk` + `--test-apk`
  (android), `--xctestrun` (ios), `--app-url` (web, an already running app).
  The app still reports its own commit when it embedded one.

## Replay protocol and safety (protocol v1.1)

* The replay server binds **127.0.0.1** on a random port (`--lan` binds the
  LAN for physical devices). Android emulators reach it through
  `adb reverse` (removed on exit); simulators and browsers use loopback.
* Each attempt gets a new random **token** in its base URL
  (`http://127.0.0.1:<port>/a/<token>`) and a new **attemptId**. Only the
  armed attempt is answered; other tokens get 404.
* A report is accepted once. Reports for a closed attempt (timed out,
  cancelled, already reported) get **410**, reports carrying another
  `attemptId` get **409**: a late report from a killed attempt can never
  count for the next one.
* Requests with an `Origin` header are refused (403): no web page can talk to
  the replay server. The web runner relays from Node through Playwright
  bindings.
* The stdout / instrumentation-status / test-log fallback channel
  (`BUGCAPSULE_RESULT::`) is accepted only from the process launched for the
  armed attempt.
* Every attempt has a timeout; on timeout or Ctrl-C the CLI kills the
  attempt's processes (xcodebuild, am instrument, the browser, servers it
  started), removes `adb reverse` rules, frees the web port it served, and
  exits 130 on interruption. An attempt that produced no report, crashed or
  timed out is an `error` attempt: never evidence of a fix.
* Attempt isolation: Android `pm clear`, iOS uninstall (fresh data
  container), web a fresh browser context; Flutter relaunches the app.
* Replay hooks are not activatable in production builds: Flutter release
  builds ignore replay requests; Android arms replay only from the
  instrumentation runner in the androidTest APK and only in debuggable
  builds; iOS only in `DEBUG` builds launched by the UI test; web only when
  the app passes `allowReplay: true` and the page was opened by the runner.

## Verdicts

Unchanged and identical for every runtime: REPRODUCED, NOT REPRODUCED,
FIXED, STILL FAILING, FLAKY, INCONCLUSIVE, INCOMPATIBLE. A clean attempt
needs every recorded input dispatched, required restoration done, no other
failure and no material divergence; FIXED needs every requested attempt to be
valid and clean. The shared fixture `spec/fixtures/conformance/verdicts.json`
pins the rules.
