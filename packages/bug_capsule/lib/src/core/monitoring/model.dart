/// Monitoring payloads (monitoring-v1 §2, §9): error events, their
/// exceptions, frames and breadcrumbs. Mutable so `beforeSend` can edit an
/// event in place; [ErrorEvent.toJson] applies the contract's size bounds.
library;

enum EventLevel {
  fatal,
  error,
  warning,
  info,
  debug;

  static EventLevel? parse(Object? wire) {
    for (final l in values) {
      if (l.name == wire) return l;
    }
    return null;
  }
}

Map<String, Object?>? _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : null;

List<Map<String, Object?>> _maps(Object? v) => [
  if (v is List)
    for (final e in v)
      if (e is Map) e.cast<String, Object?>(),
];

String? _str(Object? v) => v is String ? v : null;

/// How an error was caught (`mechanism` in monitoring-v1 §2).
class Mechanism {
  const Mechanism(this.type, {required this.handled, this.data});

  final String type;
  final bool handled;
  final Map<String, Object?>? data;

  static const flutterError = Mechanism('flutter_error', handled: false);
  static const platformDispatcher = Mechanism(
    'platform_dispatcher',
    handled: false,
  );
  static const uncaught = Mechanism('uncaught', handled: false);
  static const manual = Mechanism('manual', handled: true);
  static const assertion = Mechanism('assertion', handled: true);
  static const logging = Mechanism('logging', handled: true);

  factory Mechanism.fromJson(Map<String, Object?> j) => Mechanism(
    _str(j['type']) ?? 'generic',
    handled: j['handled'] != false,
    data: _map(j['data']),
  );

  Map<String, Object?> toJson() => {
    'type': type,
    'handled': handled,
    'data': ?data,
  };
}

/// One stack frame. Frames are ordered oldest call first, crashing frame last.
class EventFrame {
  EventFrame({
    this.function,
    this.module,
    this.filename,
    this.absPath,
    this.lineno,
    this.colno,
    this.inApp,
    this.instructionAddr,
    this.imageAddr,
    this.package,
  });

  String? function;
  String? module;
  String? filename;
  String? absPath;
  int? lineno;
  int? colno;
  bool? inApp;
  String? instructionAddr;
  String? imageAddr;
  String? package;

  factory EventFrame.fromJson(Map<String, Object?> j) => EventFrame(
    function: _str(j['function']),
    module: _str(j['module']),
    filename: _str(j['filename']),
    absPath: _str(j['absPath']),
    lineno: (j['lineno'] as num?)?.toInt(),
    colno: (j['colno'] as num?)?.toInt(),
    inApp: j['inApp'] is bool ? j['inApp'] as bool : null,
    instructionAddr: _str(j['instructionAddr']),
    imageAddr: _str(j['imageAddr']),
    package: _str(j['package']),
  );

  Map<String, Object?> toJson() => {
    'function': ?function,
    'module': ?module,
    'filename': ?filename,
    'absPath': ?absPath,
    'lineno': ?lineno,
    'colno': ?colno,
    'inApp': ?inApp,
    'instructionAddr': ?instructionAddr,
    'imageAddr': ?imageAddr,
    'package': ?package,
  };
}

class ExceptionValue {
  ExceptionValue({
    required this.type,
    this.value,
    this.module,
    this.mechanism,
    List<EventFrame>? frames,
  }) : frames = frames ?? [];

  String type;
  String? value;
  String? module;
  Mechanism? mechanism;
  List<EventFrame> frames;

  factory ExceptionValue.fromJson(Map<String, Object?> j) => ExceptionValue(
    type: _str(j['type']) ?? 'Error',
    value: _str(j['value']),
    module: _str(j['module']),
    mechanism: _map(j['mechanism']) == null
        ? null
        : Mechanism.fromJson(_map(j['mechanism'])!),
    frames: [
      for (final f in _maps(_map(j['stacktrace'])?['frames']))
        EventFrame.fromJson(f),
    ],
  );

