# bugcapsule CLI: runtimes, project configuration and replay safety

Since CLI 0.3 the same commands replay capsules from every BugCapsule SDK:

| Runtime | SDK | How an attempt runs |
|---|---|---|
| `flutter` | [bug_capsule](../README.md) | `flutter build ios --simulator` + `simctl launch`, or `flutter run` per attempt (unchanged) |
| `android` | [bugcapsule-android](https://github.com/BugCapsule/bug_capsule_android_sdk#readme) | Gradle builds the app and its androidTest APK once; per attempt `pm clear` + `am instrument` with `BugCapsuleReplayRunner` on an emulator |
| `ios` | [bugcapsule-ios](https://github.com/BugCapsule/bug_capsule_ios_sdk#readme) | `xcodebuild build-for-testing` once; per attempt uninstall + `xcodebuild test-without-building` of the app's XCUITest replay test on a simulator |
| `web` | [@bugcapsule/web](https://github.com/BugCapsule/bug_capsule_web_sdk#readme) | the project's build/serve commands once; per attempt the Playwright runner opens a fresh Chromium context |

The workflow is unchanged: `bugcapsule inspect`, `run`, `verify`,
`regress add`, `regress run`, plus `login`, `list`, `pull`, `push`, `share`
and `capture`. Verdicts, exit codes and the result recorded on the backend are
computed by the same rules for every runtime
(`packages/bug_capsule/lib/src/core/verdict.dart`).

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
| `ios` | `project` or `workspace`, `scheme`, `replayTest` (`Target/Class/method`; default `<uiTestTarget>/BugCapsuleReplayTests/testReplay`), `uiTestTarget`, `bundleId`, `configuration` (default `Debug`; it must define `DEBUG`, or the app ignores replay), `simulator`, `derivedDataPath`, `startupSeconds` (time for xcodebuild to start the test, default 120, added to each attempt's budget), `buildSettings` (map); env `BUGCAPSULE_IOS_BUILD_SETTINGS` (`K=V K2=V2`) adds build settings for one run |
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

## App deaths and crash capsules

A capsule whose failure is a crash (failure kind `crash`, built on the next
launch from the crash journal of the process that died) replays the steps
and checks for the same crash. Every launcher maps an app process death
during an attempt to the attempt's result:

| What happens in the app under test | Attempt |
|---|---|
| Dies with the same type (signal, Mach exception, ANR, out-of-memory kill) | `reproduced`; another in-app frame adds reason code `failure.different_frame` |
| Dies with another type | invalid, reason code `failure.different` (the run is `INCONCLUSIVE`) |
| Replays the window to the end and stays alive | the runner's own `not_reproduced` |
| Dies and the cause can't be told | `error` |

A death while replaying a capsule of a Dart exception is another failure:
the attempt proves nothing. How each runtime sees the death:

* **Flutter**: the app process exit (`flutter run` losing the app, with the
  `Fatal signal` lines of the device log; on the simulator, the app's crash
  report in `~/Library/Logs/DiagnosticReports`).
* **Android**: `am instrument` reporting `Process crashed`, then the exit
  record the attempt added (`dumpsys activity exit-info`, Android 11+) and the
  crash log buffer (`logcat -b crash`); a runner that outlives the app can
  report `bugcapsule_crash=<json>` as an instrumentation status.
* **iOS**: the XCTest output and the simulator's crash report of the app.
* Any runner can put a `crash` object (`type`, `mechanism`, `signal`,
  `inAppFrame`, `source`) in its result.

## Releases on runs

`run` and `verify` record each run with the release of the build under test,
`<appId>@<version>+<build>`, the form SDKs send in events: the pubspec
`version` and the Android application id or iOS bundle id (flutter), the
installed APK's `versionName` / `versionCode` (android), the built app's
`CFBundleShortVersionString` / `CFBundleVersion` (ios), `package.json`
(web). `--release` and `--environment` override or add to it. A capsule
fixed by a `verify` run remembers the release that fixed it.

## Release gate

`bugcapsule gate` verifies, in CI, that a build does not reproduce the bugs
its release claims to fix, nor any bug fixed earlier:

```bash
bugcapsule gate --release com.shop.app@1.5.0+60 --platform android \
  [--scope all|fixes|regressions] [--issue <id>] [--attempts 3] \
  [--fail-on reproduced,flaky] [--junit build/bugcapsule-gate.xml] [--json]
```

1. Fetches the capsules the release must not reproduce: fixes the release
   claims and bugs fixed in it or earlier (`--platform` is the capsules'
   runtime). With none, the gate passes and says so. The plan holds at most
   10 capsules per issue and 200 in all; when it left some out, the gate
   warns and `--json` / JUnit say `truncated`.
2. Builds the app once, as `verify` does (the working tree, or `--apk` /
   `--xctestrun` / `--app-url`), then downloads and verifies each capsule
   with `--attempts`, recording every run with the release and the commit.
3. Posts the gate report to the release, prints a table (capsule, issue,
   reason, outcome), writes JUnit XML (one test case per capsule, named
   `<issue title> (<capsule id>)`) and, with `--json`, prints the result as
   JSON on stdout (progress goes to stderr).

| Exit code | When |
|---|---|
| 0 | Passed |
| 1 | A capsule reproduced; or the backend could not be reached or refused |
| 2 | A capsule was flaky (with `flaky` in `--fail-on`, the default `reproduced,flaky`) |
| 3 | A capsule could not run (inconclusive, incompatible, error), with `error` in `--fail-on` |
| 64 | Usage |

Credentials: a service token (`bcv_…`) from **Project settings → Keys & CLI
access** with the `capsules.read` and `replay.submit` scopes, in
`BUGCAPSULE_TOKEN` (or `--token`), and the backend in
`BUGCAPSULE_URL` (or `--url`) unless you use BugCapsule's hosted backend
after `bugcapsule login`.

### GitHub Actions

```yaml
name: Release gate
on:
  push:
    tags: ['v*']

jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - name: Enable KVM for the emulator
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm
      - run: npm install -g @bugcapsule/cli@0.4.0-beta.3
      - name: Verify the release does not bring fixed bugs back
        uses: reactivecircus/android-emulator-runner@v2
        env:
          BUGCAPSULE_URL: https://api.bugcapsule.com
          BUGCAPSULE_TOKEN: ${{ secrets.BUGCAPSULE_TOKEN }}
        with:
          api-level: 34
          arch: x86_64
          script: >
            bugcapsule gate
            --release com.shop.app@${GITHUB_REF_NAME#v}
            --platform flutter
            --junit build/bugcapsule-gate.xml
      - name: Publish the gate results
        if: always()
        uses: mikepenz/action-junit-report@v4
        with:
          report_paths: build/bugcapsule-gate.xml
```

For iOS, run the job on `macos-latest` with a booted simulator
(`xcrun simctl boot "iPhone 16"`) and `--platform ios` (or `flutter`).

## Verdicts

Unchanged and identical for every runtime: REPRODUCED, NOT REPRODUCED,
FIXED, STILL FAILING, FLAKY, INCONCLUSIVE, INCOMPATIBLE. A clean attempt
needs every recorded input dispatched, required restoration done, no other
failure and no material divergence; FIXED needs every requested attempt to be
valid and clean. The shared fixture `spec/fixtures/conformance/verdicts.json`
pins the rules.
