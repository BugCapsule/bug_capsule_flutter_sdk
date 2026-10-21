import 'dart:async';

import '../../core/core.dart';

/// Zone key of the active span (`BugCapsule.startSpan`).
const spanZoneKey = #bugcapsule.span;

/// A timed operation in a trace (monitoring-v1 §8).
abstract interface class BugCapsuleSpan {
  String get traceId;
  String get spanId;
  String? get parentSpanId;
  String get op;
  String? get description;

  /// The trace's sampling decision, made at its root. Unsampled spans still
  /// propagate their ids (with the `00` flag) but are never sent.
  bool get sampled;
  bool get finished;
  String? get status;

  BugCapsuleSpan startChild(String op, {String? description});
  void setData(String key, Object? value);
  void setTag(String key, String value);
  void setStatus(String status);

  /// Ends the span; the status defaults to `ok`. Later calls are ignored.
  void finish({String? status, DateTime? endTimestamp});

  /// `traceparent` header value for an outgoing request made by this span.
  String toTraceparent();

  /// `baggage` header value (`bugcapsule-*` entries only).
  String toBaggage();
}

/// The root span of a trace segment: sent as one `transaction` item with
/// its finished children.
abstract interface class BugCapsuleTransaction implements BugCapsuleSpan {
  String get name;
  set name(String value);
  void setMeasurement(String name, num value, {String unit = 'none'});
}

/// What a transaction needs from the monitoring hub.
abstract interface class TransactionSink {
  String? get release;
  String? get environment;
  void transactionFinished(TransactionImpl transaction);
}

class SpanImpl implements BugCapsuleSpan {
  SpanImpl._(
    this._transaction, {
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required this.op,
    required this.description,
    DateTime? startTimestamp,
  }) : startTimestamp = startTimestamp ?? DateTime.now();

  TransactionImpl? _transaction;
  TransactionImpl get transaction => _transaction!;

  @override
  final String traceId;
  @override
  final String spanId;
  @override
  final String? parentSpanId;
  @override
  final String op;
  @override
  String? description;
  final DateTime startTimestamp;
  DateTime? endTimestamp;
  @override
  String? status;
  final Map<String, Object?> data = {};
  final Map<String, String> tags = {};

  @override
  bool get sampled => transaction.sampled;
  @override
  bool get finished => endTimestamp != null;

  @override
  BugCapsuleSpan startChild(String op, {String? description}) => transaction._startChild(this, op, description);

  @override
  void setData(String key, Object? value) => data[key] = value;
  @override
  void setTag(String key, String value) => tags[key] = value;
  @override
  void setStatus(String status) => this.status = status;

  @override
  void finish({String? status, DateTime? endTimestamp}) {
    if (finished) return;
    this.endTimestamp = endTimestamp ?? DateTime.now();
    this.status = status ?? this.status ?? SpanStatus.ok;
    transaction._childFinished(this);
  }

  @override
  String toTraceparent() => TraceParent.format(traceId, spanId, sampled);

  @override
  String toBaggage() => Baggage.format(
        traceId: traceId,
        release: transaction._sink.release,
        environment: transaction._sink.environment,
        sampleRate: transaction.sampleRate,
        sampled: sampled,
      );

  Map<String, Object?> toJson() => {
        'spanId': spanId,
        'parentSpanId': parentSpanId,
        'op': cut(op, 100),
        if (description != null) 'description': cut(description!, 2000),
        'startTimestamp': isoTimestamp(startTimestamp),
        'timestamp': isoTimestamp(endTimestamp ?? DateTime.now()),
        'status': status ?? SpanStatus.ok,
        if (data.isNotEmpty) 'data': data,
        if (tags.isNotEmpty) 'tags': sanitizeTags(tags),
      };
}

class TransactionImpl extends SpanImpl implements BugCapsuleTransaction {
  /// [idleTimeout]: finish on its own after this long without open
  /// children, trimmed to the last child's end; discarded if it never had a
  /// child. [maxDuration] caps an idle transaction.
  TransactionImpl({
    required String name,
    required super.op,
    required TransactionSink sink,
    required this.sampled,
    this.sampleRate,
    String? traceId,
    super.parentSpanId,
    super.startTimestamp,
    this.idleTimeout,
    this.maxDuration = const Duration(seconds: 30),
  })  : _name = name,
        _sink = sink,
        super._(null, traceId: traceId ?? newTraceId(), spanId: newSpanId(), description: null) {
    _transaction = this;
    if (idleTimeout != null) {
      _restartIdle();
      _deadline = Timer(maxDuration, () => _finish(status: SpanStatus.deadlineExceeded));
    }
  }

