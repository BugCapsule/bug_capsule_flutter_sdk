import 'dart:async';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/testing.dart';
import 'package:bug_capsule_geolocator/bug_capsule_geolocator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

Position fix(double lat, double lng, {int second = 0}) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: DateTime.utc(2026, 10, 26, 9, 30, second, 123, 456),
  accuracy: 4.0,
  altitude: 12.5,
  altitudeAccuracy: 3.0,
  heading: -0.0,
  headingAccuracy: 10.25,
  speed: 1.0,
  speedAccuracy: 0.5,
  floor: 2,
  isMocked: false,
  hasAccuracy: true,
  hasAltitude: true,
  hasHeading: false,
  hasSpeed: true,
);

/// A scripted platform: three fixes 20 ms apart, a service toggle, and
/// configurable failures.
class FakeGeolocatorPlatform extends GeolocatorPlatform {
  LocationPermission permission = LocationPermission.denied;
  bool serviceEnabled = true;
  Object? currentError;
  final List<String> calls = [];

  @override
  Future<LocationPermission> checkPermission() async {
    calls.add('checkPermission');
    return permission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    calls.add('requestPermission');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return permission = LocationPermission.whileInUse;
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    calls.add('isLocationServiceEnabled');
    return serviceEnabled;
  }

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async {
    calls.add('getLastKnownPosition');
    return forceLocationManager ? null : fix(59.91, 10.75);
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    calls.add('getCurrentPosition');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (currentError case final e?) throw e;
    return fix(59.9139, 10.7522);
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    calls.add('getPositionStream');
    return Stream.periodic(
      const Duration(milliseconds: 20),
      (i) => fix(59.0 + i, 10.0, second: i),
    ).take(3);
  }

  @override
  Stream<ServiceStatus> getServiceStatusStream() {
    calls.add('getServiceStatusStream');
    return Stream.fromIterable(const [
      ServiceStatus.disabled,
      ServiceStatus.enabled,
    ]);
  }

  @override
  Future<LocationAccuracyStatus> getLocationAccuracy() async {
    calls.add('getLocationAccuracy');
    return LocationAccuracyStatus.precise;
  }

  @override
  Future<bool> openAppSettings() async {
    calls.add('openAppSettings');
    return true;
  }
}

/// Fails the test if replay reaches the platform.
class ThrowingGeolocatorPlatform extends GeolocatorPlatform {
  int calls = 0;

  Never _fail(String m) {
    calls++;
    throw StateError('replay reached the location platform: $m');
  }

  @override
  Future<LocationPermission> checkPermission() => _fail('checkPermission');
  @override
  Future<LocationPermission> requestPermission() => _fail('requestPermission');
  @override
  Future<bool> isLocationServiceEnabled() => _fail('isLocationServiceEnabled');
  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) =>
      _fail('getLastKnownPosition');
  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) =>
      _fail('getCurrentPosition');
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      _fail('getPositionStream');
  @override
  Stream<ServiceStatus> getServiceStatusStream() =>
      _fail('getServiceStatusStream');
  @override
  Future<LocationAccuracyStatus> getLocationAccuracy() =>
      _fail('getLocationAccuracy');
  @override
  Future<LocationAccuracyStatus> requestTemporaryFullAccuracy({
    required String purposeKey,
  }) => _fail('requestTemporaryFullAccuracy');
  @override
  Future<bool> openAppSettings() => _fail('openAppSettings');
  @override
  Future<bool> openLocationSettings() => _fail('openLocationSettings');
}

Object? json(Position? p) => p == null ? null : PositionJson.encode(p);

GeolocatorPlatform get platform => GeolocatorPlatform.instance;

