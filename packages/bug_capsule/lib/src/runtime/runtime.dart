/// Internal barrel of the in-app runtime: init, capture, upload, kill switch,
/// replay engine and QA overlay. Apps import `package:bug_capsule/bug_capsule.dart`.
library;

export '../core/core.dart';

export 'backend.dart'
    show
        OutboxLimits,
        BugCapsuleTransport,
        EnvelopeTransport,
        UploadResult,
        UploadStatus;
export 'binding.dart';
export 'config.dart';
export 'connection_token.dart';
export 'emergency/contract.dart'
    show
        EmergencyAction,
        EmergencyDecision,
        EmergencyDecisionSource,
        EmergencyPlatform,
        EmergencyPolicy,
        EmergencyPolicyDocument,
        EmergencyRejection,
        EmergencyVersionRange;
export 'emergency/emergency.dart' show BugCapsuleEmergency;
export 'emergency/hotfix.dart'
    show
        EmergencyHotfix,
        HotfixAvailability,
        HotfixDownloadFailed,
        HotfixDownloadInProgress,
        HotfixNothingToDownload,
        HotfixProvider,
        HotfixRestartRequired,
        HotfixResult,
        HotfixState,
        HotfixStatus,
        HotfixUnavailable;
export 'emergency/types.dart'
    show
        EmergencyConfig,
        EmergencyDocumentState,
        EmergencyError,
        EmergencyFailureMode,
        EmergencySnapshot,
        EmergencyStatus;
export 'integration.dart';
export 'interactions.dart';
export 'overlay.dart';
export 'patch_binding.dart';
export 'state_tracker.dart';
export 'status.dart';
export 'remote_config.dart'
    show
        ConfigFetchFailed,
        ConfigFetchResult,
        ConfigFetched,
        RemoteCaptureConfig;
export 'bug_capsule.dart';
export 'monitoring/feedback.dart';
export 'monitoring/navigation.dart';
export 'monitoring/native.dart';
export 'monitoring/options.dart';
export 'monitoring/scope.dart' show Scope;
export 'monitoring/tracing.dart' show BugCapsuleSpan, BugCapsuleTransaction;