  final TransactionSink _sink;
  String _name;
  @override
  final bool sampled;
  final double? sampleRate;
  final Duration? idleTimeout;
  final Duration maxDuration;
  final List<SpanImpl> children = [];
  final Map<String, Map<String, Object?>> measurements = {};
  final String eventId = uuidV4();

  /// Called just before the transaction is handed to the sink (e.g. to add
  /// frame measurements).
  final List<void Function(TransactionImpl)> beforeFinish = [];
  int _open = 0;
  Timer? _idle;
  Timer? _deadline;
  bool _discard = false;

  @override
  String get name => _name;
  @override
  set name(String value) => _name = value;

  /// False once the transaction was dropped (idle without children).
  bool get discarded => _discard;

  @override
  void setMeasurement(String name, num value, {String unit = 'none'}) =>
      measurements[name] = {'value': value, 'unit': unit};

  SpanImpl _startChild(SpanImpl parent, String op, String? description) {
    final child = SpanImpl._(this,
        traceId: traceId, spanId: newSpanId(), parentSpanId: parent.spanId, op: op, description: description);
    if (finished || children.length >= 1000) return child;
    children.add(child);
    _open++;
    _idle?.cancel();
    return child;
  }

  void _childFinished(SpanImpl span) {
    if (identical(span, this)) return;
    if (_open > 0) _open--;
    if (_open == 0 && idleTimeout != null && !finished) _restartIdle();
  }

  void _restartIdle() {
    _idle?.cancel();
    _idle = Timer(idleTimeout!, () {
      DateTime? last;
      for (final c in children) {
        final end = c.endTimestamp;
        if (end != null && (last == null || end.isAfter(last))) last = end;
      }
      if (children.isEmpty) _discard = true;
      _finish(endTimestamp: last);
    });
  }

  @override
  void finish({String? status, DateTime? endTimestamp}) => _finish(status: status, endTimestamp: endTimestamp);

  void _finish({String? status, DateTime? endTimestamp}) {
    if (finished) return;
    _idle?.cancel();
    _deadline?.cancel();
    final end = endTimestamp ?? DateTime.now();
    for (final c in children) {
      if (!c.finished) {
        c.endTimestamp = end;
        c.status ??= SpanStatus.deadlineExceeded;
      }
    }
    this.endTimestamp = end.isBefore(startTimestamp) ? startTimestamp : end;
    this.status = status ?? this.status ?? SpanStatus.ok;
    for (final hook in beforeFinish) {
      try {
        hook(this);
      } catch (_) {
        // A measurement hook must not lose the transaction.
      }
    }
    _sink.transactionFinished(this);
  }

  /// Cancels timers without sending (SDK shutdown).
  void abandon() {
    _idle?.cancel();
    _deadline?.cancel();
    _discard = true;
    endTimestamp ??= DateTime.now();
  }

  Map<String, Object?> payload() => {
        'eventId': eventId,
        'traceId': traceId,
        'spanId': spanId,
        'parentSpanId': parentSpanId,
        'name': cut(name, 200),
        'op': cut(op, 100),
        'startTimestamp': isoTimestamp(startTimestamp),
        'timestamp': isoTimestamp(endTimestamp ?? DateTime.now()),
        'status': status ?? SpanStatus.ok,
        'runtime': 'flutter',
        'release': ?_sink.release,
        'environment': ?_sink.environment,
        'tags': sanitizeTags(tags),
        if (data.isNotEmpty) 'extra': data,
        'measurements': measurements,
        'spans': [for (final c in children.take(1000)) c.toJson()],
      };
}

/// The span `startSpan` made active in the current zone, if still open.
BugCapsuleSpan? zoneSpan() {
  final span = Zone.current[spanZoneKey];
  return span is BugCapsuleSpan && !span.finished ? span : null;
}