void main() {
  final original = GeolocatorPlatform.instance;
  late List<ThrowingGeolocatorPlatform> throwing;
  late List<BugCapsuleGeolocator> adapters;

  setUp(() {
    throwing = [];
    adapters = [];
  });
  tearDown(() {
    for (final a in adapters.reversed) {
      a.uninstall();
    }
    GeolocatorPlatform.instance = original;
  });

  Future<AdapterConformanceResult> conform(
    FutureOr<Object?> Function(BugCapsuleGeolocator adapter) scenario, {
    FakeGeolocatorPlatform? fake,
  }) => AdapterConformance.run(
    create: (replaying) {
      final GeolocatorPlatform p;
      if (replaying) {
        final t = ThrowingGeolocatorPlatform();
        throwing.add(t);
        p = t;
      } else {
        p = fake ?? FakeGeolocatorPlatform();
      }
      final a = BugCapsuleGeolocator(platform: p);
      adapters.add(a);
      return a;
    },
    scenario: scenario,
  );

  void expectClean(AdapterConformanceResult r) {
    expect(r.problems, isEmpty);
    expect(throwing.single.calls, 0, reason: 'replay reached the platform');
    expect(r.dependencies.single.adapter, 'bug_capsule.geolocator');
  }

  group('conformance through GeolocatorPlatform.instance', () {
    test('checkPermission', () async {
      final r = await conform(
        (_) async => (await platform.checkPermission()).name,
      );
      expectClean(r);
      expect(r.replayed, 'denied');
    });

    test('requestPermission', () async {
      final r = await conform(
        (_) async => [
          (await platform.checkPermission()).name,
          (await platform.requestPermission()).name,
          (await platform.checkPermission()).name,
        ],
      );
      expectClean(r);
      expect(r.replayed, ['denied', 'whileInUse', 'whileInUse']);
    });

    test('isLocationServiceEnabled', () async {
      final r = await conform(
        (_) async => platform.isLocationServiceEnabled(),
        fake: FakeGeolocatorPlatform()..serviceEnabled = false,
      );
      expectClean(r);
      expect(r.replayed, false);
    });

    test('getCurrentPosition', () async {
      final r = await conform(
        (_) async => [
          json(await platform.getCurrentPosition()),
          json(
            await platform.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 5,
                timeLimit: Duration(seconds: 10),
              ),
            ),
          ),
        ],
      );
      expectClean(r);
      final args = r.events
          .where((e) => e.type == 'native.call')
          .map((e) => (e.data['args'] as Map)['value'])
          .toList();
      expect(args[1], {
        'type': 'LocationSettings',
        'accuracy': 'high',
        'distanceFilter': 5,
        'timeLimitUs': 10000000,
      });
    });

    test('getLastKnownPosition', () async {
      final r = await conform(
        (_) async => [
          json(await platform.getLastKnownPosition()),
          json(await platform.getLastKnownPosition(forceLocationManager: true)),
        ],
      );
      expectClean(r);
      expect((r.replayed! as List)[1], isNull);
    });

    test('getPositionStream', () async {
      final r = await conform((_) async {
        final fixes = await platform.getPositionStream().toList();
        return [for (final p in fixes) json(p)];
      });
      expectClean(r);
      expect(r.events.map((e) => e.type), [
        'native.subscribe',
        'native.event',
        'native.event',
        'native.event',
        'native.done',
      ]);
    });

    test('getServiceStatusStream', () async {
      final r = await conform(
        (_) async => [
          for (final s in await platform.getServiceStatusStream().toList())
            s.name,
        ],
      );
      expectClean(r);
      expect(r.replayed, ['disabled', 'enabled']);
    });
  });

  test('positions round-trip losslessly', () async {
    final r = await conform((_) async {
      final p = await platform.getCurrentPosition();
      return [
        p == fix(59.9139, 10.7522),
        p.timestamp.isUtc,
        p.timestamp.microsecond,
        p.heading.isNegative,
        p.speed.runtimeType.toString(),
        p.floor,
        p.hasHeading,
      ];
    });
    expectClean(r);
    expect(r.replayed, [true, true, 456, true, 'double', 2, false]);
  });

  test('platform errors replay as geolocator exceptions', () async {
    final r = await conform(
      (_) async {
        final out = <Object?>[];
        for (var i = 0; i < 2; i++) {
          try {
            await platform.getCurrentPosition();
          } on LocationServiceDisabledException {
            out.add('serviceDisabled');
          } on TimeoutException catch (e) {
            out.add(['timeout', e.duration?.inSeconds]);
          }
        }
        return out;
      },
      fake: _ErrorSequence([
        const LocationServiceDisabledException(),
        TimeoutException('no fix', const Duration(seconds: 5)),
      ]),
    );
    expectClean(r);
    expect(r.replayed, [
      'serviceDisabled',
      ['timeout', 5],
    ]);
  });

  test('cancelling the position stream records native.cancel', () async {
    final r = await conform((_) async {
      final first = await platform.getPositionStream().first;
      return json(first);
    });
    expectClean(r);
    expect(r.events.map((e) => e.type), [
      'native.subscribe',
      'native.event',
      'native.cancel',
    ]);
  });

  group('unsupported operations', () {
    test('capture delegates and records a gap', () async {
      final fake = FakeGeolocatorPlatform();
      final capture = InteractionHarness.capture();
      final a = BugCapsuleGeolocator(platform: fake);
      adapters.add(a);
      await capture.setUp([a]);
      await platform.checkPermission();
      expect(
        await platform.getLocationAccuracy(),
        LocationAccuracyStatus.precise,
      );
      expect(await platform.openAppSettings(), isTrue);
      expect(fake.calls, [
        'checkPermission',
        'getLocationAccuracy',
        'openAppSettings',
      ]);
      final dep = capture.dependencies().single;
      expect(dep.coverage, DependencyCoverage.partial);
      expect(dep.gaps.single.code, DependencyGaps.operationUnsupported);
      expect(dep.gaps.single.count, 2);
      expect(
        capture.eligibility().missing.map((m) => m.dependency),
        contains('dependency.geolocator'),
      );
    });

    test('replay fails them explicitly without calling the platform', () async {
      final capture = InteractionHarness.capture();
      final a = BugCapsuleGeolocator(platform: FakeGeolocatorPlatform());
      adapters.add(a);
      await capture.setUp([a]);
      await platform.checkPermission();

      final replay = InteractionHarness.replay(
        capture.encodedEvents(),
        dependencies: capture.dependencies(),
      );
      final t = ThrowingGeolocatorPlatform();
      final b = BugCapsuleGeolocator(platform: t);
      adapters.add(b);
      await replay.setUp([b]);
      expect(await platform.checkPermission(), LocationPermission.denied);
      await expectLater(
        platform.getLocationAccuracy(),
        throwsA(
          isA<NativeAdapterException>().having(
            (e) => e.code,
            'code',
            'bugcapsule.unsupported',
          ),
        ),
      );
      await expectLater(
        platform.openLocationSettings(),
        throwsA(isA<NativeAdapterException>()),
      );
      // Pure Dart helpers still work.
      expect(platform.distanceBetween(0, 0, 0, 1), closeTo(111319, 1));
      expect(t.calls, 0);
      expect(replay.finish().map((d) => d.type), [
        'native.unrecorded',
        'native.unrecorded',
      ]);
    });
  });

  test('an unrecorded call diverges and never reaches the platform', () async {
    final r = await conform((_) async {
      await platform.checkPermission();
      return 'ok';
    });
    expect(r.problems, isEmpty);
    final replay = InteractionHarness.replay([
      for (final e in r.events) e,
    ], dependencies: r.dependencies);
    final t = ThrowingGeolocatorPlatform();
    final a = BugCapsuleGeolocator(platform: t);
    adapters.add(a);
    await replay.setUp([a]);
    await platform.checkPermission();
    await expectLater(
      platform.getCurrentPosition(),
      throwsA(
        isA<NativeAdapterException>().having(
          (e) => e.code,
          'code',
          'bugcapsule.unrecorded',
        ),
      ),
    );
    expect(t.calls, 0);
    expect(replay.finish().map((d) => d.type), ['native.unrecorded']);
  });

  test(
    'replay without a location recording never calls the platform',
    () async {
      final replay = InteractionHarness.replay(
        const [],
        dependencies: const [],
      );
      final t = ThrowingGeolocatorPlatform();
      final a = BugCapsuleGeolocator(platform: t);
      adapters.add(a);
      await replay.setUp([a]);
      await expectLater(
        platform.checkPermission(),
        throwsA(isA<NativeAdapterException>()),
      );
      await expectLater(
        platform.getPositionStream().first,
        throwsA(isA<NativeAdapterException>()),
      );
      expect(t.calls, 0);
      expect(replay.finish().map((d) => d.type).toSet(), {'native.unrecorded'});
    },
  );

  test(
    'install wraps the registered platform and uninstall restores it',
    () async {
      final fake = FakeGeolocatorPlatform();
      GeolocatorPlatform.instance = fake;
      final a = BugCapsuleGeolocator();
      adapters.add(a);
      await InteractionHarness.capture().setUp([a]);
      expect(GeolocatorPlatform.instance, isNot(same(fake)));
      expect(a.delegate, same(fake));
      a.install();
      expect(a.delegate, same(fake), reason: 'install is idempotent');
      a.uninstall();
      expect(GeolocatorPlatform.instance, same(fake));
    },
  );
}

class _ErrorSequence extends FakeGeolocatorPlatform {
  _ErrorSequence(this.errors);

  final List<Object> errors;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) {
    currentError = errors.removeAt(0);
    return super.getCurrentPosition(locationSettings: locationSettings);
  }
}
