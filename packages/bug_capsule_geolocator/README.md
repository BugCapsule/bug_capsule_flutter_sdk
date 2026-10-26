# BugCapsule for geolocator

A native SDK adapter for [BugCapsule](https://docs.bugcapsule.com/flutter.html)
that records location results at the `geolocator_platform_interface`
boundary. While capturing, permission checks, service state and position fixes
reach the device as usual and BugCapsule records what the app received.
During replay the same results come from the capsule with their recorded
timing, and location services are never touched. A bug that depends on a
denied permission, a disabled service, a timeout or a particular sequence of
fixes comes back as it happened.

The adapter is a dependency simulation. It reproduces what your app saw, not
how the platform computes locations.

## Install

```yaml
dependencies:
  bug_capsule: ^0.4.1-beta.6
  bug_capsule_geolocator: ^0.1.0-dev.1
  geolocator: ^14.1.0
```

```dart
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_geolocator/bug_capsule_geolocator.dart';

Future<void> main() async {
  await BugCapsule.init(integrations: [BugCapsuleGeolocator() /*, ... */]);
  runApp(const MyApp());
}
```

Your app code does not change. `BugCapsule.init` installs a delegating
`GeolocatorPlatform.instance`, so `Geolocator.getCurrentPosition()`,
`Geolocator.getPositionStream()` and the other static calls go through the
adapter. `uninstall()` puts the original platform back.

## Supported operations

| Operation | Recorded |
|---|---|
| `checkPermission`, `requestPermission` | the `LocationPermission` |
| `isLocationServiceEnabled` | the `bool` |
| `getCurrentPosition(locationSettings:)` | the `Position`, or the error |
| `getLastKnownPosition(forceLocationManager:)` | the `Position` or `null` |
| `getPositionStream(locationSettings:)` | every fix with its timing, errors, completion and cancellation |
| `getServiceStatusStream` | every `ServiceStatus` |

Positions round-trip losslessly: every field, including the `has*` flags,
`floor`, `isMocked`, `-0.0` and whole-number doubles, and the timestamp to the
microsecond with its UTC flag. Location settings are matched by type and
fields (`AndroidSettings` and `AppleSettings` contribute their own).

Errors are thrown again as the geolocator exception that was recorded:
`PermissionDeniedException`, `LocationServiceDisabledException`,
`PermissionDefinitionsNotFoundException`,
`PermissionRequestInProgressException`, `PositionUpdateException`,
`ActivityMissingException`, `AlreadySubscribedException`,
`InvalidPermissionException` and `TimeoutException`.

`distanceBetween` and `bearingBetween` are pure Dart and always work.

**Unsupported operations** (`getLocationAccuracy`,
`requestTemporaryFullAccuracy`, `openAppSettings`, `openLocationSettings`)
still reach the platform while capturing. The capsule then gets an
`operation.unsupported` gap naming the operation, which makes it `partial`.
During replay they fail with a `NativeAdapterException`
(`bugcapsule.unsupported`) and a `native.unrecorded` divergence. They never
reach the platform.

An operation the capsule does not contain fails the same way, with
`bugcapsule.unrecorded`.

## Tested versions

| Package | Version |
|---|---|
| `geolocator_platform_interface` | 4.4.1 |

Tested with Flutter 3.47.8 against a scripted `GeolocatorPlatform`. Not yet
tested on a device with the `geolocator_android` or `geolocator_apple`
implementations.

## Limits

- `BugCapsule.init` must run after plugin registration, which is the normal
  case. Code that replaces `GeolocatorPlatform.instance` afterwards bypasses
  the adapter.
- Code that checks the platform's concrete type
  (`GeolocatorPlatform.instance is GeolocatorAndroid`) sees the adapter
  instead. Use `BugCapsuleGeolocator.delegate` for platform-specific calls.
- Only one adapter instance per app.
- The usual capture bounds apply: 64 KiB per payload, 1 MiB of interaction
  payloads per capsule, 32 open streams.
- The project's capture settings can turn off the adapter
  (`bug_capsule.geolocator`) without touching other capture.

## License

MIT. See [LICENSE](LICENSE).
