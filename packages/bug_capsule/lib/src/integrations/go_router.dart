/// GoRouter integration for BugCapsule: records navigation and restores the
/// route of a periodic checkpoint in replay.
///
/// ```dart
/// final bugCapsuleRouter = BugCapsuleGoRouter();
/// final router = GoRouter(
///   initialLocation: bugCapsuleRouter.initialLocation('/'),
///   routes: [...],
/// );
/// // after creating the router:
/// bugCapsuleRouter.attach(router);
/// ```
///
/// Locations are redacted the same way in `route` events and in checkpoint
/// snapshots: sensitive query and fragment parameters are replaced (see
/// `Redactor.redactUri`). Secrets in path segments (`/reset/<token>`) need
/// [BugCapsuleGoRouter.sanitizeLocation].
library;

import 'package:go_router/go_router.dart';
import '../runtime/monitoring/hub.dart';
import '../runtime/runtime.dart';

class BugCapsuleGoRouter extends BugCapsuleIntegration {
  /// [sanitizeLocation] runs after built-in redaction, for events and
  /// checkpoints alike, e.g. `(l) => l.replaceAll(RegExp(r'/reset/[^/?]+'), '/reset/:token')`.
  BugCapsuleGoRouter({this.sanitizeLocation});

  final String Function(String location)? sanitizeLocation;

  GoRouter? _router;
  BugCapsuleSession? _session;
  String? _restoredLocation;
  String? _lastLocation;
  bool _sawExtra = false;

  @override
  String get name => 'go_router';

  @override
  Future<void> setUp(BugCapsuleSession session) async => _session = session;

  /// The location the router should start at: the checkpoint route during
  /// replay from a periodic checkpoint, otherwise [fallback].
  String initialLocation(String fallback) => _restoredLocation ?? fallback;

  void attach(GoRouter router) {
    _router?.routerDelegate.removeListener(_onRouteChanged);
    _router = router;
    router.routerDelegate.addListener(_onRouteChanged);
  }

  void _onRouteChanged() {
    final config = _router?.routerDelegate.currentConfiguration;
    if (config == null || config.isEmpty) return;
    final location = config.uri.toString();
    if (location == _lastLocation) return;
    _lastLocation = location;
    if (config.extra != null) _sawExtra = true;
    final session = _session;
    final hub = MonitoringHub.current;
    if (hub != null && session?.replay == null) {
      try {
        // Named after the route pattern (`/product/:id`), never the location.
        hub.onNavigation(
          config.fullPath.isNotEmpty ? config.fullPath : config.uri.path,
        );
        // A recording session derives the breadcrumb from the route event.
        if (session == null || !session.isRecording) {
          hub.navigationBreadcrumb(
            session == null ? location : _redact(session, config.uri),
          );
        }
      } catch (_) {
        // Monitoring never breaks navigation.
      }
    }
    if (session == null || !session.isRecording) return;
    session.record(EventTypes.route, {
      'location': _redact(session, config.uri),
      if (config.extra != null) 'extra': config.extra.runtimeType.toString(),
    });
  }

  /// One redaction path for events and checkpoints.
  String _redact(BugCapsuleSession session, Uri uri) {
    final location = session.redactor.redactUri(uri).toString();
    return sanitizeLocation?.call(location) ?? location;
  }

  @override
  Object? snapshot(CheckpointKind kind) {
    final config = _router?.routerDelegate.currentConfiguration;
    final session = _session;
    if (config == null || config.isEmpty || session == null) return null;
    return {
      'location': _redact(session, config.uri),
      'hasExtra': config.extra != null,
    };
  }

  @override
  Future<void> restore(Object? data, BugCapsuleSession session) async {
    if (data is Map && data['location'] is String) {
      _restoredLocation = data['location'] as String;
      if (_restoredLocation!.contains(Redactor.placeholder) ||
          _restoredLocation!.contains(
            Uri.encodeQueryComponent(Redactor.placeholder),
          )) {
        session.replay?.diverge(
          'route.redacted',
          'restored location has redacted parameters',
        );
      }
      if (data['hasExtra'] == true) {
        session.replay?.diverge(
          'route.extra',
          'route extra object at $_restoredLocation is not restored',
        );
      }
    }
  }

  @override
  void describeEligibility(
    EligibilityBuilder eligibility,
    RecordedWindow window,
  ) {
    if (window.checkpoint.kind == CheckpointKind.periodic && _sawExtra) {
      eligibility.missing(
        'route.extra',
        'navigation used GoRouter `extra` objects, which are not restored',
      );
    }
  }
}
