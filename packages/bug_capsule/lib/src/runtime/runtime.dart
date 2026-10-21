/// Internal barrel of the in-app runtime: init, capture, upload, kill switch,
/// replay engine and QA overlay. Apps import `package:bug_capsule/bug_capsule.dart`.
library;

export '../core/core.dart';

export 'backend.dart' show OutboxLimits, BugCapsuleTransport, UploadResult, UploadStatus;
export 'config.dart';
export 'integration.dart';
export 'overlay.dart';
export 'state_tracker.dart';
export 'remote_config.dart'
    show ConfigFetchFailed, ConfigFetchResult, ConfigFetched, RemoteCaptureConfig;
export 'bug_capsule.dart';
