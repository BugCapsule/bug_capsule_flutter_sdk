## 0.1.0-dev.1

- Pilot release. `BugCapsuleGeolocator` (`bug_capsule.geolocator`) installs a delegating `GeolocatorPlatform.instance` and records `checkPermission`, `requestPermission`, `isLocationServiceEnabled`, `getCurrentPosition`, `getLastKnownPosition`, `getPositionStream` and `getServiceStatusStream`. Other operations reach the platform while capturing, add a gap, and fail explicitly during replay.
