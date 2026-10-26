import 'dart:collection';
import 'dart:convert';

import 'event.dart';
import 'network.dart' show canonicalJson, stableHash;
import 'redaction.dart';
import 'typed_value.dart';

/// Event types of the interaction families (capsule-v2 §4).
abstract final class InteractionTypes {
  static const wsConnect = 'ws.connect';
  static const wsOpen = 'ws.open';
  static const wsSend = 'ws.send';
  static const wsMessage = 'ws.message';
  static const wsError = 'ws.error';
  static const wsClose = 'ws.close';

  static const platformCall = 'platform.call';
  static const platformResult = 'platform.result';
  static const platformError = 'platform.error';
  static const platformListen = 'platform.listen';
  static const platformEvent = 'platform.event';
  static const platformCancel = 'platform.cancel';
  static const platformDone = 'platform.done';

  static const nativeCall = 'native.call';
  static const nativeResult = 'native.result';
  static const nativeError = 'native.error';
  static const nativeSubscribe = 'native.subscribe';
  static const nativeEvent = 'native.event';
  static const nativeCancel = 'native.cancel';
  static const nativeDone = 'native.done';

  /// Data fields that hold payload objects.
  static const payloadFields = {'payload', 'args', 'value', 'details'};

  /// `ws`, `platform` or `native` for an interaction event type, else null.
  static String? familyOf(String type) {
    if (type.startsWith('ws.')) return 'ws';
    if (type.startsWith('platform.')) return 'platform';
    if (type.startsWith('native.')) return 'native';
    return null;
  }

  static bool isInteraction(String type) => familyOf(type) != null;
}

/// `manifest.dependencies[].kind`.
abstract final class DependencyKinds {
  static const websocket = 'websocket';
  static const platformChannel = 'platform.channel';
  static const native = 'native';
}

/// Gap codes of capsule-v2 §7.
abstract final class DependencyGaps {
  static const payloadTruncated = 'payload.truncated';
  static const payloadDropped = 'payload.dropped';
  static const payloadBinaryMetadata = 'payload.binaryMetadata';
  static const payloadRedacted = 'payload.redacted';
  static const connectionsLimit = 'connections.limit';
  static const codecUnsupported = 'codec.unsupported';
  static const channelLate = 'channel.late';
  static const captureFailed = 'adapter.captureFailed';
  static const eventsDropped = 'events.dropped';

  /// The app used an operation the adapter does not record (it reached the
  /// real dependency while capturing and fails during replay).
  static const operationUnsupported = 'operation.unsupported';
}

class DependencyGap {
  const DependencyGap(this.code, {this.count, this.detail});

  factory DependencyGap.fromJson(Map<String, Object?> j) => DependencyGap(
    j['code'] as String,
    count: j['count'] as int?,
    detail: j['detail'] as String?,
  );

  final String code;
  final int? count;
  final String? detail;

  Map<String, Object?> toJson() => {
    'code': code,
    'count': ?count,
    'detail': ?detail,
  };
}

enum DependencyCoverage { complete, partial, diagnostic }

/// One entry of `manifest.dependencies` (capsule-v2 §2).
class CapsuleDependency {
  const CapsuleDependency({
    required this.id,
    required this.kind,
    required this.adapter,
    required this.adapterVersion,
    required this.schema,
    required this.required,
    required this.coverage,
    this.operations = const [],
    this.tested = const {},
    this.gaps = const [],
    this.stats = const {},
  });

  factory CapsuleDependency.fromJson(Map<String, Object?> j) =>
      CapsuleDependency(
        id: j['id'] as String,
        kind: j['kind'] as String,
        adapter: j['adapter'] as String,
        adapterVersion: j['adapterVersion'] as String,
        schema: j['schema'] as int,
        required: j['required'] as bool,
        coverage: DependencyCoverage.values.byName(j['coverage'] as String),
        operations: [
          for (final o in (j['operations'] as List?) ?? const []) '$o',
        ],
        tested: {
          for (final t in (j['tested'] as List?) ?? const [])
            '${(t as Map)['package']}': '${t['version']}',
        },
        gaps: [
          for (final g in (j['gaps'] as List?) ?? const [])
            DependencyGap.fromJson((g as Map).cast<String, Object?>()),
        ],
        stats: {
          for (final e in ((j['stats'] as Map?) ?? const {}).entries)
            if (e.value is int) '${e.key}': e.value as int,
        },
      );

