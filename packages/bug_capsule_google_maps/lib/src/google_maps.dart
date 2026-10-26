// The platform interface still declares (and the plugin still calls) its
// deprecated members; the delegating platform has to forward them.
// ignore_for_file: deprecated_member_use

import 'dart:async';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';

const bugCapsuleGoogleMapsVersion = '0.1.0-dev.1';

/// Google Maps adapter (`bug_capsule.google_maps_flutter`, capsule-v2
/// `native`) on the `google_maps_flutter_platform_interface` boundary.
///
/// [setUp] (run by `BugCapsule.init`) installs a delegating
/// [GoogleMapsFlutterPlatform.instance], so `GoogleMap` and
/// `GoogleMapController` keep working unchanged. It records:
///
/// * camera commands (`moveCamera`, `animateCamera`) with their
///   `CameraUpdate` JSON and outcome;
/// * coordinate queries (`getVisibleRegion`, `getLatLng`,
///   `getScreenCoordinate`, `getZoomLevel`) and their results;
/// * map events as subscriptions (`onTap`, `onLongPress`,
///   `onCameraMoveStarted`, `onCameraMove`, `onCameraIdle`, `onMarkerTap`).
///
/// During replay these are served from the capsule: the taps, selected
/// coordinates and camera moves the user made reach the app as events with
/// their recorded timing, and the platform is not asked.
///
/// The map itself always renders through the real platform view
/// (`buildView*`, `init`, `update*`, styles, info windows): rendering,
/// tiles, textures and gestures are not reproduced, and replayed camera
/// commands do not move the native camera. Maps are told apart by the order
/// they were created in, so platform view ids may differ between capture
/// and replay.
class BugCapsuleGoogleMaps extends NativeAdapter {
  /// Wraps [platform], or the [GoogleMapsFlutterPlatform.instance]
  /// registered when [setUp] runs.
  BugCapsuleGoogleMaps({GoogleMapsFlutterPlatform? platform})
    : _delegate = platform;

  GoogleMapsFlutterPlatform? _delegate;
  _BugCapsuleMapsPlatform? _installed;
  final Map<int, int> _ordinals = {};

  /// The platform implementation calls reach (rendering always; recorded
  /// operations while capturing).
  GoogleMapsFlutterPlatform get delegate =>
      _delegate ??= _unwrap(GoogleMapsFlutterPlatform.instance);

  @override
  String get name => 'google_maps';

  @override
  String get adapter => 'bug_capsule.google_maps_flutter';

  @override
  String get adapterVersion => bugCapsuleGoogleMapsVersion;

  static const supportedOperations = [
    'moveCamera',
    'animateCamera',
    'getVisibleRegion',
    'getLatLng',
    'getScreenCoordinate',
    'getZoomLevel',
    'onTap',
    'onLongPress',
    'onCameraMoveStarted',
    'onCameraMove',
    'onCameraIdle',
    'onMarkerTap',
  ];

  @override
  List<String> get operations => supportedOperations;

  @override
  Map<String, String> get tested => const {
    'google_maps_flutter_platform_interface': '2.17.0',
  };

  @override
  Future<void> setUp(BugCapsuleSession session) async {
    await super.setUp(session);
    install();
  }

  /// Installs the delegating [GoogleMapsFlutterPlatform.instance]
  /// (idempotent).
  void install() {
    delegate;
    if (identical(GoogleMapsFlutterPlatform.instance, _installed)) return;
    GoogleMapsFlutterPlatform.instance = _installed = _BugCapsuleMapsPlatform(
      this,
    );
  }

  /// Puts [delegate] back as [GoogleMapsFlutterPlatform.instance].
  void uninstall() {
    if (identical(GoogleMapsFlutterPlatform.instance, _installed)) {
      GoogleMapsFlutterPlatform.instance = delegate;
    }
    _installed = null;
  }

  static GoogleMapsFlutterPlatform _unwrap(GoogleMapsFlutterPlatform p) =>
      p is _BugCapsuleMapsPlatform ? p._owner.delegate : p;

  /// 0-based creation order of the map with platform view id [mapId].
  int mapOrdinal(int mapId) =>
      _ordinals.putIfAbsent(mapId, () => _ordinals.length);

  @override
  (String, String?, Object?) describeError(Object error) {
    final (code, message, details) = switch (error) {
      PlatformException(:final code, :final message) => (
        'platform.$code',
        message,
        null,
      ),
      _ => super.describeError(error),
    };
    final s = session;
    return (
      code,
      message == null || s == null ? message : s.redactor.scrubText(message),
      details,
    );
  }

