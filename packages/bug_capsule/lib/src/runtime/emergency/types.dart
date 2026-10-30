import 'package:flutter/foundation.dart';

import '../config.dart' show BugCapsuleBackendConfig;
import 'contract.dart';

/// What a feature does while there is no usable policy document (§7.4).
enum EmergencyFailureMode {
  /// Allow (`reason_code: POLICY_UNAVAILABLE`). The default for every key.
  failOpen,

  /// Block (`reason_code: POLICY_UNAVAILABLE`). For actions that move money.
  failClosed,

  /// Evaluate the last verified document even after it expired; with no
  /// document at all, allow as [failOpen].
  useLastValidPolicy,
}

/// Settings of `BugCapsule.emergency.initialize`.
@immutable
class EmergencyConfig {
  const EmergencyConfig({
    required this.trustAnchor,
    this.environment = 'production',
    this.refreshInterval = const Duration(seconds: 60),
    this.failureModes = const {},
    this.token,
    this.backend,
    this.appVersion,
  });

  /// `bcek.v1.…` from the dashboard: the application id and the public keys
  /// allowed to sign its documents. Compile it into the app; it is never
  /// fetched from the network.
  final String trustAnchor;

  /// Matches `^[a-z0-9][a-z0-9_-]{0,39}$`.
  final String environment;

  /// How often policies are fetched while the app is in the foreground. At
  /// least 15 seconds.
  final Duration refreshInterval;

  /// Failure modes by feature key (`checkout.confirm_order`) or prefix
  /// (`checkout.*`). An exact key wins over a prefix, and a longer prefix
  /// over a shorter one. Keys not listed are [EmergencyFailureMode.failOpen].
  final Map<String, EmergencyFailureMode> failureModes;

  /// A `bcsdk.v1.…` SDK token; [backend] wins when both are set. Without
  /// either, the connection of `BugCapsule.init` is used.
  final String? token;
  final BugCapsuleBackendConfig? backend;

  /// The app version that version ranges are matched against. Defaults to
  /// `BugCapsuleConfig.appVersion` (or the `BUGCAPSULE_APP_VERSION`
  /// dart-define).
  final String? appVersion;

  static const minRefreshInterval = Duration(seconds: 15);

  Duration get effectiveRefreshInterval => refreshInterval < minRefreshInterval
      ? minRefreshInterval
      : refreshInterval;
}

/// Whether the current document may be used (§7.4, §7.5).
enum EmergencyDocumentState {
  /// No verified document.
  none,

  /// A verified document that has not expired (300 s of grace).
  usable,

  /// A verified document past its expiry plus grace.
  expired,
}

/// A failed fetch, or a fetched document that was rejected.
@immutable
class EmergencyError {
  const EmergencyError({
    required this.code,
    required this.message,
    required this.at,
    this.httpStatus,
  });

  /// A rejection reason (`bad_signature`, `stale_revision`, …) or a fetch
  /// failure (`network_error`, `http_503`, `credential_rejected`,
  /// `not_configured`, `not_connected`, `response_too_large`).
  final String code;
  final String message;
  final DateTime at;
  final int? httpStatus;

  @override
  String toString() =>
      'EmergencyError($code${httpStatus == null ? '' : ', HTTP $httpStatus'}: $message)';
}

/// The document decisions are made from, as published to observers. Every
/// evaluation uses one snapshot, never a mix of two.
@immutable
class EmergencySnapshot {
  const EmergencySnapshot({
    required this.document,
    required this.state,
    required this.receivedAt,
  });

  static const empty = EmergencySnapshot(
    document: null,
    state: EmergencyDocumentState.none,
    receivedAt: null,
  );

  final EmergencyPolicyDocument? document;

  /// The state when this snapshot was published.
  final EmergencyDocumentState state;

  /// When the document's envelope was received from the backend.
  final DateTime? receivedAt;

  int? get revision => document?.revision;
  DateTime? get issuedAt => document?.issuedAt;
  DateTime? get expiresAt => document?.expiresAt;

