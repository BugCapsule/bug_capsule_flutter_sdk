# BugCapsule for Shorebird

A hotfix adapter for [BugCapsule](https://docs.bugcapsule.com/flutter.html)
emergency recovery, built on Shorebird's official
[`shorebird_code_push`](https://pub.dev/packages/shorebird_code_push) package.
It tells your app, and the BugCapsule backend, which Shorebird patch a release
runs, and downloads an available patch when your app asks. A downloaded patch
becomes active the next time the app starts.

The BugCapsule backend uses the reports to check that a recovery can reach the
installed builds, and to follow it once it ships.

## Before you use it

- **Only builds made with `shorebird release` can be patched.** Any other
  build (`flutter build`, `flutter run`, debug builds, web, desktop) reports
  `available: false`. Such a build can only be fixed by a store release.
- **Dart code only.** Shorebird patches the Dart code of a release. Changes to
  native code, plugins or assets need a store release.
- **No automatic restart.** The adapter never restarts or terminates the app.
  After a download it reports `restart_required`; when the patch becomes
  active is your app's decision (for example on the next cold start, or after
  asking the user).
- Shorebird itself may already check and download patches when the app starts
  (`auto_update` in `shorebird.yaml`). `getStatus()` shows a patch downloaded
  that way as `restart_required`.

## Install

```yaml
dependencies:
  bug_capsule: ^0.4.1-beta.7
  bug_capsule_shorebird: ^0.1.0-dev.1
```

```dart
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_shorebird/bug_capsule_shorebird.dart';

await BugCapsule.emergency.initialize(EmergencyConfig(
  trustAnchor: 'bcek.v1.…',
  hotfixProvider: BugCapsuleShorebird(),
));
```

`BugCapsuleShorebird(track: UpdateTrack.beta)` checks another Shorebird track
(`stable` by default). `releaseVersion:` names the Shorebird release this build
is (`version+build` from `pubspec.yaml`); without it, reports use the app
version BugCapsule was configured with (`EmergencyConfig.appVersion` or
`BugCapsuleConfig.appVersion`).

## Use

```dart
final hotfix = BugCapsule.emergency.hotfix!;

final availability = await hotfix.checkAvailability();
if (availability.patchAvailable) {
  final result = await hotfix.downloadAvailablePatch();
  switch (result) {
    case HotfixRestartRequired():
      showRestartPrompt(); // Patch result.nextPatch is active after a restart.
    case HotfixNothingToDownload() || HotfixDownloadInProgress():
      break;
    case HotfixDownloadFailed(:final reason):
      log('patch download failed: $reason');
    case HotfixUnavailable():
      break; // Not a `shorebird release` build.
  }
}

final status = await hotfix.getStatus();
// status.currentPatch: the patch running now (null on the base release).
// status.nextPatch: the downloaded patch waiting for the next start.
```

| Operation | Shorebird calls |
|---|---|
| `checkAvailability()` | `checkForUpdate`, `readCurrentPatch`, `readNextPatch` |
| `downloadAvailablePatch()` | `checkForUpdate`, then `update` when a patch is available |
| `getStatus()` | `readCurrentPatch`, `readNextPatch`; `checkForUpdate` only before the first check of the process |

States: `up_to_date`, `outdated`, `downloading`, `restart_required`,
`unavailable`, `failed`. A downloaded patch is always reported as `nextPatch`,
never as `currentPatch`, until the app starts again. Failures
(`UpdateException`, `ReadPatchException`, anything else) come back as a
`failed` status or a `HotfixDownloadFailed` result (`download_failed`,
`install_failed`, `check_failed`, `unknown`, `error`); nothing is thrown.

The calls make network requests to Shorebird and can take a while. Don't make
app startup wait for them.

## Tested versions

| Package | Version |
|---|---|
| `shorebird_code_push` | 2.0.7 |

Tested with Flutter 3.47.8 against a scripted updater, and against the real
`shorebird_code_push` in a build without the Shorebird engine. Not yet tested
in a `shorebird release` build on a device.

## License

MIT. See [LICENSE](LICENSE).