  Map<String, Object?> toJson() => {
    'type': cut(type, 200),
    if (value != null) 'value': cut(value!, 8192),
    if (module != null) 'module': cut(module!, 200),
    if (mechanism != null) 'mechanism': mechanism!.toJson(),
    if (frames.isNotEmpty)
      'stacktrace': {
        // Keep the frames closest to the crash.
        'frames': [
          for (final f
              in frames.length > 250
                  ? frames.sublist(frames.length - 250)
                  : frames)
            f.toJson(),
        ],
      },
  };
}

/// Breadcrumb `type`s of monitoring-v1 §2.
abstract final class BreadcrumbType {
  static const defaultType = 'default';
  static const http = 'http';
  static const navigation = 'navigation';
  static const user = 'user';
  static const ui = 'ui';
  static const error = 'error';
  static const debug = 'debug';
  static const info = 'info';
  static const query = 'query';
  static const state = 'state';
}

class Breadcrumb {
  Breadcrumb({
    DateTime? timestamp,
    this.type = BreadcrumbType.defaultType,
    this.category,
    this.message,
    this.level = EventLevel.info,
    this.data,
  }) : timestamp = timestamp ?? DateTime.now();

  DateTime timestamp;
  String type;
  String? category;
  String? message;
  EventLevel level;
  Map<String, Object?>? data;

  factory Breadcrumb.fromJson(Map<String, Object?> j) => Breadcrumb(
    timestamp: DateTime.tryParse('${j['timestamp']}'),
    type: _str(j['type']) ?? BreadcrumbType.defaultType,
    category: _str(j['category']),
    message: _str(j['message']),
    level: EventLevel.parse(j['level']) ?? EventLevel.info,
    data: _map(j['data']),
  );

  Map<String, Object?> toJson() => {
    'timestamp': isoTimestamp(timestamp),
    'type': type,
    'category': category,
    'message': message == null ? null : cut(message!, 8192),
    'level': level.name,
    'data': ?data,
  };
}

class MonitoringUser {
  const MonitoringUser({
    this.id,
    this.email,
    this.username,
    this.ipAddress,
    this.segment,
    this.data,
  });

  final String? id;
  final String? email;
  final String? username;

  /// `{{auto}}` lets the server fill it from the connection (kept only with
  /// the project's `storeIpAddresses`).
  final String? ipAddress;
  final String? segment;
  final Map<String, Object?>? data;

  factory MonitoringUser.fromJson(Map<String, Object?> j) => MonitoringUser(
    id: _str(j['id']),
    email: _str(j['email']),
    username: _str(j['username']),
    ipAddress: _str(j['ipAddress']),
    segment: _str(j['segment']),
    data: _map(j['data']),
  );

  Map<String, Object?> toJson() => {
    'id': ?id,
    'email': ?email,
    'username': ?username,
    'ipAddress': ?ipAddress,
    'segment': ?segment,
    'data': ?data,
  };
}

/// An `event` item: an error or a message.
class ErrorEvent {
  ErrorEvent({
    required this.eventId,
    required this.timestamp,
    this.level = EventLevel.error,
    List<ExceptionValue>? exceptions,
    this.message,
    this.fingerprint,
    Map<String, String>? tags,
    this.user,
    Map<String, Object?>? contexts,
    List<Breadcrumb>? breadcrumbs,
    List<Map<String, Object?>>? debugImages,
    this.request,
    Map<String, Object?>? extra,
    this.capsuleId,
    this.release,
    this.environment,
    this.threads,
  }) : exceptions = exceptions ?? [],
       tags = tags ?? {},
       contexts = contexts ?? {},
       breadcrumbs = breadcrumbs ?? [],
       debugImages = debugImages ?? [],
       extra = extra ?? {};

  final String eventId;
  DateTime timestamp;
  EventLevel level;

