# BugCapsule example

`main.dart` shows SDK initialization, navigation monitoring, and manual capsule
capture. Without an SDK token, capsules stay on the device.

To run it in a new Flutter app:

```sh
flutter create bug_capsule_example
cd bug_capsule_example
flutter pub add bug_capsule
```

Replace `lib/main.dart` with this example's `main.dart`, then run:

```sh
flutter run --dart-define=BUGCAPSULE_TOKEN=YOUR_SDK_TOKEN
```

Get the SDK token from **Project settings → Keys → SDK tokens** in the
BugCapsule dashboard. Omit the dart-define to try local capture.

For a complete demo with network, state, and replay integrations, see the
[repository demo app](https://github.com/BugCapsule/bug_capsule_flutter_sdk/tree/main/example/bug_capsule_demo).
