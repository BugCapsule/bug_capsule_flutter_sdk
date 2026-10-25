import 'dart:collection';

import '../../core/core.dart';

/// Breadcrumbs derived from flight-recorder events (route, action, http,
/// lifecycle, log, state, failure), so no integration is instrumented twice.
abstract final class BreadcrumbMapper {
  static const _state = {
    EventTypes.blocCreate,
    EventTypes.blocClose,
    EventTypes.blocEvent,
    EventTypes.blocState,
    EventTypes.blocError,
    EventTypes.riverpodAdd,
    EventTypes.riverpodUpdate,
    EventTypes.riverpodError,
    EventTypes.riverpodDispose,
    EventTypes.notifierCreate,
    EventTypes.notifierChange,
    EventTypes.getxCreate,
    EventTypes.getxChange,
    EventTypes.mobxCreate,
    EventTypes.mobxChange,
    EventTypes.mobxObservable,
    EventTypes.mobxAction,
    EventTypes.mobxError,
  };

  /// Whether events of [type] become breadcrumbs (pointer and text events
  /// do not: too many, and typed text is personal).
  static bool wants(String type) =>
      type == EventTypes.route ||
      type == EventTypes.action ||
      type == EventTypes.http ||
      type == EventTypes.lifecycle ||
      type == EventTypes.log ||
      type == EventTypes.failure ||
      _state.contains(type);

  /// [data] is already redacted by the recorder's sanitizer.
  static Breadcrumb? fromEvent(
    String type,
    Map<String, Object?> data, {
    String? previousRoute,
  }) {
    switch (type) {
      case EventTypes.route:
        return Breadcrumb(
          type: BreadcrumbType.navigation,
          category: 'navigation',
          data: {'from': ?previousRoute, 'to': data['location']},
        );
      case EventTypes.action:
        return Breadcrumb(
          type: BreadcrumbType.user,
          category: 'ui.action',
          message: '${data['id']}',
        );
      case EventTypes.http:
        return http(
          method: '${data['method']}',
          url: '${data['url']}',
          status: data['status'] as int?,
          durationMs: data['durationMs'] as int?,
          error: (data['error'] as Map?)?['type'] as String?,
        );
      case EventTypes.lifecycle:
        return Breadcrumb(
          category: 'app.lifecycle',
          data: {'state': data['state']},
        );
      case EventTypes.log:
        return Breadcrumb(
          type: BreadcrumbType.debug,
          category: 'log',
          message: '${data['message']}',
          level: _level('${data['level']}'),
        );
      case EventTypes.failure:
        return Breadcrumb(
          type: BreadcrumbType.error,
          category: 'error',
          message: '${data['type']}: ${data['message']}',
          level: EventLevel.error,
        );
    }
    if (_state.contains(type)) {
      return Breadcrumb(
        type: BreadcrumbType.state,
        category: type,
        data: _scalars(data),
      );
    }
    return null;
  }

  static Breadcrumb http({
    required String method,
    required String url,
    int? status,
    int? durationMs,
    String? error,
  }) => Breadcrumb(
    type: BreadcrumbType.http,
    category: 'http',
    level: status == null || status == 0 || status >= 500
        ? EventLevel.error
        : status >= 400
        ? EventLevel.warning
        : EventLevel.info,
    data: {
      'method': method,
      'url': url,
      if (status != null && status > 0) 'status_code': status,
      'duration_ms': ?durationMs,
      'error': ?error,
    },
  );

  static EventLevel _level(String level) => switch (level) {
    'error' || 'severe' || 'shout' => EventLevel.error,
    'warning' || 'warn' => EventLevel.warning,
    'debug' ||
    'fine' ||
    'finer' ||
    'finest' ||
    'trace' ||
    'verbose' => EventLevel.debug,
    _ => EventLevel.info,
  };

  /// Names and short values only: state payloads can be large.
  static Map<String, Object?> _scalars(Map<String, Object?> data) => {
    for (final e in data.entries.take(10))
      if (e.value is num || e.value is bool)
        e.key: e.value
      else if (e.value is String)
        e.key: cut(e.value! as String, 200),
  };
}

/// Ring of the most recent breadcrumbs, oldest first.
class BreadcrumbBuffer {
  BreadcrumbBuffer(this.max);

  int max;
  final ListQueue<Breadcrumb> _items = ListQueue();

  void add(Breadcrumb b) {
    if (max <= 0) return;
    _items.addLast(b);
    while (_items.length > max) {
      _items.removeFirst();
    }
  }

  void clear() => _items.clear();
  List<Breadcrumb> snapshot() => List.of(_items);
}
