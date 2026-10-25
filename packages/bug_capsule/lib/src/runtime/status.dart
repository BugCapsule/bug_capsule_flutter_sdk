/// Where the SDK stands with the backend (`BugCapsule.status.connection.state`).
enum BugCapsuleConnectionState {
  /// No token and no backend: the app runs without BugCapsule uploads.
  notConfigured('not_configured'),

  /// The token can't be used (see `message`); the app runs without BugCapsule.
  invalidToken('invalid_token'),

  /// The token's version needs a newer SDK; the app runs without BugCapsule.
  unsupportedTokenVersion('unsupported_token_version'),

  /// No config fetched yet in this session.
  connecting('connecting'),

  /// The config was fetched in this session (basic connectivity).
  connected('connected'),

  /// The backend can't be reached (network error, timeout, 5xx, 408, 429);
  /// data waits in the outbox and is retried with backoff.
  offline('offline'),

  /// The backend refused the credential (`reason`: `token_revoked`,
  /// `token_expired`, `token_unknown`, `key_unknown_or_revoked`, ...).
  /// Capture and uploads are off for this session.
  rejected('rejected'),

  /// `enabled: false`, or capture switched off by the backend.
  disabled('disabled');

  const BugCapsuleConnectionState(this.code);

  /// The cross-SDK name, e.g. `not_configured`.
  final String code;
}

/// How the backend was configured.
enum BugCapsuleConnectionSource {
  /// `BugCapsuleConfig.token`.
  token,

  /// `BugCapsuleConfig.backend` (explicit URL and ingest key).
  backend,
}

class BugCapsuleConnectionStatus {
  const BugCapsuleConnectionStatus({
    required this.state,
    this.source,
    this.apiUrl,
    this.reason,
    this.message,
    this.configFetchedAt,
    this.firstEventAcceptedAt,
    this.firstCapsuleAcceptedAt,
  });

  final BugCapsuleConnectionState state;
  final BugCapsuleConnectionSource? source;

  /// The API the SDK talks to, from the token or the explicit backend.
  final String? apiUrl;

  /// Machine-readable cause: the token error code, the backend's refusal
  /// reason (e.g. `token_revoked`) or the last network error.
  final String? reason;

  /// What to do about it, for people.
  final String? message;

  /// Confirmation 1 (configuration fetched): the last time in this session
  /// the SDK reached the backend with a valid credential.
  final DateTime? configFetchedAt;

  /// Confirmation 2 (data received): the first time in this session the
  /// backend accepted an error event / a Capsule.
  final DateTime? firstEventAcceptedAt;
  final DateTime? firstCapsuleAcceptedAt;

  Map<String, Object?> toJson() => {
    'state': state.code,
    'source': source?.name,
    'apiUrl': apiUrl,
    'reason': reason,
    'message': message,
    'configFetchedAt': configFetchedAt?.toUtc().toIso8601String(),
    'firstEventAcceptedAt': firstEventAcceptedAt?.toUtc().toIso8601String(),
    'firstCapsuleAcceptedAt': firstCapsuleAcceptedAt?.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'BugCapsuleConnectionStatus(${toJson()})';
}

/// Which replay instrumentation is set up. Connecting to the backend is not
/// complete replay: these are the progressive setup steps.
class BugCapsuleInstrumentationStatus {
  const BugCapsuleInstrumentationStatus({
    required this.recording,
    required this.network,
    required this.navigation,
    required this.appState,
    required this.integrations,
    required this.missing,
  });

  /// This session records (enabled, sampled in, not switched off).
  final bool recording;

  /// Network responses are captured as replay fixtures (`BugCapsuleDio`,
  /// `BugCapsuleHttp`).
  final bool network;

  /// Routes are recorded and restored (`BugCapsuleGoRouter`).
  /// `BugCapsuleNavigatorObserver` adds monitoring breadcrumbs only.
  final bool navigation;

  /// App state is snapshotted and restored (`BugCapsuleBloc`,
  /// `BugCapsuleRiverpod`, `BugCapsuleNotifiers`, `BugCapsuleGetx`,
  /// `BugCapsuleMobx`, `BugCapsuleSharedPreferences`).
  final bool appState;

  /// Names of the integrations passed to `BugCapsule.init`.
  final List<String> integrations;

  /// Steps still to set up: `network`, `navigation`, `app_state`.
  final List<String> missing;

  Map<String, Object?> toJson() => {
    'recording': recording,
    'network': network,
    'navigation': navigation,
    'appState': appState,
    'integrations': integrations,
    'missing': missing,
  };

  @override
  String toString() => 'BugCapsuleInstrumentationStatus(${toJson()})';
}

/// Connection and instrumentation, for setup checks and support
/// (`BugCapsule.status`).
class BugCapsuleStatus {
  const BugCapsuleStatus({
    required this.connection,
    required this.instrumentation,
  });

  final BugCapsuleConnectionStatus connection;
  final BugCapsuleInstrumentationStatus instrumentation;

  Map<String, Object?> toJson() => {
    'connection': connection.toJson(),
    'instrumentation': instrumentation.toJson(),
  };

  @override
  String toString() => 'BugCapsuleStatus(${toJson()})';
}
