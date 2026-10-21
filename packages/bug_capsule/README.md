# bug_capsule

BugCapsule for Flutter: records the context around a failure into a portable `.bugcapsule` capsule and replays it locally.

One package holds the runtime, every integration (BLoC, Riverpod, Provider, GetX, MobX, Dio, `package:http`, GoRouter, SharedPreferences) and the `bugcapsule` CLI:

```dart
import 'package:bug_capsule/bug_capsule.dart';
```

Part of the [BugCapsule Flutter SDK](https://github.com/draz26648/bug_capsule_flutter_sdk). See the root README for setup and usage, and [docs/cli-runtimes.md](../../docs/cli-runtimes.md) for replaying capsules from the native Android, native iOS and web SDKs.