  final String id;
  final String kind;
  final String adapter;
  final String adapterVersion;
  final int schema;
  final bool required;
  final DependencyCoverage coverage;
  final List<String> operations;

  /// Package -> version the adapter was qualified against.
  final Map<String, String> tested;
  final List<DependencyGap> gaps;
  final Map<String, int> stats;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'adapter': adapter,
    'adapterVersion': adapterVersion,
    'schema': schema,
    'required': required,
    'coverage': coverage.name,
    if (operations.isNotEmpty) 'operations': operations,
    if (tested.isNotEmpty)
      'tested': [
        for (final e in tested.entries) {'package': e.key, 'version': e.value},
      ],
    if (gaps.isNotEmpty) 'gaps': [for (final g in gaps) g.toJson()],
    if (stats.isNotEmpty) 'stats': stats,
  };
}

enum PayloadMode { full, redacted, metadata, omitted, truncated }

/// A payload object (capsule-v2 §3).
class InteractionPayload {
  const InteractionPayload({
    required this.mode,
    required this.replayable,
    this.value,
    this.bytes,
    this.kind,
  });

  factory InteractionPayload.fromJson(Map<String, Object?> j) =>
      InteractionPayload(
        mode: PayloadMode.values.byName(j['mode'] as String),
        replayable: j['replayable'] as bool,
        value: j['value'],
        bytes: j['bytes'] as int?,
        kind: j['kind'] as String?,
      );

