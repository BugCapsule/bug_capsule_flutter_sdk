import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';

/// Emergency policies, client contract v1 (spec/emergency-client-v1.md):
/// the trust anchor, envelope verification and the reference evaluation.
/// Pure functions: no clock, no I/O.

const emergencyWireFormat = 'bugcapsule.emergency.v1';
const emergencySignatureAlg = 'ES256';
const emergencyAnchorPrefix = 'bcek.v1.';

/// What a guarded feature should do (§4).
enum EmergencyAction {
  allow('ALLOW', 0),
  useSafeFallback('USE_SAFE_FALLBACK', 1),
  readOnly('READ_ONLY', 2),
  disableFeature('DISABLE_FEATURE', 3),
  showMaintenance('SHOW_MAINTENANCE', 4),
  requireUpdate('REQUIRE_UPDATE', 5),
  block('BLOCK', 6);

  const EmergencyAction(this.wire, this.restrictiveness);

  /// The name on the wire, e.g. `REQUIRE_UPDATE`.
  final String wire;

  /// Ties at one priority go to the higher value (§6.5).
  final int restrictiveness;

  /// An action this client does not know is treated as [block] (fails safe).
  static EmergencyAction fromWire(String wire) {
    for (final a in values) {
      if (a.wire == wire) return a;
    }
    return block;
  }
}

/// Platforms of §1. A Flutter app is [flutterAndroid] or [flutterIos].
enum EmergencyPlatform {
  flutterAndroid('FLUTTER_ANDROID'),
  flutterIos('FLUTTER_IOS'),
  nativeAndroid('NATIVE_ANDROID'),
  nativeIos('NATIVE_IOS'),
  server('SERVER');

  const EmergencyPlatform(this.wire);
  final String wire;
}

/// Where a decision came from (§7.4).
enum EmergencyDecisionSource {
  /// A verified document that has not expired.
  policy('policy'),

  /// An expired document, used because the feature's failure mode is
  /// `useLastValidPolicy`.
  stalePolicy('stale_policy'),

  /// No usable document: the feature's failure mode decided.
  failureMode('failure_mode'),

  /// The SDK is replaying a capsule: the decision recorded in it (§7.8).
  replay('replay');

  const EmergencyDecisionSource(this.wire);
  final String wire;
}

/// Why a fetched or cached envelope was not used (§4, §5). [wire] is the
/// lower-case code sent in receipts.
enum EmergencyRejection {
  malformed('malformed'),
  unsupportedFormat('unsupported_format'),
  unknownKey('unknown_key'),
  badSignature('bad_signature'),
  unsupportedSchema('unsupported_schema'),
  wrongApplication('wrong_application'),
  wrongEnvironment('wrong_environment'),
  staleRevision('stale_revision'),
  expiredOnArrival('expired_on_arrival');

  const EmergencyRejection(this.wire);
  final String wire;
}

final RegExp _featureKey = RegExp(
  r'^[a-z0-9_-]{1,64}(\.[a-z0-9_-]{1,64}){0,7}$',
);
final RegExp _policyKey = RegExp(
  r'^[a-z0-9_-]{1,64}(\.[a-z0-9_-]{1,64}){0,7}(\.\*)?$',
);
final RegExp _environment = RegExp(r'^[a-z0-9][a-z0-9_-]{0,39}$');

/// A feature key such as `checkout.confirm_order` (no wildcard).
bool isEmergencyFeatureKey(String key) => _featureKey.hasMatch(key);

/// A feature key, or a `prefix.*` pattern.
bool isEmergencyKeyPattern(String key) =>
    _policyKey.hasMatch(key) && key.length <= 200;

bool isEmergencyEnvironment(String env) => _environment.hasMatch(env);

/// `prefix.*` covers every key below `prefix` (not `prefix` itself).
bool emergencyKeyMatches(String pattern, String featureKey) {
  if (pattern.endsWith('.*')) {
    return featureKey.startsWith(pattern.substring(0, pattern.length - 1));
  }
  return pattern == featureKey;
}