  @override
  Object rebuildError(String code, String? message, Object? details) =>
      code.startsWith('platform.')
      ? PlatformException(code: code.substring(9), message: message)
      : super.rebuildError(code, message, details);

  // ------------------------------------------------------------ plumbing

  bool get _replaying => session?.replay != null;

  /// Replaying a capsule without this adapter's recording.
  bool get _unserved => _replaying && replayInteractions == null;

  NativeAdapterException _fail(String code, String operation, String why) {
    diverge('native.unrecorded', '$adapter $operation: $why');
    return NativeAdapterException(code, '$operation: $why');
  }

  static const _noRecording = 'the capsule has no recording of this adapter';

  Future<T> _call<T>(
    String operation,
    int mapId, {
    Map<String, Object?> args = const {},
    required Future<T> Function() invoke,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) {
    if (_unserved) {
      return Future.error(
        _fail('bugcapsule.unrecorded', operation, _noRecording),
      );
    }
    final map = mapOrdinal(mapId);
    return call(
      operation,
      args: {'map': map, ...args},
      instance: 'map$map',
      invoke: invoke,
      encode: encode,
      decode: decode,
    );
  }

  Stream<T> _events<T>(
    String operation,
    int mapId, {
    required Stream<T> Function() open,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) {
    if (_unserved) {
      return Stream.multi((c) {
        c
          ..addError(_fail('bugcapsule.unrecorded', operation, _noRecording))
          ..close();
      });
    }
    final map = mapOrdinal(mapId);
    return subscribe(
      operation,
      args: {'map': map},
      instance: 'map$map',
      open: open,
      encode: encode,
      decode: decode,
    );
  }

  /// A read this adapter does not record: the platform while capturing
  /// (with a gap), an explicit failure during replay.
  Future<T> _unsupported<T>(String operation, Future<T> Function() real) {
    if (_replaying) {
      return Future.error(
        _fail(
          'bugcapsule.unsupported',
          operation,
          'not recorded by $adapter, so it cannot be replayed',
        ),
      );
    }
    if (capturing) {
      stats.gap(
        DependencyGaps.operationUnsupported,
        'unsupported operation $operation (not recorded)',
      );
    }
    return real();
  }

  /// Events this adapter does not record: none during replay; while
  /// capturing, the platform's stream, with a gap once an event arrives.
  Stream<T> _unsupportedEvents<T>(String operation, Stream<T> Function() real) {
    if (_replaying) return const Stream.empty();
    return real().map((e) {
      if (capturing) {
        stats.gap(
          DependencyGaps.operationUnsupported,
          'unsupported event $operation (not recorded)',
        );
      }
      return e;
    });
  }
}

/// JSON of the maps value types (lossless through capsule typed values).
abstract final class MapsJson {
  static Object latLng(LatLng p) => [p.latitude, p.longitude];

  static LatLng readLatLng(Object? json) {
    final l = json! as List;
    return LatLng((l[0] as num).toDouble(), (l[1] as num).toDouble());
  }

  static Object bounds(LatLngBounds b) => [
    latLng(b.southwest),
    latLng(b.northeast),
  ];

  static LatLngBounds readBounds(Object? json) {
    final l = json! as List;
    return LatLngBounds(
      southwest: readLatLng(l[0]),
      northeast: readLatLng(l[1]),
    );
  }

  static Object screen(ScreenCoordinate c) => {'x': c.x, 'y': c.y};

  static ScreenCoordinate readScreen(Object? json) {
    final m = json! as Map;
    return ScreenCoordinate(
      x: (m['x'] as num).toInt(),
      y: (m['y'] as num).toInt(),
    );
  }

  static Object camera(CameraPosition p) => {
    'target': latLng(p.target),
    'zoom': p.zoom,
    'bearing': p.bearing,
    'tilt': p.tilt,
  };

  static CameraPosition readCamera(Object? json) {
    final m = json! as Map;
    return CameraPosition(
      target: readLatLng(m['target']),
      zoom: (m['zoom'] as num).toDouble(),
      bearing: (m['bearing'] as num).toDouble(),
      tilt: (m['tilt'] as num).toDouble(),
    );
  }
}

/// The [GoogleMapsFlutterPlatform.instance] [BugCapsuleGoogleMaps]
/// installs.
class _BugCapsuleMapsPlatform extends GoogleMapsFlutterPlatform {
  _BugCapsuleMapsPlatform(this._owner);

  final BugCapsuleGoogleMaps _owner;

  GoogleMapsFlutterPlatform get _real => _owner.delegate;

  // ------------------------------------------------------ recorded calls

  @override
  Future<void> moveCamera(CameraUpdate cameraUpdate, {required int mapId}) =>
      _owner._call<void>(
        'moveCamera',
        mapId,
        args: {'update': cameraUpdate.toJson()},
        invoke: () => _real.moveCamera(cameraUpdate, mapId: mapId),
        encode: (_) => null,
        decode: (_) {},
      );

  @override
  Future<void> animateCamera(CameraUpdate cameraUpdate, {required int mapId}) =>
      _owner._call<void>(
        'animateCamera',
        mapId,
        args: {'update': cameraUpdate.toJson()},
        invoke: () => _real.animateCamera(cameraUpdate, mapId: mapId),
        encode: (_) => null,
        decode: (_) {},
      );

  @override
  Future<void> animateCameraWithConfiguration(
    CameraUpdate cameraUpdate,
    CameraUpdateAnimationConfiguration configuration, {
    required int mapId,
  }) => _owner._call<void>(
    'animateCamera',
    mapId,
    args: {
      'update': cameraUpdate.toJson(),
      'durationUs': ?configuration.duration?.inMicroseconds,
    },
    invoke: () => _real.animateCameraWithConfiguration(
      cameraUpdate,
      configuration,
      mapId: mapId,
    ),
    encode: (_) => null,
    decode: (_) {},
  );

  @override
  Future<LatLngBounds> getVisibleRegion({required int mapId}) => _owner._call(
    'getVisibleRegion',
    mapId,
    invoke: () => _real.getVisibleRegion(mapId: mapId),
    encode: MapsJson.bounds,
    decode: MapsJson.readBounds,
  );

  @override
  Future<ScreenCoordinate> getScreenCoordinate(
    LatLng latLng, {
    required int mapId,
  }) => _owner._call(
    'getScreenCoordinate',
    mapId,
    args: {'latLng': MapsJson.latLng(latLng)},
    invoke: () => _real.getScreenCoordinate(latLng, mapId: mapId),
    encode: MapsJson.screen,
    decode: MapsJson.readScreen,
  );

  @override
  Future<LatLng> getLatLng(
    ScreenCoordinate screenCoordinate, {
    required int mapId,
  }) => _owner._call(
    'getLatLng',
    mapId,
    args: {'point': MapsJson.screen(screenCoordinate)},
    invoke: () => _real.getLatLng(screenCoordinate, mapId: mapId),
    encode: MapsJson.latLng,
    decode: MapsJson.readLatLng,
  );

  @override
  Future<double> getZoomLevel({required int mapId}) => _owner._call(
    'getZoomLevel',
    mapId,
    invoke: () => _real.getZoomLevel(mapId: mapId),
    encode: (z) => z,
    decode: (json) => (json! as num).toDouble(),
  );

  // ----------------------------------------------------- recorded events

  @override
  Stream<MapTapEvent> onTap({required int mapId}) => _owner._events(
    'onTap',
    mapId,
    open: () => _real.onTap(mapId: mapId),
    encode: (e) => MapsJson.latLng(e.position),
    decode: (json) => MapTapEvent(mapId, MapsJson.readLatLng(json)),
  );

  @override
  Stream<MapLongPressEvent> onLongPress({required int mapId}) => _owner._events(
    'onLongPress',
    mapId,
    open: () => _real.onLongPress(mapId: mapId),
    encode: (e) => MapsJson.latLng(e.position),
    decode: (json) => MapLongPressEvent(mapId, MapsJson.readLatLng(json)),
  );

  @override
  Stream<CameraMoveStartedEvent> onCameraMoveStarted({required int mapId}) =>
      _owner._events(
        'onCameraMoveStarted',
        mapId,
        open: () => _real.onCameraMoveStarted(mapId: mapId),
        encode: (_) => null,
        decode: (_) => CameraMoveStartedEvent(mapId),
      );

  @override
  Stream<CameraMoveEvent> onCameraMove({required int mapId}) => _owner._events(
    'onCameraMove',
    mapId,
    open: () => _real.onCameraMove(mapId: mapId),
    encode: (e) => MapsJson.camera(e.value),
    decode: (json) => CameraMoveEvent(mapId, MapsJson.readCamera(json)),
  );

  @override
  Stream<CameraIdleEvent> onCameraIdle({required int mapId}) => _owner._events(
    'onCameraIdle',
    mapId,
    open: () => _real.onCameraIdle(mapId: mapId),
    encode: (_) => null,
    decode: (_) => CameraIdleEvent(mapId),
  );

  @override
  Stream<MarkerTapEvent> onMarkerTap({required int mapId}) => _owner._events(
    'onMarkerTap',
    mapId,
    open: () => _real.onMarkerTap(mapId: mapId),
    encode: (e) => e.value.value,
    decode: (json) => MarkerTapEvent(mapId, MarkerId(json! as String)),
  );

  // -------------------------------------------- unsupported reads/events

  @override
  Future<bool> isMarkerInfoWindowShown(
    MarkerId markerId, {
    required int mapId,
  }) => _owner._unsupported(
    'isMarkerInfoWindowShown',
    () => _real.isMarkerInfoWindowShown(markerId, mapId: mapId),
  );

  @override
  Future<Uint8List?> takeSnapshot({required int mapId}) => _owner._unsupported(
    'takeSnapshot',
    () => _real.takeSnapshot(mapId: mapId),
  );

  @override
  Stream<InfoWindowTapEvent> onInfoWindowTap({required int mapId}) =>
      _owner._unsupportedEvents(
        'onInfoWindowTap',
        () => _real.onInfoWindowTap(mapId: mapId),
      );

  @override
  Stream<MarkerDragStartEvent> onMarkerDragStart({required int mapId}) =>
      _owner._unsupportedEvents(
        'onMarkerDragStart',
        () => _real.onMarkerDragStart(mapId: mapId),
      );

  @override
  Stream<MarkerDragEvent> onMarkerDrag({required int mapId}) =>
      _owner._unsupportedEvents(
        'onMarkerDrag',
        () => _real.onMarkerDrag(mapId: mapId),
      );

  @override
  Stream<MarkerDragEndEvent> onMarkerDragEnd({required int mapId}) =>
      _owner._unsupportedEvents(
        'onMarkerDragEnd',
        () => _real.onMarkerDragEnd(mapId: mapId),
      );

  @override
  Stream<PolylineTapEvent> onPolylineTap({required int mapId}) =>
      _owner._unsupportedEvents(
        'onPolylineTap',
        () => _real.onPolylineTap(mapId: mapId),
      );

  @override
  Stream<PolygonTapEvent> onPolygonTap({required int mapId}) =>
      _owner._unsupportedEvents(
        'onPolygonTap',
        () => _real.onPolygonTap(mapId: mapId),
      );

  @override
  Stream<CircleTapEvent> onCircleTap({required int mapId}) => _owner
      ._unsupportedEvents('onCircleTap', () => _real.onCircleTap(mapId: mapId));

  @override
  Stream<PointOfInterestTapEvent> onPointOfInterestTap({required int mapId}) =>
      _owner._unsupportedEvents(
        'onPointOfInterestTap',
        () => _real.onPointOfInterestTap(mapId: mapId),
      );

  @override
  Stream<ClusterTapEvent> onClusterTap({required int mapId}) =>
      _owner._unsupportedEvents(
        'onClusterTap',
        () => _real.onClusterTap(mapId: mapId),
      );

  @override
  Stream<GroundOverlayTapEvent> onGroundOverlayTap({required int mapId}) =>
      _owner._unsupportedEvents(
        'onGroundOverlayTap',
        () => _real.onGroundOverlayTap(mapId: mapId),
      );

  // ------------------------------- rendering: always the real platform

  @override
  Future<void> init(int mapId) {
    _owner.mapOrdinal(mapId);
    return _real.init(mapId);
  }

  @override
  void dispose({required int mapId}) => _real.dispose(mapId: mapId);

  @override
  Future<void> updateMapOptions(
    Map<String, dynamic> optionsUpdate, {
    required int mapId,
  }) => _real.updateMapOptions(optionsUpdate, mapId: mapId);

  @override
  Future<void> updateMapConfiguration(
    MapConfiguration configuration, {
    required int mapId,
  }) => _real.updateMapConfiguration(configuration, mapId: mapId);

  @override
  Future<void> updateMarkers(
    MarkerUpdates markerUpdates, {
    required int mapId,
  }) => _real.updateMarkers(markerUpdates, mapId: mapId);

  @override
  Future<void> updatePolygons(
    PolygonUpdates polygonUpdates, {
    required int mapId,
  }) => _real.updatePolygons(polygonUpdates, mapId: mapId);

  @override
  Future<void> updatePolylines(
    PolylineUpdates polylineUpdates, {
    required int mapId,
  }) => _real.updatePolylines(polylineUpdates, mapId: mapId);

  @override
  Future<void> updateCircles(
    CircleUpdates circleUpdates, {
    required int mapId,
  }) => _real.updateCircles(circleUpdates, mapId: mapId);

  @override
  Future<void> updateHeatmaps(
    HeatmapUpdates heatmapUpdates, {
    required int mapId,
  }) => _real.updateHeatmaps(heatmapUpdates, mapId: mapId);

  @override
  Future<void> updateTileOverlays({
    required Set<TileOverlay> newTileOverlays,
    required int mapId,
  }) =>
      _real.updateTileOverlays(newTileOverlays: newTileOverlays, mapId: mapId);

  @override
  Future<void> updateClusterManagers(
    ClusterManagerUpdates clusterManagerUpdates, {
    required int mapId,
  }) => _real.updateClusterManagers(clusterManagerUpdates, mapId: mapId);

  @override
  Future<void> updateGroundOverlays(
    GroundOverlayUpdates groundOverlayUpdates, {
    required int mapId,
  }) => _real.updateGroundOverlays(groundOverlayUpdates, mapId: mapId);

  @override
  Future<void> clearTileCache(
    TileOverlayId tileOverlayId, {
    required int mapId,
  }) => _real.clearTileCache(tileOverlayId, mapId: mapId);

  @override
  Future<void> setMapStyle(String? mapStyle, {required int mapId}) =>
      _real.setMapStyle(mapStyle, mapId: mapId);

  @override
  Future<String?> getStyleError({required int mapId}) =>
      _real.getStyleError(mapId: mapId);

  @override
  Future<void> showMarkerInfoWindow(MarkerId markerId, {required int mapId}) =>
      _real.showMarkerInfoWindow(markerId, mapId: mapId);

  @override
  Future<void> hideMarkerInfoWindow(MarkerId markerId, {required int mapId}) =>
      _real.hideMarkerInfoWindow(markerId, mapId: mapId);

  @override
  Future<bool> isAdvancedMarkersAvailable({required int mapId}) =>
      _real.isAdvancedMarkersAvailable(mapId: mapId);

  @override
  Widget buildView(
    int creationId,
    PlatformViewCreatedCallback onPlatformViewCreated, {
    required CameraPosition initialCameraPosition,
    Set<Marker> markers = const <Marker>{},
    Set<Polygon> polygons = const <Polygon>{},
    Set<Polyline> polylines = const <Polyline>{},
    Set<Circle> circles = const <Circle>{},
    Set<TileOverlay> tileOverlays = const <TileOverlay>{},
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers =
        const <Factory<OneSequenceGestureRecognizer>>{},
    Map<String, dynamic> mapOptions = const <String, dynamic>{},
  }) => _real.buildView(
    creationId,
    onPlatformViewCreated,
    initialCameraPosition: initialCameraPosition,
    markers: markers,
    polygons: polygons,
    polylines: polylines,
    circles: circles,
    tileOverlays: tileOverlays,
    gestureRecognizers: gestureRecognizers,
    mapOptions: mapOptions,
  );

  @override
  Widget buildViewWithTextDirection(
    int creationId,
    PlatformViewCreatedCallback onPlatformViewCreated, {
    required CameraPosition initialCameraPosition,
    required TextDirection textDirection,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
    Set<Marker> markers = const <Marker>{},
    Set<Polygon> polygons = const <Polygon>{},
    Set<Polyline> polylines = const <Polyline>{},
    Set<Circle> circles = const <Circle>{},
    Set<TileOverlay> tileOverlays = const <TileOverlay>{},
    Map<String, dynamic> mapOptions = const <String, dynamic>{},
  }) => _real.buildViewWithTextDirection(
    creationId,
    onPlatformViewCreated,
    initialCameraPosition: initialCameraPosition,
    textDirection: textDirection,
    gestureRecognizers: gestureRecognizers,
    markers: markers,
    polygons: polygons,
    polylines: polylines,
    circles: circles,
    tileOverlays: tileOverlays,
    mapOptions: mapOptions,
  );

  @override
  Widget buildViewWithConfiguration(
    int creationId,
    PlatformViewCreatedCallback onPlatformViewCreated, {
    required MapWidgetConfiguration widgetConfiguration,
    MapConfiguration mapConfiguration = const MapConfiguration(),
    MapObjects mapObjects = const MapObjects(),
  }) => _real.buildViewWithConfiguration(
    creationId,
    onPlatformViewCreated,
    widgetConfiguration: widgetConfiguration,
    mapConfiguration: mapConfiguration,
    mapObjects: mapObjects,
  );

  @override
  // ignore: invalid_use_of_visible_for_testing_member
  void enableDebugInspection() => _real.enableDebugInspection();
}
