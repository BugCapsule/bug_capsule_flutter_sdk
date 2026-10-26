## 0.1.0-dev.1

- Pilot release. `BugCapsuleGoogleMaps` (`bug_capsule.google_maps_flutter`) installs a delegating `GoogleMapsFlutterPlatform.instance` and records camera commands, coordinate queries (`getVisibleRegion`, `getLatLng`, `getScreenCoordinate`, `getZoomLevel`) and map events (`onTap`, `onLongPress`, `onCameraMoveStarted`, `onCameraMove`, `onCameraIdle`, `onMarkerTap`). The map always renders through the real platform view.