// ------------------------------------------------------------------ anchor

/// The parsed trust anchor (§2): the application and the keys allowed to
/// sign its documents. Never fetched from the network.
final class EmergencyTrustAnchor {
  EmergencyTrustAnchor._(this.applicationId, this._keys);

  final String applicationId;
  final Map<String, P256PublicKey> _keys;

  Iterable<String> get keyIds => _keys.keys;
  P256PublicKey? key(String kid) => _keys[kid];

  /// Parses `bcek.v1.<base64url JSON>`. Throws [FormatException] for an
  /// anchor that is malformed, has no keys, a key whose `alg` is not ES256,
  /// or a key that is not a P-256 SubjectPublicKeyInfo.
  static EmergencyTrustAnchor parse(String anchor) {
    final trimmed = anchor.trim();
    if (!trimmed.startsWith(emergencyAnchorPrefix)) {
      throw const FormatException(
        'not an emergency trust anchor (expected bcek.v1.…)',
      );
    }
    final bytes = decodeBase64Url(
      trimmed.substring(emergencyAnchorPrefix.length),
    );
    if (bytes == null) {
      throw const FormatException('trust anchor is not base64url');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('trust anchor is not JSON');
    }
    if (json is! Map) throw const FormatException('malformed trust anchor');
    final app = json['app'];
    final keys = json['keys'];
    if (app is! String || app.isEmpty || keys is! List || keys.isEmpty) {
      throw const FormatException('malformed trust anchor');
    }
    final parsed = <String, P256PublicKey>{};
    for (final k in keys) {
      if (k is! Map) throw const FormatException('malformed trust anchor key');
      final kid = k['kid'];
      final alg = k['alg'];
      final spki = k['spki'];
      if (kid is! String || kid.isEmpty || spki is! String) {
        throw const FormatException('malformed trust anchor key');
      }
      if (alg != emergencySignatureAlg) {
        throw FormatException('trust anchor key "$kid" is not ES256');
      }
      final der = decodeBase64Url(spki);
      final key = der == null ? null : P256PublicKey.fromSpki(der);
      if (key == null) {
        throw FormatException('trust anchor key "$kid" is not a P-256 key');
      }
      parsed[kid] = key;
    }
    return EmergencyTrustAnchor._(app, Map.unmodifiable(parsed));
  }
}

// ---------------------------------------------------------------- document

/// Inclusive version bounds; null is unbounded.
final class EmergencyVersionRange {
  const EmergencyVersionRange({this.min, this.max});
  final String? min;
  final String? max;

  Map<String, Object?> toJson() => {'min': min, 'max': max};
}

/// One policy of a signed document (§4), as the backend wrote it.
final class EmergencyPolicy {
  const EmergencyPolicy({
    required this.policyId,
    required this.key,
    required this.revision,
    required this.action,
    required this.actionName,
    required this.priority,
    required this.severity,
    required this.incidentId,
    required this.targetPlatforms,
    required this.versionRanges,
    required this.rolloutBp,
    required this.rolloutSeed,
    required this.reasonCode,
    required this.publicUserMessage,
    required this.requiredVersion,
    required this.fallback,
    required this.expiresAt,
  });

  final String policyId;

  /// A feature key, or `prefix.*`.
  final String key;
  final int revision;

  /// [EmergencyAction.block] for an action this SDK does not know.
  final EmergencyAction action;

  /// The action as sent, also when this SDK does not know it.
  final String actionName;
  final int priority;
  final String? severity;
  final String? incidentId;

  /// Platform names (`FLUTTER_IOS`, …); empty means every platform.
  final List<String> targetPlatforms;

  /// Empty means every version.
  final List<EmergencyVersionRange> versionRanges;

