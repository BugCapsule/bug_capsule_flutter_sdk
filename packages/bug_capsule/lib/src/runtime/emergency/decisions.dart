import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/core.dart';
import 'contract.dart';
import 'crypto.dart';

/// `manifest.capabilities` key that says whether a capsule holds every
/// decision (§7.8).
const emergencyDecisionsCapability = 'emergency.decisions';

/// The subject as written in a capsule: never the subject itself (§7.8).
String emergencySubjectTag(String subject) {
  final digest = sha256(utf8.encode('bugcapsule.emergency.subject:$subject'));
  final hex = StringBuffer();
  for (final b in digest.take(8)) {
    hex.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}

/// The latest decision of each feature key and subject, and whether all of
/// them could be kept. A decision is written when it changes, because apps
/// may evaluate on every build.
class EmergencyDecisionTracker {
  EmergencyDecisionTracker({this.maxPairs = 256});

  final int maxPairs;
  final Map<(String, String?), Map<String, Object?>> _latest = {};
  final Map<String, String> _tags = {};

  /// False once a decision could not be recorded.
  bool get complete => _complete;
  bool _complete = true;

  /// Each tracked decision as event data.
  Iterable<Map<String, Object?>> get current => _latest.values;

  void markIncomplete() => _complete = false;

  /// The event data when the decision changed; null when it did not or
  /// when it no longer fits.
  Map<String, Object?>? track(EmergencyDecision decision, String? subject) {
    final tag = subject == null ? null : tagOf(subject);
    final pair = (decision.featureKey, tag);
    final data = _eventData(decision, tag);
    final previous = _latest[pair];
    if (previous != null && mapEquals(previous, data)) return null;
    if (previous == null && _latest.length >= maxPairs) {
      _complete = false;
      return null;
    }
    _latest[pair] = data;
    return data;
  }

  /// [emergencySubjectTag], cached: hashing on every build adds up.
  String tagOf(String subject) {
    final cached = _tags[subject];
    if (cached != null) return cached;
    if (_tags.length >= 64) _tags.clear();
    return _tags[subject] = emergencySubjectTag(subject);
  }

  void clear() {
    _latest.clear();
    _tags.clear();
    _complete = true;
  }

  static Map<String, Object?> _eventData(EmergencyDecision d, String? tag) => {
    'key': d.featureKey,
    'subject': ?tag,
    'action': d.action.wire,
    'source': d.source.wire,
    'reasonCode': ?d.reasonCode,
    'policyId': ?d.policyId,
    'policyRevision': ?d.policyRevision,
    'documentRevision': ?d.documentRevision,
    'message': ?d.publicUserMessage,
    'requiredVersion': ?d.requiredVersion,
    'fallback': ?d.fallback,
    if (d.fallbackAvailable) 'fallbackAvailable': true,
  };
}

/// The decisions of a capsule, looked up during replay (§7.8).
class EmergencyDecisionScript {
  EmergencyDecisionScript(Iterable<BugCapsuleEvent> events) {
    for (final e in events) {
      if (e.type != EventTypes.emergencyDecision) continue;
      final entry = _Entry.tryParse(e);
      if (entry != null) (_byKey[entry.key] ??= []).add(entry);
    }
  }

  final Map<String, List<_Entry>> _byKey = {};

  /// The decision the app saw for [key] at recorded time [t]; null when the
  /// capsule has none for it.
  EmergencyDecision? lookup(String key, String? subjectTag, int t) {
    final all = _byKey[key];
    if (all == null) return null;
    final same = [
      for (final e in all)
        if (e.subject == subjectTag) e,
    ];
    final entries = same.isEmpty ? all : same;
    _Entry? latest;
    _Entry? earliest;
    for (final e in entries) {
      if (earliest == null || e.t < earliest.t) earliest = e;
      if (e.t <= t && (latest == null || e.t >= latest.t)) latest = e;
    }
    return (latest ?? earliest)!.decision;
  }
}

class _Entry {
  _Entry(this.key, this.subject, this.t, this.decision);

  final String key;
  final String? subject;
  final int t;
  final EmergencyDecision decision;

  static _Entry? tryParse(BugCapsuleEvent e) {
    final d = e.data;
    final key = d['key'];
    // Not fromWire: that blocks an unknown action, which only a document may do.
    final action = EmergencyAction.values
        .where((a) => a.wire == d['action'])
        .firstOrNull;
    if (key is! String || action == null) return null;
    return _Entry(
      key,
      d['subject'] is String ? d['subject'] as String : null,
      e.t,
      EmergencyDecision(
        featureKey: key,
        allowed: action == EmergencyAction.allow,
        action: action,
        source: EmergencyDecisionSource.replay,
        reasonCode: _text(d['reasonCode']),
        policyId: _text(d['policyId']),
        policyRevision: _int(d['policyRevision']),
        documentRevision: _int(d['documentRevision']),
        publicUserMessage: _text(d['message']),
        requiredVersion: _text(d['requiredVersion']),
        fallback: _text(d['fallback']),
        fallbackAvailable: d['fallbackAvailable'] == true,
      ),
    );
  }

  static String? _text(Object? v) => v is String ? v : null;
  static int? _int(Object? v) => v is int ? v : null;
}
