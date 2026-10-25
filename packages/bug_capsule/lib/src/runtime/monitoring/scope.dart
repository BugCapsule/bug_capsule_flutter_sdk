import 'dart:async';

import '../../core/core.dart';
import 'tracing.dart';

/// Zone key of a temporary scope (`BugCapsule.withScope`).
const scopeZoneKey = #bugcapsule.scope;

/// An incoming trace to continue (`BugCapsule.continueTrace`).
class ContinuedTrace {
  const ContinuedTrace(
    this.traceId,
    this.parentSpanId,
    this.sampled, {
    this.sampleRate,
  });

  final String traceId;
  final String parentSpanId;
  final bool sampled;
  final double? sampleRate;
}

/// Data applied to every event, transaction and feedback captured while it
/// is current: user, tags, extras, contexts, level, fingerprint and the
/// transaction bound to it (the current screen).
class Scope {
  Scope();

  MonitoringUser? user;
  final Map<String, String> tags = {};
  final Map<String, Object?> extras = {};
  final Map<String, Object?> contexts = {};

  /// Overrides the level of events captured with this scope.
  EventLevel? level;

  /// Custom grouping for events captured with this scope.
  List<String>? fingerprint;

  /// The transaction new spans attach to when no span is active in the zone
  /// (screen transactions bind themselves here).
  BugCapsuleTransaction? transaction;

  /// Set by `continueTrace`; the next root transaction joins this trace.
  ContinuedTrace? continuedTrace;

  void setUser(MonitoringUser? user) => this.user = user;
  void setTag(String key, String value) => tags[key] = value;
  void setTags(Map<String, String> tags) => this.tags.addAll(tags);
  void removeTag(String key) => tags.remove(key);
  void setExtra(String key, Object? value) => extras[key] = value;
  void setExtras(Map<String, Object?> extras) => this.extras.addAll(extras);
  void setContext(String name, Object? value) => contexts[name] = value;
  void setLevel(EventLevel? level) => this.level = level;
  void setFingerprint(List<String>? fingerprint) =>
      this.fingerprint = fingerprint;

  /// The open span: the zone's (`startSpan`), else the bound transaction.
  BugCapsuleSpan? get activeSpan {
    final zone = zoneSpan();
    if (zone != null) return zone;
    final tx = transaction;
    return tx != null && !tx.finished ? tx : null;
  }

  Scope clone() => Scope()
    ..user = user
    ..tags.addAll(tags)
    ..extras.addAll(extras)
    ..contexts.addAll(contexts)
    ..level = level
    ..fingerprint = fingerprint
    ..transaction = transaction
    ..continuedTrace = continuedTrace;

  void clear() {
    user = null;
    tags.clear();
    extras.clear();
    contexts.clear();
    level = null;
    fingerprint = null;
    transaction = null;
    continuedTrace = null;
  }

  /// The root scope, usable before `BugCapsule.init` (a user set early is
  /// kept).
  static final Scope root = Scope();

  /// The zone's temporary scope, else [root].
  static Scope get current {
    final s = Zone.current[scopeZoneKey];
    return s is Scope ? s : root;
  }
}
