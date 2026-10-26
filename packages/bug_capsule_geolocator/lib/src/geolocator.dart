import 'dart:async';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

const bugCapsuleGeolocatorVersion = '0.1.0-dev.1';

/// Location adapter (`bug_capsule.geolocator`, capsule-v2 `native`) on the
/// `geolocator_platform_interface` boundary.
///
/// [setUp] (run by `BugCapsule.init`) installs a delegating
/// [GeolocatorPlatform.instance], so app code keeps calling `Geolocator.*`.
/// While capturing, recorded operations reach the real platform and their
/// results (permissions, service state, positions, errors) are recorded;
/// during replay they are served from the capsule and the real platform is
/// never called.
///
/// ```dart
/// await BugCapsule.init(integrations: [BugCapsuleGeolocator(), ...]);
/// final position = await Geolocator.getCurrentPosition();
/// ```
///
/// Operations outside [supportedOperations] (accuracy status, settings
/// pages) still reach the platform while capturing and add an
/// `operation.unsupported` gap; during replay they fail with a
/// [NativeAdapterException] (`bugcapsule.unsupported`) and a
/// `native.unrecorded` divergence. `distanceBetween` and `bearingBetween`
/// are pure Dart and always work.
class BugCapsuleGeolocator extends NativeAdapter {
  /// Wraps [platform], or the [GeolocatorPlatform.instance] registered when
  /// [setUp] runs.
  BugCapsuleGeolocator({GeolocatorPlatform? platform}) : _delegate = platform;

  GeolocatorPlatform? _delegate;
  _BugCapsuleGeolocatorPlatform? _installed;

  /// The platform implementation calls reach while capturing.
  GeolocatorPlatform get delegate =>
      _delegate ??= _unwrap(GeolocatorPlatform.instance);

  @override
  String get name => 'geolocator';

  @override
  String get adapter => 'bug_capsule.geolocator';

  @override
  String get adapterVersion => bugCapsuleGeolocatorVersion;

  static const supportedOperations = [
    'checkPermission',
    'requestPermission',
    'isLocationServiceEnabled',
    'getCurrentPosition',
    'getLastKnownPosition',
    'getPositionStream',
    'getServiceStatusStream',
  ];

  @override
  List<String> get operations => supportedOperations;

  @override
  Map<String, String> get tested => const {
    'geolocator_platform_interface': '4.4.1',
  };

  @override
  Future<void> setUp(BugCapsuleSession session) async {
    await super.setUp(session);
    install();
  }

  /// Installs the delegating [GeolocatorPlatform.instance] (idempotent).
  void install() {
    delegate;
    final current = GeolocatorPlatform.instance;
    if (identical(current, _installed)) return;
    GeolocatorPlatform.instance = _installed = _BugCapsuleGeolocatorPlatform(
      this,
    );
  }

  /// Puts [delegate] back as [GeolocatorPlatform.instance].
  void uninstall() {
    if (identical(GeolocatorPlatform.instance, _installed)) {
      GeolocatorPlatform.instance = delegate;
    }
    _installed = null;
  }

  static GeolocatorPlatform _unwrap(GeolocatorPlatform p) =>
      p is _BugCapsuleGeolocatorPlatform ? p._owner.delegate : p;