  /// Null when [json] is not a payload object.
  static InteractionPayload? tryParse(Object? json) {
    if (json is! Map) return null;
    try {
      return InteractionPayload.fromJson(json.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  static const none = InteractionPayload(
    mode: PayloadMode.full,
    replayable: true,
  );

  final PayloadMode mode;
  final bool replayable;

  /// Typed-value JSON (see [TypedValue]).
  final Object? value;
  final int? bytes;

  /// `text`, `binary` or null (`value`).
  final String? kind;

  /// The Dart value replay hands the app.
  Object? get decoded => TypedValue.decode(value);

  /// Whether this recording and [other] carry the same value (canonical
  /// JSON), for mismatch checks. Non-replayable payloads compare by size.
  bool sameAs(InteractionPayload other) {
    if (!replayable || !other.replayable) {
      return bytes == other.bytes && kind == other.kind;
    }
    return canonicalJson(value) == canonicalJson(other.value);
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'replayable': replayable,
    if (replayable || value != null) 'value': value,
    'bytes': ?bytes,
    'kind': ?kind,
  };
}

/// Bounds of capsule-v2 §7.
class InteractionLimits {
  const InteractionLimits({
    this.maxPayloadBytes = 64 * 1024,
    this.maxWindowPayloadBytes = 1024 * 1024,
    this.maxActive = 32,
    this.windowMs = 5 * 60 * 1000,
  });

  /// Per payload (encoded JSON).
  final int maxPayloadBytes;

  /// Interaction payloads retained in the recorder window, all adapters.
  final int maxWindowPayloadBytes;

  /// Captured connections and subscriptions open at the same time.
  final int maxActive;

  /// Matches the flight recorder window: older payloads no longer count.
  final int windowMs;

  InteractionLimits lowered({int? maxPayloadBytes, int? maxWindowBytes}) =>
      InteractionLimits(
        maxPayloadBytes: _min(this.maxPayloadBytes, maxPayloadBytes),
        maxWindowPayloadBytes: _min(maxWindowPayloadBytes, maxWindowBytes),
        maxActive: maxActive,
        windowMs: windowMs,
      );

  static int _min(int a, int? b) => b == null || b > a ? a : b;
}

/// Shared payload byte budget of every adapter in a session: a rolling
/// window so a long session keeps recording recent traffic.
class PayloadBudget {
  PayloadBudget(this.limits);

  InteractionLimits limits;
  final ListQueue<(int, int)> _spent = ListQueue();
  int _total = 0;

  bool spend(int now, int bytes) {
    while (_spent.isNotEmpty && _spent.first.$1 < now - limits.windowMs) {
      _total -= _spent.removeFirst().$2;
    }
    if (_total + bytes > limits.maxWindowPayloadBytes) return false;
    _spent.addLast((now, bytes));
    _total += bytes;
    return true;
  }
}

/// Per-dependency capture bookkeeping: gaps and stats for the manifest.
class DependencyStats {
  int events = 0;
  int payloadBytes = 0;
  int dropped = 0;
  int truncated = 0;
  final Map<String, (int, String?)> _gaps = {};

  void gap(String code, [String? detail]) {
    final (n, d) = _gaps[code] ?? (0, detail);
    _gaps[code] = (n + 1, d ?? detail);
  }

  bool get hasGaps => _gaps.isNotEmpty;

  List<DependencyGap> get gaps => [
    for (final e in _gaps.entries)
      DependencyGap(e.key, count: e.value.$1, detail: e.value.$2),
  ];

  Map<String, int> toJson() => {
    'events': events,
    'payloadBytes': payloadBytes,
    'dropped': dropped,
    'truncated': truncated,
  };
}

/// Turns live values into payload objects: typed encoding, redaction,
/// binary policy, size limits and the shared budget.
class PayloadEncoder {
  PayloadEncoder({
    required this.redactor,
    required this.budget,
    required this.stats,
    required this.now,
    this.captureBinary = false,
    this.redactedReplayable = false,
  });

  final Redactor Function() redactor;
  final PayloadBudget budget;
  final DependencyStats stats;
  final int Function() now;

  /// Binary values (byte frames, typed arrays) are kept only when true;
  /// otherwise recorded as metadata.
  bool captureBinary;

  /// Whether a value the redactor changed can still be replayed (the app
  /// does not branch on the redacted fields).
  bool redactedReplayable;

  /// Encodes [value]. [kind] is `text`/`binary` for WebSocket frames.
  /// [redactedReplayable] overrides the encoder's setting for this payload
  /// (an adapter that knows the redacted fields are safe to replay).
  InteractionPayload encode(
    Object? value, {
    String? kind,
    bool? redactedReplayable,
  }) {
    final Object? typed;
    try {
      typed = value is String && kind == 'text'
          ? value
          : TypedValue.encode(value);
    } catch (_) {
      stats.gap(DependencyGaps.captureFailed, 'value could not be encoded');
      return InteractionPayload(
        mode: PayloadMode.omitted,
        replayable: false,
        kind: kind,
      );
    }
    final size = _size(value, typed);
    if (!captureBinary && (kind == 'binary' || TypedValue.hasBinary(typed))) {
      stats.gap(
        DependencyGaps.payloadBinaryMetadata,
        'binary data recorded as metadata; register a serializer to keep it',
      );
      return InteractionPayload(
        mode: PayloadMode.metadata,
        replayable: false,
        bytes: size,
        kind: kind,
      );
    }
    final (redacted, changed) = TypedValue.redact(typed, redactor());
    final encoded = jsonEncode(redacted);
    if (encoded.length > budget.limits.maxPayloadBytes) {
      stats
        ..truncated += 1
        ..gap(DependencyGaps.payloadTruncated);
      return InteractionPayload(
        mode: PayloadMode.truncated,
        replayable: false,
        bytes: size,
        kind: kind,
      );
    }
    if (!budget.spend(now(), encoded.length)) {
      stats
        ..dropped += 1
        ..gap(DependencyGaps.payloadDropped, 'capsule payload budget spent');
      return InteractionPayload(
        mode: PayloadMode.metadata,
        replayable: false,
        bytes: size,
        kind: kind,
      );
    }
    stats.payloadBytes += encoded.length;
    if (changed) stats.gap(DependencyGaps.payloadRedacted);
    final replayable =
        TypedValue.isReplayable(redacted) &&
        (!changed || (redactedReplayable ?? this.redactedReplayable));
    return InteractionPayload(
      mode: changed ? PayloadMode.redacted : PayloadMode.full,
      replayable: replayable,
      value: redacted,
      bytes: size,
      kind: kind,
    );
  }

  /// The match-key input for [value]: encoded and redacted like a payload,
  /// whatever the capture limits (so capture and replay agree).
  Object? keyInput(Object? value) {
    try {
      return TypedValue.redact(TypedValue.encode(value), redactor()).$1;
    } catch (_) {
      return '${value.runtimeType}';
    }
  }

  static int _size(Object? value, Object? typed) {
    if (value is String) return utf8.encode(value).length;
    if (value is List<int>) return value.length;
    try {
      return jsonEncode(typed).length;
    } catch (_) {
      return 0;
    }
  }
}

/// `<scope>|<method>|<hash of canonical args>` (capsule-v2 §5).
String interactionKey(String scope, String? method, Object? argsJson) =>
    '$scope|${method ?? ''}|${stableHash(canonicalJson(argsJson))}';

/// Counts occurrences per key on the capture side.
class OccurrenceCounter {
  final Map<String, int> _counts = {};

  int next(String key) {
    final n = _counts[key] ?? 0;
    _counts[key] = n + 1;
    return n;
  }
}

/// A recorded interaction event plus its scheduling metadata.
class RecordedInteraction {
  RecordedInteraction(this.event, this.scope, this.outbound);

  final BugCapsuleEvent event;
  final String scope;
  final bool outbound;

  /// For inbound events: the outbound event that releases it.
  RecordedInteraction? anchor;
  bool consumed = false;

  /// Replay-clock time this event was matched (outbound) or delivered.
  int? at;
  int? dueAt;

  String get type => event.type;
  String get family => InteractionTypes.familyOf(event.type)!;
  Map<String, Object?> get data => event.data;
  String get dep => data['dep'] as String;

  InteractionPayload? payload(String field) =>
      InteractionPayload.tryParse(data[field]);

  @override
  String toString() => '${event.type}#${event.seq}';
}

/// The scheduling scope and direction of an interaction event (§5): the
/// scope orders deliveries and is what an adapter binds a handler to.
(String, bool)? interactionScope(
  BugCapsuleEvent e,
  Map<String, String> callDirections,
) {
  final d = e.data;
  switch (e.type) {
    case InteractionTypes.wsConnect || InteractionTypes.wsSend:
      return ('ws:${d['conn']}', true);
    case InteractionTypes.wsClose:
      return ('ws:${d['conn']}', d['initiator'] == 'client');
    case InteractionTypes.wsOpen ||
        InteractionTypes.wsMessage ||
        InteractionTypes.wsError:
      return ('ws:${d['conn']}', false);
    case InteractionTypes.platformCall:
      return d['dir'] == 'platform'
          ? ('platform.in:${d['channel']}', false)
          : ('platform.call:${d['call']}', true);
    case InteractionTypes.platformResult || InteractionTypes.platformError:
      // The reply to a platform-to-Dart call is the app's own (outbound).
      final dir = callDirections['${d['call']}'];
      return ('platform.call:${d['call']}', dir == 'platform');
    case InteractionTypes.platformListen || InteractionTypes.platformCancel:
      return ('platform.sub:${d['sub']}', true);
    case InteractionTypes.platformEvent || InteractionTypes.platformDone:
      return ('platform.sub:${d['sub']}', false);
    case InteractionTypes.nativeCall:
      return ('native.op:${d['op']}', true);
    case InteractionTypes.nativeResult:
      return ('native.op:${d['op']}', false);
    case InteractionTypes.nativeError:
      return d['sub'] != null
          ? ('native.sub:${d['sub']}', false)
          : ('native.op:${d['op']}', false);
    case InteractionTypes.nativeSubscribe || InteractionTypes.nativeCancel:
      return ('native.sub:${d['sub']}', true);
    case InteractionTypes.nativeEvent || InteractionTypes.nativeDone:
      return ('native.sub:${d['sub']}', false);
  }
  return null;
}

/// Replay of interaction dependencies (capsule-v2 §5), without timers: the
/// runtime calls [pump] when [nextDueAt] arrives.
///
/// Adapters consume outbound expectations with [take] (keyed operations:
/// connects, calls, listens) or [takeNext] (ordered operations within a
/// scope: sends, cancels, replies), and [bind] a handler to a scope to
/// receive its inbound events. Each inbound event is released by its anchor
/// (the latest outbound event of its scope before it) and delivered
/// `t(inbound) - t(anchor)` after the anchor was matched; events without an
/// anchor follow the replay clock once [runStarted].
class InteractionScript {
  InteractionScript(
    Iterable<BugCapsuleEvent> events, {
    required Set<String> dependencies,
    required this.clock,
    this.base = 0,
    this.maxHandlerWaitMs = 5000,
  }) {
    final calls = <String, String>{};
    for (final e in events) {
      if (e.type == InteractionTypes.platformCall) {
        calls['${e.data['call']}'] = '${e.data['dir']}';
      }
    }
    final lastOutbound = <String, RecordedInteraction>{};
    for (final e in events) {
      if (!InteractionTypes.isInteraction(e.type)) continue;
      if (!dependencies.contains(e.data['dep'])) continue;
      if (e.data['diagnostic'] == true) continue;
      final scoped = interactionScope(e, calls);
      if (scoped == null) continue;
      final (scope, outbound) = scoped;
      final r = RecordedInteraction(e, scope, outbound);
      _all.add(r);
      final channelScope = e.type.startsWith('platform.')
          ? 'channel:${e.data['channel']}'
          : null;
      if (outbound) {
        lastOutbound[scope] = r;
        if (channelScope != null) lastOutbound[channelScope] = r;
        final key = e.data['key'];
        if (key is String) {
          (_keyed['${r.dep}|${e.type}|$key'] ??= ListQueue()).add(r);
        } else {
          (_ordered[scope] ??= []).add(r);
        }
      } else {
        r.anchor = e.type == InteractionTypes.platformCall
            ? lastOutbound[channelScope]
            : lastOutbound[scope];
        if (r.anchor == null) {
          _unanchored.add(r);
        } else {
          (_released[r.anchor!] ??= []).add(r);
        }
      }
    }
  }

  /// Replay clock in milliseconds (monotonic, includes skipped idle time).
  final int Function() clock;

  /// Recorded time replay starts from: 0 for a launch checkpoint, the
  /// checkpoint time for a periodic one.
  final int base;

  /// How long a due event may wait for its scope's handler.
  final int maxHandlerWaitMs;

  final List<RecordedInteraction> _all = [];
  final Map<String, ListQueue<RecordedInteraction>> _keyed = {};
  final Map<String, List<RecordedInteraction>> _ordered = {};
  final Map<RecordedInteraction, List<RecordedInteraction>> _released = {};
  final List<RecordedInteraction> _unanchored = [];
  final List<RecordedInteraction> _pending = [];
  final Map<String, void Function(RecordedInteraction)> _handlers = {};
  final Map<String, int> _lastDue = {};
  final List<(String, String)> _divergences = [];
  int? _runStart;

  /// Recorded interactions of [dependency] (for preflight and inspection).
  Iterable<RecordedInteraction> get all => _all;

  bool get isEmpty => _all.isEmpty;

  /// Divergences found while scheduling (undelivered events), drained by
  /// the runtime.
  List<(String, String)> takeDivergences() {
    final out = List.of(_divergences);
    _divergences.clear();
    return out;
  }

  /// Matches a keyed outbound operation (`ws.connect`, `platform.call`,
  /// `platform.listen`, `native.call`, `native.subscribe`) by key and
  /// invocation order. Null: nothing recorded (the caller reports
  /// `<family>.unrecorded` and fails the operation).
  RecordedInteraction? take(String dep, String type, String key) {
    final queue = _keyed['$dep|$type|$key'];
    if (queue == null) return null;
    while (queue.isNotEmpty) {
      final r = queue.removeFirst();
      if (r.consumed) continue;
      _consume(r);
      return r;
    }
    return null;
  }

  /// Unmatched keyed operations of [type] in [dep] whose key starts with
  /// [prefix]: lets an adapter tell a payload mismatch from an unrecorded
  /// operation.
  bool hasUnconsumed(String dep, String type, String prefix) {
    for (final e in _keyed.entries) {
      if (!e.key.startsWith('$dep|$type|$prefix')) continue;
      if (e.value.any((r) => !r.consumed)) return true;
    }
    return false;
  }

  /// Matches the next unconsumed outbound event of [types] in [scope], in
  /// recorded order (sends on a connection, a client close, a cancel, the
  /// app's reply to a platform call).
  RecordedInteraction? takeNext(String scope, Set<String> types) {
    final list = _ordered[scope];
    if (list == null) return null;
    for (final r in list) {
      if (r.consumed || !types.contains(r.type)) continue;
      _consume(r);
      return r;
    }
    return null;
  }

  void _consume(RecordedInteraction r) {
    final now = clock();
    r
      ..consumed = true
      ..at = now;
    for (final inbound in _released[r] ?? const <RecordedInteraction>[]) {
      _schedule(inbound, now + (inbound.event.t - r.event.t));
    }
  }

  void _schedule(RecordedInteraction r, int due) {
    final last = _lastDue[r.scope];
    final at = last != null && last > due ? last : due;
    _lastDue[r.scope] = at;
    r.dueAt = at;
    _pending.add(r);
  }

  /// Replay of recorded input started at replay time [at], which
  /// corresponds to recorded time [base]. Events without an anchor become
  /// due on this clock.
  void runStarted(int at) {
    _runStart = at;
    for (final r in _unanchored) {
      if (r.dueAt == null && !r.consumed) {
        _schedule(r, at + (r.event.t - base));
      }
    }
    _pending.sort(_byDue);
  }

  /// Events without an anchor recorded before the replayed window started
  /// (e.g. platform calls before the first frame) are due as soon as their
  /// handler exists.
  void _scheduleEarly(String scope) {
    if (_runStart != null) return;
    for (final r in _unanchored) {
      if (r.scope != scope || r.dueAt != null || r.consumed) continue;
      if (r.event.t < base) _schedule(r, clock());
    }
  }

  /// Delivers inbound events of [scope] to [handler] from now on (and any
  /// already due).
  void bind(String scope, void Function(RecordedInteraction) handler) {
    _handlers[scope] = handler;
    _scheduleEarly(scope);
  }

  void unbind(String scope) => _handlers.remove(scope);

  bool isBound(String scope) => _handlers.containsKey(scope);

  /// Earliest time an event is due whose handler is bound; null when
  /// nothing is scheduled. Events waiting for a handler do not count (an
  /// open but idle subscription must not hold replay busy).
  int? get nextDueAt {
    int? next;
    for (final r in _pending) {
      if (!_handlers.containsKey(r.scope)) continue;
      final due = r.dueAt!;
      if (next == null || due < next) next = due;
    }
    return next;
  }

  /// Scheduled, undelivered events of [scope] (e.g. the server's close
  /// after the app closed a connection).
  int scheduledIn(String scope) =>
      _pending.where((r) => r.scope == scope).length;

  /// Whether any scheduled event waits for a handler.
  bool get hasWaiting => _pending.any((r) => !_handlers.containsKey(r.scope));

  /// Delivers every event due at or before now, in (due, seq) order.
  /// Returns how many were delivered.
  int pump() {
    final now = clock();
    _pending.sort(_byDue);
    var delivered = 0;
    final keep = <RecordedInteraction>[];
    final due = <RecordedInteraction>[];
    for (final r in _pending) {
      if (r.dueAt! > now) {
        keep.add(r);
        continue;
      }
      final handler = _handlers[r.scope];
      if (handler == null) {
        if (now - r.dueAt! > maxHandlerWaitMs) {
          r.consumed = true;
          _divergences.add((
            '${r.family}.undelivered',
            '${_describe(r)}: no handler for ${now - r.dueAt!} ms',
          ));
        } else {
          keep.add(r);
        }
        continue;
      }
      due.add(r);
    }
    _pending
      ..clear()
      ..addAll(keep);
    for (final r in due) {
      r
        ..consumed = true
        ..at = now;
      final handler = _handlers[r.scope];
      if (handler == null) {
        // Unbound by an earlier delivery in this batch (a close).
        _pending.add(r);
        continue;
      }
      handler(r);
      delivered++;
    }
    return delivered;
  }

  static int _byDue(RecordedInteraction a, RecordedInteraction b) {
    final c = a.dueAt!.compareTo(b.dueAt!);
    return c != 0 ? c : a.event.seq.compareTo(b.event.seq);
  }

  /// Unmatched and undelivered recorded interactions, grouped by family and
  /// scope: `<family>.unused` when recorded at or before [failureT] (or
  /// with no failure), `<family>.unusedAfterFailure` after it.
  List<(String, String)> unused(int? failureT) {
    final groups = <(String, bool, String), List<RecordedInteraction>>{};
    for (final r in _all) {
      if (r.consumed) continue;
      final after = failureT != null && r.event.t > failureT;
      (groups[(r.family, after, r.scope)] ??= []).add(r);
    }
    return [
      for (final e in groups.entries)
        (
          '${e.key.$1}.${e.key.$2 ? 'unusedAfterFailure' : 'unused'}',
          '${e.key.$3}: ${_summary(e.value)}',
        ),
    ];
  }

  static String _summary(List<RecordedInteraction> list) {
    final counts = <String, int>{};
    for (final r in list) {
      counts[r.type] = (counts[r.type] ?? 0) + 1;
    }
    final first = list.first.event.t;
    return '${counts.entries.map((e) => e.value > 1 ? '${e.key}×${e.value}' : e.key).join(', ')} from ${first}ms';
  }

  static String _describe(RecordedInteraction r) =>
      '${r.scope} ${r.type} @${r.event.t}ms';
}
