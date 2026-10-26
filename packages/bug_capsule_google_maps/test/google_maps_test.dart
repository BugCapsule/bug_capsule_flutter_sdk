import 'dart:async';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/testing.dart';
import 'package:bug_capsule_google_maps/bug_capsule_google_maps.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';

/// Rendering calls every platform answers (also the throwing one, since
/// the real map view keeps rendering during replay).
mixin _Rendering on GoogleMapsFlutterPlatform {
  final List<String> renderCalls = [];

  @override
  Future<void> init(int mapId) async => renderCalls.add('init');

  @override
  Future<void> updateMarkers(
    MarkerUpdates markerUpdates, {
    required int mapId,
  }) async => renderCalls.add('updateMarkers');

  @override
  Widget buildViewWithConfiguration(
    int creationId,
    PlatformViewCreatedCallback onPlatformViewCreated, {
    required MapWidgetConfiguration widgetConfiguration,
    MapConfiguration mapConfiguration = const MapConfiguration(),
    MapObjects mapObjects = const MapObjects(),
  }) {
    renderCalls.add('buildViewWithConfiguration');
    return const SizedBox(key: Key('native-map'));
  }
}

/// A scripted map: camera state, coordinate projection and event streams
/// the test drives.
class FakeMapsPlatform extends GoogleMapsFlutterPlatform with _Rendering {
  CameraPosition camera = const CameraPosition(
    target: LatLng(59.91, 10.75),
    zoom: 12,
  );
  final taps = StreamController<MapTapEvent>.broadcast();
  final longPresses = StreamController<MapLongPressEvent>.broadcast();
  final moveStarted = StreamController<CameraMoveStartedEvent>.broadcast();
  final moves = StreamController<CameraMoveEvent>.broadcast();
  final idle = StreamController<CameraIdleEvent>.broadcast();
  final markerTaps = StreamController<MarkerTapEvent>.broadcast();
  final dragEnds = StreamController<MarkerDragEndEvent>.broadcast();
  final calls = <String>[];

  @override
  Future<void> moveCamera(
    CameraUpdate cameraUpdate, {
    required int mapId,
  }) async {
    calls.add('moveCamera');
    final json = cameraUpdate.toJson() as List;
    if (json.first == 'newLatLng') {
      final l = json[1] as List;
      camera = CameraPosition(
        target: LatLng(l[0] as double, l[1] as double),
        zoom: camera.zoom,
      );
    }
  }

  @override
  Future<void> animateCameraWithConfiguration(
    CameraUpdate cameraUpdate,
    CameraUpdateAnimationConfiguration configuration, {
    required int mapId,
  }) async {
    calls.add('animateCamera');
    final json = cameraUpdate.toJson() as List;
    if (json.first == 'zoomTo') {
      camera = CameraPosition(target: camera.target, zoom: json[1] as double);
    }
    moveStarted.add(CameraMoveStartedEvent(mapId));
    moves.add(CameraMoveEvent(mapId, camera));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    idle.add(CameraIdleEvent(mapId));
  }

  @override
  Future<LatLngBounds> getVisibleRegion({required int mapId}) async {
    calls.add('getVisibleRegion');
    final t = camera.target;
    return LatLngBounds(
      southwest: LatLng(t.latitude - 0.05, t.longitude - 0.1),
      northeast: LatLng(t.latitude + 0.05, t.longitude + 0.1),
    );
  }

  @override
  Future<LatLng> getLatLng(
    ScreenCoordinate screenCoordinate, {
    required int mapId,
  }) async {
    calls.add('getLatLng');
    return LatLng(
      camera.target.latitude + screenCoordinate.y / 10000,
      camera.target.longitude + screenCoordinate.x / 10000,
    );
  }

  @override
  Future<ScreenCoordinate> getScreenCoordinate(
    LatLng latLng, {
    required int mapId,
  }) async {
    calls.add('getScreenCoordinate');
    return ScreenCoordinate(
      x: ((latLng.longitude - camera.target.longitude) * 10000).round(),
      y: ((latLng.latitude - camera.target.latitude) * 10000).round(),
    );
  }

  @override
  Future<double> getZoomLevel({required int mapId}) async {
    calls.add('getZoomLevel');
    return camera.zoom;
  }

  @override
  Future<Uint8List?> takeSnapshot({required int mapId}) async {
    calls.add('takeSnapshot');
    return Uint8List(4);
  }

