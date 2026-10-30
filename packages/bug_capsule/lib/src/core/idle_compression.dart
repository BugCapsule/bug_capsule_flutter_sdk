import 'event.dart';

/// Decides when replay may jump over an idle stretch before an input.
///
/// A stretch is skipped only when both sides agree it is idle:
/// * the recording shows nothing happening for longer than [minGapMs] before
///   the input ([idleSince]). An HTTP exchange counts from request to
///   response, so recorded latency is never inside an idle stretch;
/// * the replayed app is quiet ([maySkip]): nothing in flight and no
///   activity for [collapseToMs].
///
/// The stretch then shrinks to about [collapseToMs].
class IdleCompressor {
  IdleCompressor(this.events, {this.minGapMs = 1500, this.collapseToMs = 300});

  /// Every recorded event of the capsule, not only the replayable ones.
  final List<BugCapsuleEvent> events;
  final int minGapMs;
  final int collapseToMs;

  /// Recorded time from which the recording is idle until the input at [to],
  /// given the previous input at [from]; null when that stretch is not
  /// longer than [minGapMs].
  int? idleSince(int from, int to) {
    if (to - from <= minGapMs) return null;
    var since = from;
    for (final e in events) {
      // Rewritten after every periodic checkpoint: not something happening.
      if (e.type == EventTypes.emergencyDecision) continue;
      final start = e.type == EventTypes.http
          ? e.t - (e.data['durationMs'] as int? ?? 0)
          : e.t;
      if (start >= to) continue;
      final end = e.t < to ? e.t : to;
      if (end > since) since = end;
    }
    return to - since > minGapMs ? since : null;
  }

  /// Whether replay, now at recorded time [now], may jump to the input whose
  /// idle stretch began at [idleSince]. [busy] counts work still running in
  /// the app (pending responses, pressed pointers, animations); [quietMs] is
  /// how long ago the app last did something.
  bool maySkip({
    required int now,
    required int idleSince,
    required int busy,
    required int quietMs,
  }) => busy == 0 && quietMs >= collapseToMs && now >= idleSince + collapseToMs;
}