  /// Basis points of subjects included, 0..10000.
  final int rolloutBp;
  final String rolloutSeed;
  final String reasonCode;
  final String? publicUserMessage;

  /// REQUIRE_UPDATE: the first version that no longer needs the restriction.
  final String? requiredVersion;

  /// USE_SAFE_FALLBACK: the app-defined name of the fallback to use.
  final String? fallback;

  /// After it the policy no longer applies; null for no expiry.
  final DateTime? expiresAt;

  Map<String, Object?> toJson() => {
    'policy_id': policyId,
    'key': key,
    'revision': revision,
    'action': actionName,
    'priority': priority,
    'severity': severity,
    'incident_id': incidentId,
    'target_platforms': targetPlatforms,
    'version_ranges': [for (final r in versionRanges) r.toJson()],
    'rollout_bp': rolloutBp,
    'rollout_seed': rolloutSeed,
    'reason_code': reasonCode,
    'public_user_message': publicUserMessage,
    'required_version': requiredVersion,
    'fallback': fallback,
    'expires_at': expiresAt?.toUtc().toIso8601String(),
  };

  /// Parses one policy. Throws [FormatException] when a field has the wrong
  /// type, a key or version bound is not valid, or a time does not parse.
  static EmergencyPolicy fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('policy is not an object');
    T req<T>(String field) {
      final v = raw[field];
      if (v is T) return v;
      throw FormatException('policy field "$field" is malformed');
    }

    T? opt<T>(String field) {
      final v = raw[field];
      if (v == null || v is T) return v as T?;
      throw FormatException('policy field "$field" is malformed');
    }

    final key = req<String>('key');
    if (!isEmergencyKeyPattern(key)) {
      throw FormatException('policy key "$key" is not a feature key');
    }
    final platforms = <String>[];
    for (final p in req<List<Object?>>('target_platforms')) {
      if (p is! String) {
        throw const FormatException('policy target_platforms is malformed');
      }
      platforms.add(p);
    }
    final ranges = <EmergencyVersionRange>[];
    for (final r in req<List<Object?>>('version_ranges')) {
      if (r is! Map) {
        throw const FormatException('policy version_ranges is malformed');
      }
      final min = r['min'];
      final max = r['max'];
      for (final bound in [min, max]) {
        if (bound != null &&
            (bound is! String || parseEmergencyVersion(bound) == null)) {
          throw const FormatException('policy version bound is malformed');
        }
      }
      ranges.add(
        EmergencyVersionRange(min: min as String?, max: max as String?),
      );
    }
    final expires = opt<String>('expires_at');
    final DateTime? expiresAt;
    if (expires == null) {
      expiresAt = null;
    } else {
      expiresAt = DateTime.tryParse(expires);
      if (expiresAt == null) {
        throw const FormatException('policy expires_at is malformed');
      }
    }
    final actionName = req<String>('action');
    return EmergencyPolicy(
      policyId: req<String>('policy_id'),
      key: key,
      revision: req<int>('revision'),
      action: EmergencyAction.fromWire(actionName),
      actionName: actionName,
      priority: req<int>('priority'),
      severity: opt<String>('severity'),
      incidentId: opt<String>('incident_id'),
      targetPlatforms: List.unmodifiable(platforms),
      versionRanges: List.unmodifiable(ranges),
      rolloutBp: req<int>('rollout_bp'),
      rolloutSeed: req<String>('rollout_seed'),
      reasonCode: req<String>('reason_code'),
      publicUserMessage: opt<String>('public_user_message'),
      requiredVersion: opt<String>('required_version'),
      fallback: opt<String>('fallback'),
      expiresAt: expiresAt,
    );
  }
}

/// A verified policy document of one application and environment.
final class EmergencyPolicyDocument {
  const EmergencyPolicyDocument({
    required this.applicationId,
    required this.environment,
    required this.revision,
    required this.issuedAt,
    required this.expiresAt,
    required this.policies,
  });

  final String applicationId;
  final String environment;

