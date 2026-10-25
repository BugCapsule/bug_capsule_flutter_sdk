# bug_capsule

BugCapsule for Flutter. It records what led up to a bug as a portable
`.bugcapsule` file you can replay on a simulator against your real app code,
verify a fix against, and keep as a regression test. It also reports errors,
release health, performance traces and user feedback.

One package holds the runtime, every integration (BLoC, Riverpod, Provider,
GetX, MobX, Dio, `package:http`, GoRouter, SharedPreferences) and the
`bugcapsule` CLI.

## Install

```bash
flutter pub add bug_capsule
```

## Connect

Generate an SDK token in the BugCapsule dashboard (**Project settings → Keys →
SDK tokens**) and make `BugCapsule.init` the first line of `main`:

```dart
import 'package:bug_capsule/bug_capsule.dart';

void main() => BugCapsule.init(
      config: const BugCapsuleConfig(token: 'bcsdk.v1.…'),
      appRunner: () => runApp(const MyApp()),
    );
```

> SDK tokens arrive in the release after `0.4.1-beta.1`. On `0.4.1-beta.1`,
> pass `backend: BugCapsuleBackendConfig(url: 'https://api.bugcapsule.com', ingestKey: 'bci_…')`
> instead of `token`.

The token holds your BugCapsule address and a send-only credential, so it is
safe to ship in the app. A token that can't be used, no network or a server
error never stops the app. `BugCapsule.status` tells you whether the SDK is
connected, why not, and which replay steps are still missing:

1. **Network**: `BugCapsuleDio` or `BugCapsuleHttp`, so replay serves the recorded responses.
2. **Navigation**: `BugCapsuleGoRouter`, so replay restores the route.
3. **App state**: `BugCapsuleBloc`, `BugCapsuleRiverpod`, `BugCapsuleNotifiers`,
   `BugCapsuleGetx`, `BugCapsuleMobx` or `BugCapsuleSharedPreferences`.

## Replay with the CLI

```bash
dart pub global activate bug_capsule
bugcapsule login --url https://api.bugcapsule.com --token bcp_…
bugcapsule run <id>       # REPRODUCED
bugcapsule verify <id>    # after your fix: FIXED
```

The same CLI replays capsules from the BugCapsule Android, iOS and web SDKs.

## Documentation

- [Flutter SDK guide](https://docs.bugcapsule.com/flutter.html)
- [Quickstart: capture to verified fix](https://docs.bugcapsule.com/quickstart.html)
- [CLI reference](https://docs.bugcapsule.com/cli.html)
- [Full README on GitHub](https://github.com/BugCapsule/bug_capsule_flutter_sdk#readme)

Proprietary software of Bug Capsule; see LICENSE. Questions:
[contact@bugcapsule.com](mailto:contact@bugcapsule.com).
