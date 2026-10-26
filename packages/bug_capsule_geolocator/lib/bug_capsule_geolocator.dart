/// BugCapsule native SDK adapter for location (capsule-v2 `native`):
/// [BugCapsuleGeolocator] records permission, service and position results
/// at the `geolocator_platform_interface` boundary and replays them without
/// touching location services.
///
/// ```dart
/// await BugCapsule.init(integrations: [BugCapsuleGeolocator(), ...]);
/// // App code is unchanged:
/// final position = await Geolocator.getCurrentPosition();
/// ```
library;

export 'src/geolocator.dart';