  /// Only ever increases per environment.
  final int revision;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final List<EmergencyPolicy> policies;

  /// The document fields of a payload whose binding was already checked.
  /// Throws [FormatException] for a malformed field or policy.
  static EmergencyPolicyDocument fromJson(Map<Object?, Object?> json) {
    final revision = json['revision'];
    final issued = json['issued_at'];
    final expires = json['expires_at'];
    final policies = json['policies'];
    if (revision is! int || revision < 0) {
      throw const FormatException('document revision is malformed');
    }
    final issuedAt = issued is String ? DateTime.tryParse(issued) : null;
    final expiresAt = expires is String ? DateTime.tryParse(expires) : null;
    if (issuedAt == null || expiresAt == null) {
      throw const FormatException('document issued_at/expires_at is malformed');
    }
    if (policies is! List) {
      throw const FormatException('document policies is malformed');
    }
    return EmergencyPolicyDocument(
      applicationId: json['application_id']! as String,
      environment: json['environment']! as String,
      revision: revision,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      policies: List.unmodifiable(policies.map(EmergencyPolicy.fromJson)),
    );
  }
}

// ------------------------------------------------------------ verification

sealed class EnvelopeVerification {
  const EnvelopeVerification();
}

final class EnvelopeVerified extends EnvelopeVerification {
  const EnvelopeVerified(this.document);
  final EmergencyPolicyDocument document;
}

final class EnvelopeRejected extends EnvelopeVerification {
  const EnvelopeRejected(this.reason);
  final EmergencyRejection reason;
}

/// Verifies a decoded envelope (§4) in the normative order, stopping at the
/// first failure. The signature is checked over the decoded payload bytes,
/// which are parsed only afterwards.
EnvelopeVerification verifyEmergencyEnvelope(
  Object? raw,
  EmergencyTrustAnchor anchor,
  String environment,
) {
  EnvelopeRejected reject(EmergencyRejection r) => EnvelopeRejected(r);
  if (raw is! Map) return reject(EmergencyRejection.malformed);
  final kid = raw['kid'];
  final payload = raw['payload'];
  final signature = raw['signature'];
  if (kid is! String || payload is! String || signature is! String) {
    return reject(EmergencyRejection.malformed);
  }
  if (raw['format'] != emergencyWireFormat ||
      raw['alg'] != emergencySignatureAlg) {
    return reject(EmergencyRejection.unsupportedFormat);
  }
  final key = anchor.key(kid);
  if (key == null) return reject(EmergencyRejection.unknownKey);
  final payloadBytes = decodeBase64Url(payload);
  final signatureBytes = decodeBase64Url(signature);
  if (payloadBytes == null ||
      signatureBytes == null ||
      !key.verify(payloadBytes, signatureBytes)) {
    return reject(EmergencyRejection.badSignature);
  }
  final Object? doc;
  try {
    doc = jsonDecode(utf8.decode(payloadBytes));
  } on FormatException {
    return reject(EmergencyRejection.malformed);
  }
  if (doc is! Map) return reject(EmergencyRejection.malformed);
  if (doc['schema_version'] != 1) {
    return reject(EmergencyRejection.unsupportedSchema);
  }
  if (doc['application_id'] != anchor.applicationId) {
    return reject(EmergencyRejection.wrongApplication);
  }
  if (doc['environment'] != environment) {
    return reject(EmergencyRejection.wrongEnvironment);
  }
  try {
    return EnvelopeVerified(EmergencyPolicyDocument.fromJson(doc));
  } on FormatException {
    return reject(EmergencyRejection.malformed);
  }
}

// ---------------------------------------------------------------- versions

final RegExp _version = RegExp(
  r'^v?(\d{1,9}(?:\.\d{1,9}){0,5})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  caseSensitive: false,
);
final RegExp _digits = RegExp(r'^\d+$');

typedef EmergencyVersion = ({List<int> nums, List<String>? pre});

