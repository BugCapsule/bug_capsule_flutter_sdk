import 'dart:collection';

import 'capsule.dart';
import 'event.dart';

/// The checkpoint plus the events that follow it — what a capsule replays.
class RecordedWindow {
  const RecordedWindow({
    required this.checkpoint,
    required this.events,
    required this.droppedEvents,
    required this.hasGap,
  });

  final Checkpoint checkpoint;
  final List<BugCapsuleEvent> events;

  /// Events evicted from the buffer over the whole session.
  final int droppedEvents;

  /// True when no retained checkpoint covers the oldest retained event, so
  /// some events between the checkpoint and the window are missing.
  final bool hasGap;
}

/// Told about what a [FlightRecorder] keeps, so a crash journal can mirror
/// it on disk. Called synchronously from the recording path: implementations
/// only hand the data on.
abstract interface class FlightRecorderListener {
  void onEvent(BugCapsuleEvent event);
  void onCheckpoint(Checkpoint checkpoint);

  /// Retained events or checkpoints were rewritten ([FlightRecorder.rewrite]).
  void onRewrite(FlightRecorder recorder);
}

/// Bounded event buffer with checkpoints.
///
/// While nothing has been evicted, the window is the launch checkpoint plus
/// every event (replay re-executes the whole session). After eviction starts,
/// the window starts at the earliest periodic checkpoint taken after the last
/// evicted event, so the checkpoint plus its following events is complete.
class FlightRecorder {
  FlightRecorder({
    required Checkpoint launch,
    this.maxEvents = 20000,
    this.windowMs = 5 * 60 * 1000,
    this.maxCheckpoints = 4,
  }) : assert(launch.kind == CheckpointKind.launch),
       _launch = launch;

  final int maxEvents;
  final int windowMs;
  final int maxCheckpoints;

  Checkpoint _launch;
  final ListQueue<BugCapsuleEvent> _events = ListQueue();
  final List<Checkpoint> _periodic = [];
  int _seq = 0;
  int _dropped = 0;
  int _lastEvictedSeq = 0;

  /// Events removed by [rewrite] over the session.
  int rewriteDropped = 0;

  /// Mirrors what the recorder keeps (the crash journal).
  FlightRecorderListener? listener;

  int get lastSeq => _seq;
  Checkpoint get launch => _launch;
  List<Checkpoint> get periodicCheckpoints => List.unmodifiable(_periodic);
  Iterable<BugCapsuleEvent> get events => _events;
  int get eventCount => _events.length;
  int get droppedEvents => _dropped;
  bool get launchCoversWindow => _dropped == 0;

  BugCapsuleEvent add(
    int t,
    String type, [
    Map<String, Object?> data = const {},
  ]) {
    final event = BugCapsuleEvent(seq: ++_seq, t: t, type: type, data: data);
    _events.addLast(event);
    _evict(t);
    listener?.onEvent(event);
    return event;
  }

  void addCheckpoint(Checkpoint checkpoint) {
    assert(checkpoint.kind == CheckpointKind.periodic);
    _periodic.add(checkpoint);
    _prune();
    listener?.onCheckpoint(checkpoint);
  }

  /// Rewrites every retained event and checkpoint in place, e.g. to apply
  /// redaction rules that arrived after they were recorded. Sequence numbers
  /// and times must be kept; returning null drops the event (counted in
  /// [rewriteDropped]).
  void rewrite({
    BugCapsuleEvent? Function(BugCapsuleEvent event)? event,
    Checkpoint Function(Checkpoint checkpoint)? checkpoint,
  }) {
    if (event != null) {
      final updated = <BugCapsuleEvent>[];
      for (final e in _events) {
        final r = event(e);
        if (r == null) {
          rewriteDropped++;
        } else {
          updated.add(r);
        }
      }
      _events
        ..clear()
        ..addAll(updated);
    }
    if (checkpoint != null) {
      _launch = checkpoint(_launch);
      for (var i = 0; i < _periodic.length; i++) {
        _periodic[i] = checkpoint(_periodic[i]);
      }
    }
    listener?.onRewrite(this);
  }

  /// Builds a checkpoint stamped with the current sequence number.
  Checkpoint checkpointNow({
    required CheckpointKind kind,
    required int t,
    required int wallClockMs,
    required Map<String, Object?> data,
  }) => Checkpoint(
    kind: kind,
    t: t,
    wallClockMs: wallClockMs,
    afterSeq: _seq,
    data: data,
  );

  RecordedWindow window() {
    if (launchCoversWindow) {
      return RecordedWindow(
        checkpoint: _launch,
        events: List.of(_events),
        droppedEvents: 0,
        hasGap: false,
      );
    }
    Checkpoint? chosen;
    for (final cp in _periodic) {
      if (cp.afterSeq >= _lastEvictedSeq) {
        chosen = cp;
        break;
      }
    }
    final hasGap = chosen == null;
    chosen ??= _periodic.isNotEmpty ? _periodic.last : _launch;
    final from = chosen.afterSeq;
    return RecordedWindow(
      checkpoint: chosen,
      events: [
        for (final e in _events)
          if (e.seq > from) e,
      ],
      droppedEvents: _dropped,
      hasGap: hasGap,
    );
  }

  void _evict(int now) {
    while (_events.isNotEmpty &&
        (_events.length > maxEvents || _events.first.t < now - windowMs)) {
      _lastEvictedSeq = _events.removeFirst().seq;
      _dropped++;
    }
    if (_dropped > 0) _prune();
  }

  /// Keeps periodic checkpoints that can still start a complete window; when
  /// none can, keeps only the newest as a best-effort fallback.
  void _prune() {
    final firstValid = _periodic.indexWhere(
      (cp) => cp.afterSeq >= _lastEvictedSeq,
    );
    final keepFrom = firstValid == -1 ? _periodic.length - 1 : firstValid;
    if (keepFrom > 0) _periodic.removeRange(0, keepFrom);
    while (_periodic.length > maxCheckpoints) {
      _periodic.removeAt(0);
    }
  }
}
