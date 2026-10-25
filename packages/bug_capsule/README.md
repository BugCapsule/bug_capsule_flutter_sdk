# bug_capsule

BugCapsule for Flutter: records the context around a failure into a portable `.bugcapsule` capsule and replays it locally.

One package holds the runtime, every integration (BLoC, Riverpod, Provider, GetX, MobX, Dio, `package:http`, GoRouter, SharedPreferences) and the `bugcapsule` CLI:

```dart
import 'package:bug_capsule/bug_capsule.dart';

void main() => BugCapsule.init(
      config: const BugCapsuleConfig(token: 'bcsdk.v1.…'),   // the SDK token from the dashboard
      appRunner: () => runApp(const MyApp()),
    );
```

The token carries the API address and an upload-only credential, so it is
safe to ship in the app. A token that can't be used, no network or a server
error never stops the app; `BugCapsule.status` tells whether the SDK is
connected, why not, and which replay steps are still missing:

1. **Network** — `BugCapsuleDio` or `BugCapsuleHttp`, so replay serves the recorded responses.
2. **Navigation** — `BugCapsuleGoRouter`, so replay restores the route.
3. **App state** — `BugCapsuleBloc`, `BugCapsuleRiverpod`, `BugCapsuleNotifiers`, `BugCapsuleGetx`, `BugCapsuleMobx` or `BugCapsuleSharedPreferences`.

Self-hosted and advanced setups can still pass the backend explicitly,
`backend: BugCapsuleBackendConfig(url: ..., ingestKey: 'bci_...')`, which wins
over a token.

Part of the [BugCapsule Flutter SDK](https://github.com/draz26648/bug_capsule_flutter_sdk). See the root README for setup and usage, and [docs/cli-runtimes.md](../../docs/cli-runtimes.md) for replaying capsules from the native Android, native iOS and web SDKs.