/// `v?N(.N){0,5}(-pre)?(+build)?` (§6.3); null for anything else.
EmergencyVersion? parseEmergencyVersion(String raw) {
  final m = _version.firstMatch(raw.trim());
  if (m == null) return null;
  return (
    nums: [for (final n in m.group(1)!.split('.')) int.parse(n)],
    pre: m.group(2)?.split('.'),
  );
}

/// -1, 0 or 1; null when either side does not parse. Missing parts are 0,
/// build metadata is ignored, a pre-release sorts before its release and
/// pre-release identifiers compare as in SemVer §11.
int? compareEmergencyVersions(String a, String b) {
  final x = parseEmergencyVersion(a);
  final y = parseEmergencyVersion(b);
  if (x == null || y == null) return null;
  final n = x.nums.length > y.nums.length ? x.nums.length : y.nums.length;
  for (var i = 0; i < n; i++) {
    final p = i < x.nums.length ? x.nums[i] : 0;
    final q = i < y.nums.length ? y.nums[i] : 0;
    if (p != q) return p < q ? -1 : 1;
  }
  final xp = x.pre;
  final yp = y.pre;
  if (xp == null && yp == null) return 0;
  if (xp == null) return 1;
  if (yp == null) return -1;
  final m = xp.length > yp.length ? xp.length : yp.length;
  for (var i = 0; i < m; i++) {
    if (i >= xp.length) return -1;
    if (i >= yp.length) return 1;
    final p = xp[i];
    final q = yp[i];
    final pn = _digits.hasMatch(p);
    final qn = _digits.hasMatch(q);
    if (pn && qn) {
      final d = BigInt.parse(p).compareTo(BigInt.parse(q));
      if (d != 0) return d < 0 ? -1 : 1;
    } else if (pn != qn) {
      return pn ? -1 : 1;
    } else if (p != q) {
      return p.compareTo(q) < 0 ? -1 : 1;
    }
  }
  return 0;
}

/// Whether [version] falls in any of [ranges] (§6.2). No ranges, or a
/// version that is null or does not parse: targeted.
bool emergencyVersionTargeted(
  String? version,
  List<EmergencyVersionRange> ranges,
) {
  if (ranges.isEmpty) return true;
  if (version == null || parseEmergencyVersion(version) == null) return true;
  for (final r in ranges) {
    final min = r.min;
    final max = r.max;
    // An unparsable bound cannot reach here from a verified document; it
    // counts as unbounded, like the reference.
    final aboveMin =
        min == null || (compareEmergencyVersions(version, min) ?? 0) >= 0;
    final belowMax =
        max == null || (compareEmergencyVersions(version, max) ?? 0) <= 0;
    if (aboveMin && belowMax) return true;
  }
  return false;
}

// ----------------------------------------------------------------- rollout

/// 0..9999: the first 4 bytes of SHA-256 of UTF-8 `<seed>:<subject>` as a
/// big-endian uint32, mod 10000 (§6.4).
int emergencyRolloutBucket(String seed, String subject) {
  final h = sha256(utf8.encode('$seed:$subject'));
  return ByteData.sublistView(h, 0, 4).getUint32(0) % 10000;
}

bool emergencyInRollout(EmergencyPolicy p, String? subject) {
  if (p.rolloutBp >= 10000) return true;
  if (p.rolloutBp <= 0) return false;
  // A partial rollout needs a stable subject; without one it applies.
  if (subject == null || subject.isEmpty) return true;
  return emergencyRolloutBucket(p.rolloutSeed, subject) < p.rolloutBp;
}

// -------------------------------------------------------------- evaluation

/// The answer for one feature key (§6, §7.4).
final class EmergencyDecision {
  const EmergencyDecision({
    required this.featureKey,
    required this.allowed,
    required this.action,
    required this.source,
    this.reasonCode,
    this.policyId,
    this.policyRevision,
    this.documentRevision,
    this.publicUserMessage,
    this.requiredVersion,
    this.fallback,
    this.fallbackAvailable = false,
    this.policy,
  });