  /// Innermost cause first, the exception thrown last at the end.
  List<ExceptionValue> exceptions;
  String? message;
  List<String>? fingerprint;
  Map<String, String> tags;
  MonitoringUser? user;
  Map<String, Object?> contexts;
  List<Breadcrumb> breadcrumbs;
  List<Map<String, Object?>> debugImages;
  Map<String, Object?>? request;
  Map<String, Object?> extra;
  String? capsuleId;
  String? release;
  String? environment;

  /// `[{id, name, crashed, current, stacktrace}]`: the current stack of a
  /// `captureMessage` event (`attachStacktrace`), or a hang's threads.
  List<Map<String, Object?>>? threads;

  /// An event built elsewhere (a native SDK's crash report): every field
  /// [toJson] writes, so it goes through `beforeSend` like any other event.
  /// Null without an `eventId`.
  static ErrorEvent? fromJson(Map<String, Object?> j) {
    final id = _str(j['eventId']);
    if (id == null || id.isEmpty) return null;
    final message = j['message'];
    return ErrorEvent(
      eventId: id,
      timestamp: DateTime.tryParse('${j['timestamp']}') ?? DateTime.now(),
      level: EventLevel.parse(j['level']) ?? EventLevel.error,
      exceptions: [
        for (final v in _maps(_map(j['exception'])?['values']))
          ExceptionValue.fromJson(v),
      ],
      message: message is Map ? _str(message['formatted']) : _str(message),
      fingerprint: j['fingerprint'] is List
          ? [for (final f in j['fingerprint'] as List) '$f']
          : null,
      tags: {
        for (final e in (_map(j['tags']) ?? const {}).entries)
          if (e.value != null) e.key: '${e.value}',
      },
      user: _map(j['user']) == null
          ? null
          : MonitoringUser.fromJson(_map(j['user'])!),
      contexts: _map(j['contexts']),
      breadcrumbs: [
        for (final b in _maps(j['breadcrumbs'])) Breadcrumb.fromJson(b),
      ],
      debugImages: _maps(j['debugImages']),
      request: _map(j['request']),
      extra: _map(j['extra']),
      capsuleId: _str(j['capsuleId']),
      release: _str(j['release']),
      environment: _str(j['environment']),
      threads: j['threads'] is List ? _maps(j['threads']) : null,
    );
  }

  /// True when no exception value was caught by the app.
  bool get unhandled => exceptions.any((e) => e.mechanism?.handled == false);

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'timestamp': isoTimestamp(timestamp),
    'level': level.name,
    'runtime': 'flutter',
    'release': ?release,
    'environment': ?environment,
    if (exceptions.isNotEmpty)
      'exception': {
        'values': [
          for (final e
              in exceptions.length > 10
                  ? exceptions.sublist(exceptions.length - 10)
                  : exceptions)
            e.toJson(),
        ],
      },
    'message': message == null ? null : {'formatted': cut(message!, 8192)},
    'fingerprint': fingerprint == null
        ? null
        : [for (final f in fingerprint!.take(10)) cut(f, 200)],
    'tags': sanitizeTags(tags),
    if (user != null) 'user': user!.toJson(),
    'contexts': contexts,
    'breadcrumbs': [
      for (final b
          in breadcrumbs.length > 100
              ? breadcrumbs.sublist(breadcrumbs.length - 100)
              : breadcrumbs)
        b.toJson(),
    ],
    'debugImages': debugImages.take(500).toList(),
    'request': request,
    'extra': extra,
    'capsuleId': ?capsuleId,
    'threads': ?threads,
  };
}

String cut(String s, int max) => s.length <= max ? s : s.substring(0, max);

/// ISO-8601 in UTC with milliseconds (`2026-10-21T14:03:10.982Z`).
String isoTimestamp(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final ms = u.millisecond.toString().padLeft(3, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.${ms}Z';
}

final _tagKey = RegExp(r'^[A-Za-z0-9_.:-]{1,32}$');

/// At most 50 tags with valid keys; values cut to 200 characters.
Map<String, String> sanitizeTags(Map<String, String> tags) => {
  for (final e in tags.entries.where((e) => _tagKey.hasMatch(e.key)).take(50))
    e.key: cut(e.value, 200),
};
