/// GoRouter integration for Repro: records navigation and restores the
/// route of a periodic checkpoint in replay.
///
/// ```dart
/// final reproRouter = ReproGoRouter();
/// final router = GoRouter(
///   initialLocation: reproRouter.initialLocation('/'),
///   routes: [...],
/// );
/// // after creating the router:
/// reproRouter.attach(router);
/// ```
library;

import 'package:go_router/go_router.dart';
import 'package:repro_flutter/repro_flutter.dart';

class ReproGoRouter extends ReproIntegration {
  GoRouter? _router;
  ReproSession? _session;
  String? _restoredLocation;
  String? _lastLocation;
  bool _sawExtra = false;

  @override
  String get name => 'go_router';

  @override
  Future<void> setUp(ReproSession session) async => _session = session;

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
    if (session == null || !session.isRecording) return;
    session.record(EventTypes.route, {
      'location': session.redactor.redactUri(Uri.parse(location)).toString(),
      if (config.extra != null) 'extra': config.extra.runtimeType.toString(),
    });
  }

  @override
  Object? snapshot(CheckpointKind kind) {
    final config = _router?.routerDelegate.currentConfiguration;
    if (config == null || config.isEmpty) return null;
    return {
      'location': config.uri.toString(),
      'hasExtra': config.extra != null,
    };
  }

  @override
  Future<void> restore(Object? data, ReproSession session) async {
    if (data is Map && data['location'] is String) {
      _restoredLocation = data['location'] as String;
      if (data['hasExtra'] == true) {
        session.replay?.diverge('route.extra', 'route extra object at $_restoredLocation is not restored');
      }
    }
  }

  @override
  void describeEligibility(EligibilityBuilder eligibility, RecordedWindow window) {
    if (window.checkpoint.kind == CheckpointKind.periodic && _sawExtra) {
      eligibility.missing('route.extra', 'navigation used GoRouter `extra` objects, which are not restored');
    }
  }
}