  final String featureKey;

  /// Only [EmergencyAction.allow] is allowed.
  final bool allowed;
  final EmergencyAction action;
  final EmergencyDecisionSource source;

  /// The policy's reason, or `POLICY_UNAVAILABLE` for a failure mode.
  final String? reasonCode;
  final String? policyId;
  final int? policyRevision;

  /// The revision of the document that decided; null for failure modes.
  final int? documentRevision;

  /// Text the policy author wrote for end users; null when there is none.
  final String? publicUserMessage;
  final String? requiredVersion;
  final String? fallback;

  /// True only for USE_SAFE_FALLBACK with a fallback name.
  final bool fallbackAvailable;

  /// The winning policy, when one decided.
  final EmergencyPolicy? policy;

  /// The snake_case decision fields of §6, plus `source`.
  Map<String, Object?> toJson() => {
    'feature_key': featureKey,
    'allowed': allowed,
    'action': action.wire,
    'reason_code': reasonCode,
    'policy_id': policyId,
    'policy_revision': policyRevision,
    'document_revision': documentRevision,
    'public_user_message': publicUserMessage,
    'required_version': requiredVersion,
    'fallback': fallback,
    'fallback_available': fallbackAvailable,
    'source': source.wire,
  };

  @override
  String toString() => 'EmergencyDecision(${jsonEncode(toJson())})';
}

/// The reference decision (§6) over [policies]. [source] is
/// [EmergencyDecisionSource.policy] or [EmergencyDecisionSource.stalePolicy].
EmergencyDecision evaluateEmergencyPolicies({
  required List<EmergencyPolicy> policies,
  required int documentRevision,
  required String featureKey,
  required String platform,
  required String? appVersion,
  required String? subject,
  required DateTime now,
  EmergencyDecisionSource source = EmergencyDecisionSource.policy,
}) {
  EmergencyPolicy? winner;
  for (final p in policies) {
    if (!emergencyKeyMatches(p.key, featureKey)) continue;
    final expires = p.expiresAt;
    if (expires != null && !expires.isAfter(now)) continue;
    if (p.targetPlatforms.isNotEmpty && !p.targetPlatforms.contains(platform)) {
      continue;
    }
    if (!emergencyVersionTargeted(appVersion, p.versionRanges)) continue;
    if (!emergencyInRollout(p, subject)) continue;
    if (winner == null || _beats(p, winner, featureKey)) winner = p;
  }
  final w = winner;
  if (w == null) {
    return EmergencyDecision(
      featureKey: featureKey,
      allowed: true,
      action: EmergencyAction.allow,
      source: source,
      documentRevision: documentRevision,
    );
  }
  return EmergencyDecision(
    featureKey: featureKey,
    allowed: w.action == EmergencyAction.allow,
    action: w.action,
    source: source,
    reasonCode: w.reasonCode,
    policyId: w.policyId,
    policyRevision: w.revision,
    documentRevision: documentRevision,
    publicUserMessage: w.publicUserMessage,
    requiredVersion: w.requiredVersion,
    fallback: w.fallback,
    fallbackAvailable:
        w.action == EmergencyAction.useSafeFallback && w.fallback != null,
    policy: w,
  );
}

/// Highest priority, then most restrictive, then exact key over wildcard,
/// then lowest policy id by code unit.
bool _beats(EmergencyPolicy a, EmergencyPolicy b, String featureKey) {
  if (a.priority != b.priority) return a.priority > b.priority;
  if (a.action.restrictiveness != b.action.restrictiveness) {
    return a.action.restrictiveness > b.action.restrictiveness;
  }
  final ae = a.key == featureKey;
  final be = b.key == featureKey;
  if (ae != be) return ae;
  return a.policyId.compareTo(b.policyId) < 0;
}
