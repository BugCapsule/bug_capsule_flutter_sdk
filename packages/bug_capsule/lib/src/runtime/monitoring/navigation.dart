import 'package:flutter/widgets.dart';

import 'hub.dart';

/// Screen transactions and navigation breadcrumbs for `Navigator` apps:
///
/// ```dart
/// MaterialApp(navigatorObservers: [BugCapsuleNavigatorObserver()], ...)
/// ```
///
/// Each page route that becomes visible starts a `navigation` transaction
/// named after the route (ids in path-like names become `:id`) and ends the
/// previous screen's. Dialogs and other popup routes are ignored. Apps using
/// `BugCapsuleGoRouter` get the same from it and do not need this observer.
class BugCapsuleNavigatorObserver extends NavigatorObserver {
  /// [routeName] names a route (default: `route.settings.name`; unnamed
  /// routes are skipped). Return a pattern, never ids.
  BugCapsuleNavigatorObserver({this.routeName});

  final String? Function(Route<dynamic> route)? routeName;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _changed(route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _changed(newRoute, oldRoute);

  /// Closing a dialog or popup returns to the same screen: not a navigation.
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _changed(previousRoute, route);
  }

  void _changed(Route<dynamic>? to, Route<dynamic>? from) {
    final hub = MonitoringHub.current;
    if (hub == null || to is! PageRoute) return;
    try {
      final name = _name(to);
      if (name == null) return;
      hub.navigationBreadcrumb(name, from: from == null ? null : _name(from));
      hub.onNavigation(name);
    } catch (_) {
      // Monitoring never breaks navigation.
    }
  }

  String? _name(Route<dynamic> route) =>
      routeName == null ? route.settings.name : routeName!(route);
}