  @override
  String toString() =>
      'EmergencySnapshot(${state.name}, revision: $revision, expiresAt: $expiresAt)';
}

/// The module's current state (§7.5).
@immutable
class EmergencyStatus {
  const EmergencyStatus({
    required this.initialized,
    required this.active,
    required this.state,
    this.revision,
    this.issuedAt,
    this.expiresAt,
    this.receivedAt,
    this.lastFetchAt,
    this.lastError,
    this.credentialRejected = false,
    this.inactiveReason,
    this.environment,
    this.platform,
  });

  /// `initialize` was called.
  final bool initialized;

  /// Policies are fetched and evaluated. False before `initialize`, during
  /// capsule replay, and when [inactiveReason] says why not.
  final bool active;
  final EmergencyDocumentState state;
  final int? revision;
  final DateTime? issuedAt;
  final DateTime? expiresAt;
  final DateTime? receivedAt;

  /// When the backend last answered with a document or `304`.
  final DateTime? lastFetchAt;

  /// The last failure; null after a fetch succeeds.
  final EmergencyError? lastError;

  /// The backend refused the credential (401/403/404); scheduled fetches
  /// stopped for this process.
  final bool credentialRejected;

  /// `invalid_anchor`, `invalid_environment`, `unsupported_platform`,
  /// `replay` or `setup_failed`.
  final String? inactiveReason;
  final String? environment;
  final EmergencyPlatform? platform;

  @override
  String toString() =>
      'EmergencyStatus(${active ? 'active' : 'inactive${inactiveReason == null ? '' : ' ($inactiveReason)'}'}, '
      '${state.name}, revision: $revision, expiresAt: $expiresAt, '
      'lastFetchAt: $lastFetchAt, lastError: $lastError, '
      'credentialRejected: $credentialRejected)';
}

/// Failure modes by exact key and `prefix.*` (§7.4).
final class EmergencyFailureModes {
  EmergencyFailureModes(Map<String, EmergencyFailureMode> modes) {
    final prefixes = <(String, EmergencyFailureMode)>[];
    for (final e in modes.entries) {
      if (!isEmergencyKeyPattern(e.key)) {
        debugPrint(
          '[bugcapsule] emergency: ignoring failure mode for "${e.key}": '
          'not a feature key or prefix.*',
        );
        continue;
      }
      if (e.key.endsWith('.*')) {
        prefixes.add((e.key, e.value));
      } else {
        _exact[e.key] = e.value;
      }
    }
    prefixes.sort((a, b) => b.$1.length.compareTo(a.$1.length));
    _prefixes = prefixes;
  }

  static final defaults = EmergencyFailureModes(const {});

  final Map<String, EmergencyFailureMode> _exact = {};
  late final List<(String, EmergencyFailureMode)> _prefixes;

  EmergencyFailureMode modeFor(String featureKey) {
    final exact = _exact[featureKey];
    if (exact != null) return exact;
    for (final (pattern, mode) in _prefixes) {
      if (emergencyKeyMatches(pattern, featureKey)) return mode;
    }
    return EmergencyFailureMode.failOpen;
  }
}

/// The decision of a failure mode when no document can be used.
EmergencyDecision emergencyFailureDecision(
  String featureKey,
  EmergencyFailureMode mode,
) {
  final closed = mode == EmergencyFailureMode.failClosed;
  return EmergencyDecision(
    featureKey: featureKey,
    allowed: !closed,
    action: closed ? EmergencyAction.block : EmergencyAction.allow,
    source: EmergencyDecisionSource.failureMode,
    reasonCode: 'POLICY_UNAVAILABLE',
  );
}

/// While a capsule replays everything is allowed (§7.4).
EmergencyDecision emergencyReplayDecision(String featureKey) =>
    EmergencyDecision(
      featureKey: featureKey,
      allowed: true,
      action: EmergencyAction.allow,
      source: EmergencyDecisionSource.replay,
    );
