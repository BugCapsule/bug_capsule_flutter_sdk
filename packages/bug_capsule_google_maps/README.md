# BugCapsule for Google Maps

A native SDK adapter for [BugCapsule](https://docs.bugcapsule.com/flutter.html)
that records camera commands, coordinate queries and map events at the
`google_maps_flutter_platform_interface` boundary. During replay, the taps,
long presses, marker taps and camera moves the user made reach your app as
events with their recorded timing, and coordinate queries return the
recorded answers. A bug in how your app reacts to a selected place or a
camera position comes back without anyone touching the map.

The adapter is a dependency simulation. **Map rendering, tiles, textures and
gestures are not reproduced.** The map still renders through the real
platform view during replay, and replayed camera commands do not move its
camera.

## Install

```yaml
dependencies:
  bug_capsule: ^0.4.1-beta.6
  bug_capsule_google_maps: ^0.1.0-dev.1
  google_maps_flutter: ^2.19.0
```

```dart
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_google_maps/bug_capsule_google_maps.dart';

Future<void> main() async {
  await BugCapsule.init(integrations: [BugCapsuleGoogleMaps() /*, ... */]);
  runApp(const MyApp());
}
```

`GoogleMap` and `GoogleMapController` are used unchanged. `BugCapsule.init`
installs a delegating `GoogleMapsFlutterPlatform.instance`. `uninstall()`
puts the original platform back.

## Supported operations

| Operation | Recorded | Replay |
|---|---|---|
| `moveCamera`, `animateCamera` (with duration) | the `CameraUpdate` JSON and outcome | outcome returned, native camera not moved |
| `getVisibleRegion` | `LatLngBounds` | recorded result |
| `getLatLng(ScreenCoordinate)` | `LatLng` | recorded result |
| `getScreenCoordinate(LatLng)` | `ScreenCoordinate` | recorded result |
| `getZoomLevel` | `double` | recorded result |
| `onTap`, `onLongPress` | position of each event | delivered as events |
| `onCameraMoveStarted`, `onCameraMove`, `onCameraIdle` | each event, with the `CameraPosition` | delivered as events |
| `onMarkerTap` | the `MarkerId` | delivered as events |

Maps are told apart by the order they were created in, so a different
platform view id in replay still matches. Replayed events carry the id of
the map in the replay.

**Always the real platform**, in capture and replay: `buildView*`, `init`,
`dispose`, `updateMapConfiguration`, `updateMarkers` and the other `update*`
calls, `clearTileCache`, `setMapStyle`, `getStyleError`,
`showMarkerInfoWindow`, `hideMarkerInfoWindow` and
`isAdvancedMarkersAvailable`.

**Unsupported reads** (`takeSnapshot`, `isMarkerInfoWindowShown`) reach the
platform while capturing and add an `operation.unsupported` gap. During
replay they fail with a `NativeAdapterException` (`bugcapsule.unsupported`)
and a `native.unrecorded` divergence.

**Unsupported events** (`onInfoWindowTap`, marker drag events,
`onPolylineTap`, `onPolygonTap`, `onCircleTap`, `onPointOfInterestTap`,
`onClusterTap`, `onGroundOverlayTap`) come from the platform while capturing.
The first such event adds an `operation.unsupported` gap. During replay these
streams deliver nothing.

## Tested versions

| Package | Version |
|---|---|
| `google_maps_flutter_platform_interface` | 2.17.0 |

Tested with Flutter 3.47.8 against a scripted `GoogleMapsFlutterPlatform`,
following the call sequence `google_maps_flutter` 2.19.0 uses. Not yet tested
on a device with `google_maps_flutter_android` or `google_maps_flutter_ios`.

## Limits

- Rendering, tiles, textures, gestures and the native camera are not
  reproduced (see above).
- Code that checks the platform's concrete type
  (`GoogleMapsFlutterPlatform.instance is GoogleMapsFlutterAndroid`, for
  example to choose a renderer) sees the adapter instead. Do that
  configuration on `BugCapsuleGoogleMaps.delegate`, or before
  `BugCapsule.init`.
- Events of different streams recorded within the same millisecond can be
  delivered in a different order during replay. Each stream keeps its own
  order.
- The usual capture bounds apply: 64 KiB per payload, 1 MiB of interaction
  payloads per capsule, 32 open streams. Each map opens up to six recorded
  streams.
- The project's capture settings can turn off the adapter
  (`bug_capsule.google_maps_flutter`) without touching other capture.

## License

MIT. See [LICENSE](LICENSE).