  @override
  Stream<MapTapEvent> onTap({required int mapId}) => taps.stream;
  @override
  Stream<MapLongPressEvent> onLongPress({required int mapId}) =>
      longPresses.stream;
  @override
  Stream<CameraMoveStartedEvent> onCameraMoveStarted({required int mapId}) =>
      moveStarted.stream;
  @override
  Stream<CameraMoveEvent> onCameraMove({required int mapId}) => moves.stream;
  @override
  Stream<CameraIdleEvent> onCameraIdle({required int mapId}) => idle.stream;
  @override
  Stream<MarkerTapEvent> onMarkerTap({required int mapId}) => markerTaps.stream;
  @override
  Stream<MarkerDragEndEvent> onMarkerDragEnd({required int mapId}) =>
      dragEnds.stream;
}

/// Fails the test if replay asks the platform anything but rendering.
class ThrowingMapsPlatform extends GoogleMapsFlutterPlatform with _Rendering {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError(
      'replay reached the maps platform: ${invocation.memberName}',
    );
  }

  Never _fail(String m) {
    calls++;
    throw StateError('replay reached the maps platform: $m');
  }

  @override
  Future<void> moveCamera(CameraUpdate cameraUpdate, {required int mapId}) =>
      _fail('moveCamera');
  @override
  Future<void> animateCamera(CameraUpdate cameraUpdate, {required int mapId}) =>
      _fail('animateCamera');
  @override
  Future<void> animateCameraWithConfiguration(
    CameraUpdate cameraUpdate,
    CameraUpdateAnimationConfiguration configuration, {
    required int mapId,
  }) => _fail('animateCameraWithConfiguration');
  @override
  Future<LatLngBounds> getVisibleRegion({required int mapId}) =>
      _fail('getVisibleRegion');
  @override
  Future<LatLng> getLatLng(
    ScreenCoordinate screenCoordinate, {
    required int mapId,
  }) => _fail('getLatLng');
  @override
  Future<ScreenCoordinate> getScreenCoordinate(
    LatLng latLng, {
    required int mapId,
  }) => _fail('getScreenCoordinate');
  @override
  Future<double> getZoomLevel({required int mapId}) => _fail('getZoomLevel');
  @override
  Future<Uint8List?> takeSnapshot({required int mapId}) =>
      _fail('takeSnapshot');
  @override
  Stream<MapTapEvent> onTap({required int mapId}) => _fail('onTap');
  @override
  Stream<MapLongPressEvent> onLongPress({required int mapId}) =>
      _fail('onLongPress');
  @override
  Stream<CameraMoveStartedEvent> onCameraMoveStarted({required int mapId}) =>
      _fail('onCameraMoveStarted');
  @override
  Stream<CameraMoveEvent> onCameraMove({required int mapId}) =>
      _fail('onCameraMove');
  @override
  Stream<CameraIdleEvent> onCameraIdle({required int mapId}) =>
      _fail('onCameraIdle');
  @override
  Stream<MarkerTapEvent> onMarkerTap({required int mapId}) =>
      _fail('onMarkerTap');
  @override
  Stream<MarkerDragEndEvent> onMarkerDragEnd({required int mapId}) =>
      _fail('onMarkerDragEnd');
}

GoogleMapsFlutterPlatform get platform => GoogleMapsFlutterPlatform.instance;

/// Collects events of [stream] until [stop] completes.
Future<List<T>> collect<T>(Stream<T> stream, Future<void> stop) async {
  final out = <T>[];
  final sub = stream.listen(out.add);
  await stop;
  await sub.cancel();
  return out;
}

