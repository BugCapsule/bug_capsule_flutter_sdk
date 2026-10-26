/// BugCapsule native SDK adapter for Google Maps (capsule-v2 `native`):
/// [BugCapsuleGoogleMaps] records camera commands, coordinate queries and
/// map events at the `google_maps_flutter_platform_interface` boundary and
/// replays the taps and camera moves as events. The map itself still
/// renders through the real platform view.
///
/// ```dart
/// await BugCapsule.init(integrations: [BugCapsuleGoogleMaps(), ...]);
/// // GoogleMap and GoogleMapController are used unchanged.
/// ```
library;

export 'src/google_maps.dart';