  @override
  (String, String?, Object?) describeError(Object error) {
    final (code, message, details) = switch (error) {
      PermissionDeniedException(:final message) => (
        'permissionDenied',
        message,
        null,
      ),
      LocationServiceDisabledException() => (
        'locationServiceDisabled',
        null,
        null,
      ),
      PermissionDefinitionsNotFoundException(:final message) => (
        'permissionDefinitionsNotFound',
        message,
        null,
      ),
      PermissionRequestInProgressException(:final message) => (
        'permissionRequestInProgress',
        message,
        null,
      ),
      PositionUpdateException(:final message) => (
        'positionUpdate',
        message,
        null,
      ),
      ActivityMissingException(:final message) => (
        'activityMissing',
        message,
        null,
      ),
      AlreadySubscribedException() => ('alreadySubscribed', null, null),
      InvalidPermissionException(:final valueToConvert) => (
        'invalidPermission',
        null,
        {'value': valueToConvert},
      ),
      TimeoutException(:final message, :final duration) => (
        'timeout',
        message,
        {'us': ?duration?.inMicroseconds},
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
  Object rebuildError(String code, String? message, Object? details) {
    final d = details is Map ? details : const {};
    return switch (code) {
      'permissionDenied' => PermissionDeniedException(message),
      'locationServiceDisabled' => const LocationServiceDisabledException(),
      'permissionDefinitionsNotFound' => PermissionDefinitionsNotFoundException(
        message,
      ),
      'permissionRequestInProgress' => PermissionRequestInProgressException(
        message,
      ),
      'positionUpdate' => PositionUpdateException(message),
      'activityMissing' => ActivityMissingException(message),
      'alreadySubscribed' => const AlreadySubscribedException(),
      'invalidPermission' => InvalidPermissionException(
        (d['value'] as num?)?.toInt() ?? -1,
      ),
      'timeout' => TimeoutException(
        message,
        d['us'] == null
            ? null
            : Duration(microseconds: (d['us'] as num).toInt()),
      ),
      _ => super.rebuildError(code, message, details),
    };
  }

  // ------------------------------------------------------------ operations

  /// Replaying a capsule without this adapter's recording: nothing may reach
  /// the platform.
  bool get _unserved => session?.replay != null && replayInteractions == null;

  bool get _replaying => session?.replay != null;

  NativeAdapterException _fail(String code, String operation, String why) {
    diverge('native.unrecorded', '$adapter $operation: $why');
    return NativeAdapterException(code, '$operation: $why');
  }

  Future<T> _call<T>(
    String operation, {
    Object? args,
    required Future<T> Function() invoke,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) {
    if (_unserved) {
      return Future.error(
        _fail(
          'bugcapsule.unrecorded',
          operation,
          'the capsule has no recording of this adapter',
        ),
      );
    }
    return call(
      operation,
      args: args,
      invoke: invoke,
      encode: encode,
      decode: decode,
    );
  }

  Stream<T> _subscribe<T>(
    String operation, {
    Object? args,
    required Stream<T> Function() open,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) {
    if (_unserved) {
      return Stream.multi((c) {
        c
          ..addError(
            _fail(
              'bugcapsule.unrecorded',
              operation,
              'the capsule has no recording of this adapter',
            ),
          )
          ..close();
      });
    }
    return subscribe(
      operation,
      args: args,
      open: open,
      encode: encode,
      decode: decode,
    );
  }

  /// An operation this adapter does not record: the platform while
  /// capturing (with a gap), an explicit failure during replay.
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

  static Object? _permission(LocationPermission p) => p.name;
  static LocationPermission _readPermission(Object? json) =>
      LocationPermission.values.byName(json! as String);

  Future<LocationPermission> checkPermission() => _call(
    'checkPermission',
    invoke: delegate.checkPermission,
    encode: _permission,
    decode: _readPermission,
  );

  Future<LocationPermission> requestPermission() => _call(
    'requestPermission',
    invoke: delegate.requestPermission,
    encode: _permission,
    decode: _readPermission,
  );

  Future<bool> isLocationServiceEnabled() => _call(
    'isLocationServiceEnabled',
    invoke: delegate.isLocationServiceEnabled,
    encode: (v) => v,
    decode: (json) => json! as bool,
  );

  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) =>
      _call(
        'getLastKnownPosition',
        args: {'forceLocationManager': forceLocationManager},
        invoke: () => delegate.getLastKnownPosition(
          forceLocationManager: forceLocationManager,
        ),
        encode: (p) => p == null ? null : PositionJson.encode(p),
        decode: (json) => json == null ? null : PositionJson.decode(json),
      );

  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) =>
      _call(
        'getCurrentPosition',
        args: settingsJson(locationSettings),
        invoke: () =>
            delegate.getCurrentPosition(locationSettings: locationSettings),
        encode: PositionJson.encode,
        decode: PositionJson.decode,
      );

  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      _subscribe(
        'getPositionStream',
        args: settingsJson(locationSettings),
        open: () =>
            delegate.getPositionStream(locationSettings: locationSettings),
        encode: PositionJson.encode,
        decode: PositionJson.decode,
      );

  Stream<ServiceStatus> getServiceStatusStream() => _subscribe(
    'getServiceStatusStream',
    open: delegate.getServiceStatusStream,
    encode: (s) => s.name,
    decode: (json) => ServiceStatus.values.byName(json! as String),
  );

  /// The recorded (and matched) form of [settings]: platform subclasses
  /// (`AndroidSettings`, `AppleSettings`) contribute their own fields.
  static Map<String, Object?>? settingsJson(LocationSettings? settings) {
    if (settings == null) return null;
    Map<String, Object?> json;
    try {
      json = Map<String, Object?>.of(settings.toJson());
    } catch (_) {
      json = {};
    }
    return {
      'type': '${settings.runtimeType}',
      ...json,
      'accuracy': settings.accuracy.name,
      'distanceFilter': settings.distanceFilter,
      'timeLimitUs': ?settings.timeLimit?.inMicroseconds,
    };
  }
}

/// Lossless JSON for [Position]: every field, the timestamp in
/// microseconds with its UTC flag.
abstract final class PositionJson {
  static Map<String, Object?> encode(Position p) => {
    'lat': p.latitude,
    'lng': p.longitude,
    'ts': p.timestamp.microsecondsSinceEpoch,
    'utc': p.timestamp.isUtc,
    'accuracy': p.accuracy,
    'altitude': p.altitude,
    'altitudeAccuracy': p.altitudeAccuracy,
    'heading': p.heading,
    'headingAccuracy': p.headingAccuracy,
    'speed': p.speed,
    'speedAccuracy': p.speedAccuracy,
    'verticalSpeed': p.verticalSpeed,
    'verticalSpeedAccuracy': p.verticalSpeedAccuracy,
    'floor': p.floor,
    'mocked': p.isMocked,
    'has': [
      p.hasAccuracy,
      p.hasAltitude,
      p.hasAltitudeAccuracy,
      p.hasHeading,
      p.hasHeadingAccuracy,
      p.hasSpeed,
      p.hasSpeedAccuracy,
      p.hasVerticalSpeed,
      p.hasVerticalSpeedAccuracy,
    ],
  };

  static Position decode(Object? json) {
    final m = json! as Map;
    double d(String k) => (m[k] as num).toDouble();
    final has = [for (final h in m['has'] as List) h == true];
    return Position(
      latitude: d('lat'),
      longitude: d('lng'),
      timestamp: DateTime.fromMicrosecondsSinceEpoch(
        (m['ts'] as num).toInt(),
        isUtc: m['utc'] == true,
      ),
      accuracy: d('accuracy'),
      altitude: d('altitude'),
      altitudeAccuracy: d('altitudeAccuracy'),
      heading: d('heading'),
      headingAccuracy: d('headingAccuracy'),
      speed: d('speed'),
      speedAccuracy: d('speedAccuracy'),
      verticalSpeed: d('verticalSpeed'),
      verticalSpeedAccuracy: d('verticalSpeedAccuracy'),
      floor: (m['floor'] as num?)?.toInt(),
      isMocked: m['mocked'] == true,
      hasAccuracy: has[0],
      hasAltitude: has[1],
      hasAltitudeAccuracy: has[2],
      hasHeading: has[3],
      hasHeadingAccuracy: has[4],
      hasSpeed: has[5],
      hasSpeedAccuracy: has[6],
      hasVerticalSpeed: has[7],
      hasVerticalSpeedAccuracy: has[8],
    );
  }
}

/// The [GeolocatorPlatform.instance] [BugCapsuleGeolocator] installs.
class _BugCapsuleGeolocatorPlatform extends GeolocatorPlatform {
  _BugCapsuleGeolocatorPlatform(this._owner);

  final BugCapsuleGeolocator _owner;

  @override
  Future<LocationPermission> checkPermission() => _owner.checkPermission();

  @override
  Future<LocationPermission> requestPermission() => _owner.requestPermission();

  @override
  Future<bool> isLocationServiceEnabled() => _owner.isLocationServiceEnabled();

  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) =>
      _owner.getLastKnownPosition(forceLocationManager: forceLocationManager);

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) =>
      _owner.getCurrentPosition(locationSettings: locationSettings);

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      _owner.getPositionStream(locationSettings: locationSettings);

  @override
  Stream<ServiceStatus> getServiceStatusStream() =>
      _owner.getServiceStatusStream();

  @override
  Future<LocationAccuracyStatus> requestTemporaryFullAccuracy({
    required String purposeKey,
  }) => _owner._unsupported(
    'requestTemporaryFullAccuracy',
    () => _owner.delegate.requestTemporaryFullAccuracy(purposeKey: purposeKey),
  );

  @override
  Future<LocationAccuracyStatus> getLocationAccuracy() => _owner._unsupported(
    'getLocationAccuracy',
    _owner.delegate.getLocationAccuracy,
  );

  @override
  Future<bool> openAppSettings() =>
      _owner._unsupported('openAppSettings', _owner.delegate.openAppSettings);

  @override
  Future<bool> openLocationSettings() => _owner._unsupported(
    'openLocationSettings',
    _owner.delegate.openLocationSettings,
  );
}