Future<void> until(bool Function() done) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final original = GoogleMapsFlutterPlatform.instance;
  late List<BugCapsuleGoogleMaps> adapters;
  late List<ThrowingMapsPlatform> throwing;
  late List<FakeMapsPlatform> fakes;

  setUp(() {
    adapters = [];
    throwing = [];
    fakes = [];
  });
  tearDown(() {
    for (final a in adapters.reversed) {
      a.uninstall();
    }
    GoogleMapsFlutterPlatform.instance = original;
  });

  BugCapsuleGoogleMaps create(bool replaying) {
    final GoogleMapsFlutterPlatform p;
    if (replaying) {
      p = ThrowingMapsPlatform();
      throwing.add(p as ThrowingMapsPlatform);
    } else {
      p = FakeMapsPlatform();
      fakes.add(p as FakeMapsPlatform);
    }
    final a = BugCapsuleGoogleMaps(platform: p);
    adapters.add(a);
    return a;
  }

  /// Platform view ids differ between capture (7) and replay (3); maps are
  /// matched by creation order.
  int mapIdOf(BugCapsuleGoogleMaps a) => a.delegate is FakeMapsPlatform ? 7 : 3;

  FakeMapsPlatform? fakeOf(BugCapsuleGoogleMaps a) {
    final d = a.delegate;
    return d is FakeMapsPlatform ? d : null;
  }

  void expectClean(AdapterConformanceResult r) {
    expect(r.problems, isEmpty);
    expect(throwing.single.calls, 0, reason: 'replay reached the platform');
    expect(r.dependencies.single.adapter, 'bug_capsule.google_maps_flutter');
  }

  group('conformance through GoogleMapsFlutterPlatform.instance', () {
    test('moveCamera and animateCamera', () async {
      final r = await AdapterConformance.run(
        create: create,
        scenario: (a) async {
          final id = mapIdOf(a);
          await platform.init(id);
          await platform.moveCamera(
            CameraUpdate.newLatLng(const LatLng(60.39, 5.32)),
            mapId: id,
          );
          await platform.animateCameraWithConfiguration(
            CameraUpdate.zoomTo(15),
            const CameraUpdateAnimationConfiguration(
              duration: Duration(milliseconds: 300),
            ),
            mapId: id,
          );
          return 'ok';
        },
      );
      expectClean(r);
      final args = [
        for (final e in r.events)
          if (e.type == 'native.call') (e.data['args'] as Map)['value'],
      ];
      expect(args, [
        {
          'map': 0,
          'update': [
            'newLatLng',
            [60.39, 5.32],
          ],
        },
        {
          'map': 0,
          'update': [
            'zoomTo',
            {r'$t': 'double', 'v': '15.0'},
          ],
          'durationUs': 300000,
        },
      ]);
    });

    test('coordinate queries', () async {
      final r = await AdapterConformance.run(
        create: create,
        scenario: (a) async {
          final id = mapIdOf(a);
          await platform.init(id);
          final region = await platform.getVisibleRegion(mapId: id);
          final latLng = await platform.getLatLng(
            const ScreenCoordinate(x: 120, y: -40),
            mapId: id,
          );
          final screen = await platform.getScreenCoordinate(
            const LatLng(59.92, 10.76),
            mapId: id,
          );
          final zoom = await platform.getZoomLevel(mapId: id);
          return [
            MapsJson.bounds(region),
            MapsJson.latLng(latLng),
            MapsJson.screen(screen),
            zoom,
            zoom.runtimeType.toString(),
          ];
        },
      );
      expectClean(r);
      expect((r.replayed! as List).last, 'double');
    });

    test('map events replay as events with the replay map id', () async {
      final r = await AdapterConformance.run(
        create: create,
        scenario: (a) async {
          final id = mapIdOf(a);
          final fake = fakeOf(a);
          await platform.init(id);
          final seen = <Object?>[];
          final subs = [
            platform
                .onTap(mapId: id)
                .listen(
                  (e) => seen.add([
                    'tap',
                    e.mapId == id,
                    MapsJson.latLng(e.position),
                  ]),
                ),
            platform
                .onLongPress(mapId: id)
                .listen(
                  (e) => seen.add([
                    'longPress',
                    e.mapId == id,
                    MapsJson.latLng(e.position),
                  ]),
                ),
            platform
                .onCameraMoveStarted(mapId: id)
                .listen((e) => seen.add(['moveStarted', e.mapId == id])),
            platform
                .onCameraMove(mapId: id)
                .listen(
                  (e) => seen.add([
                    'move',
                    e.mapId == id,
                    MapsJson.camera(e.value),
                  ]),
                ),
            platform
                .onCameraIdle(mapId: id)
                .listen((e) => seen.add(['idle', e.mapId == id])),
            platform
                .onMarkerTap(mapId: id)
                .listen(
                  (e) => seen.add(['marker', e.mapId == id, e.value.value]),
                ),
          ];
          if (fake != null) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            fake.taps.add(MapTapEvent(id, const LatLng(59.9, 10.7)));
            await Future<void>.delayed(const Duration(milliseconds: 15));
            fake.markerTaps.add(MarkerTapEvent(id, const MarkerId('shop-42')));
            await Future<void>.delayed(const Duration(milliseconds: 15));
            fake.longPresses.add(
              MapLongPressEvent(id, const LatLng(59.95, 10.8)),
            );
            await Future<void>.delayed(const Duration(milliseconds: 5));
            fake.moveStarted.add(CameraMoveStartedEvent(id));
            await Future<void>.delayed(const Duration(milliseconds: 5));
            fake.moves.add(
              CameraMoveEvent(
                id,
                const CameraPosition(
                  target: LatLng(59.95, 10.8),
                  zoom: 13.5,
                  bearing: 90,
                  tilt: 0,
                ),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 10));
            fake.idle.add(CameraIdleEvent(id));
          }
          await until(() => seen.length == 6);
          for (final s in subs) {
            await s.cancel();
          }
          return seen;
        },
      );
      expectClean(r);
      final replayed = r.replayed! as List;
      // Events carry the replay's own map id (3, not the recorded 7).
      expect(replayed.map((e) => (e as List)[1]).toSet(), {true});
      expect(replayed.map((e) => (e as List).first), [
        'tap',
        'marker',
        'longPress',
        'moveStarted',
        'move',
        'idle',
      ]);
      expect(
        r.events.where((e) => e.type == 'native.cancel'),
        hasLength(6),
        reason: 'every listener teardown is recorded',
      );
    });
  });

  test('two maps are told apart by creation order', () async {
    final r = await AdapterConformance.run(
      create: create,
      scenario: (a) async {
        final first = mapIdOf(a);
        final second = first + 1;
        await platform.init(first);
        await platform.init(second);
        final z2 = await platform.getVisibleRegion(mapId: second);
        final z1 = await platform.getVisibleRegion(mapId: first);
        return [MapsJson.bounds(z1), MapsJson.bounds(z2)];
      },
    );
    expectClean(r);
    final instances = [
      for (final e in r.events)
        if (e.type == 'native.call') e.data['instance'],
    ];
    expect(instances, ['map1', 'map0']);
  });

  test('rendering always reaches the real platform view', () async {
    final capture = InteractionHarness.capture();
    final a = create(false);
    await capture.setUp([a]);
    await platform.init(7);
    await platform.getZoomLevel(mapId: 7);
    final replay = InteractionHarness.replay(
      capture.encodedEvents(),
      dependencies: capture.dependencies(),
    );
    final b = create(true);
    await replay.setUp([b]);
    final view = platform.buildViewWithConfiguration(
      1,
      (_) {},
      widgetConfiguration: const MapWidgetConfiguration(
        initialCameraPosition: CameraPosition(target: LatLng(0, 0)),
        textDirection: TextDirection.ltr,
      ),
    );
    expect((view as SizedBox).key, const Key('native-map'));
    await platform.init(3);
    await platform.updateMarkers(
      MarkerUpdates.from(const {}, {const Marker(markerId: MarkerId('m'))}),
      mapId: 3,
    );
    expect(await platform.getZoomLevel(mapId: 3), 12);
    expect(throwing.single.renderCalls, [
      'buildViewWithConfiguration',
      'init',
      'updateMarkers',
    ]);
    expect(throwing.single.calls, 0);
    expect(replay.finish(), isEmpty);
  });

  group('unsupported operations', () {
    test('capture delegates and records a gap', () async {
      final capture = InteractionHarness.capture();
      final a = create(false);
      await capture.setUp([a]);
      await platform.init(7);
      await platform.getZoomLevel(mapId: 7);
      expect(await platform.takeSnapshot(mapId: 7), hasLength(4));
      final drags = <MarkerDragEndEvent>[];
      final sub = platform.onMarkerDragEnd(mapId: 7).listen(drags.add);
      fakes.single.dragEnds.add(
        MarkerDragEndEvent(7, const LatLng(1, 2), const MarkerId('m')),
      );
      await until(() => drags.isNotEmpty);
      await sub.cancel();
      final dep = capture.dependencies().single;
      expect(dep.coverage, DependencyCoverage.partial);
      expect(dep.gaps.single.code, DependencyGaps.operationUnsupported);
      expect(dep.gaps.single.count, 2);
    });

    test(
      'replay fails reads explicitly and replays no unsupported events',
      () async {
        final capture = InteractionHarness.capture();
        await capture.setUp([create(false)]);
        await platform.init(7);
        await platform.getZoomLevel(mapId: 7);
        final replay = InteractionHarness.replay(
          capture.encodedEvents(),
          dependencies: capture.dependencies(),
        );
        await replay.setUp([create(true)]);
        await platform.init(3);
        await platform.getZoomLevel(mapId: 3);
        await expectLater(
          platform.takeSnapshot(mapId: 3),
          throwsA(
            isA<NativeAdapterException>().having(
              (e) => e.code,
              'code',
              'bugcapsule.unsupported',
            ),
          ),
        );
        expect(await platform.onMarkerDragEnd(mapId: 3).toList(), isEmpty);
        expect(throwing.single.calls, 0);
        expect(replay.finish().map((d) => d.type), ['native.unrecorded']);
      },
    );
  });

  test('replay without a maps recording never asks the platform', () async {
    final replay = InteractionHarness.replay(const [], dependencies: const []);
    await replay.setUp([create(true)]);
    await expectLater(
      platform.getVisibleRegion(mapId: 3),
      throwsA(isA<NativeAdapterException>()),
    );
    await expectLater(
      platform.onTap(mapId: 3).first,
      throwsA(isA<NativeAdapterException>()),
    );
    expect(throwing.single.calls, 0);
    expect(replay.finish().map((d) => d.type).toSet(), {'native.unrecorded'});
  });
}
