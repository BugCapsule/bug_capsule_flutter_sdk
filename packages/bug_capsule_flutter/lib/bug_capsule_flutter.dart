/// BugCapsule Flutter SDK: capture the context around a failure into a portable
/// `.bugcapsule` capsule, and replay it locally with the `bugcapsule` CLI.
library;

export 'package:bug_capsule_core/bug_capsule_core.dart';

export 'src/backend.dart' show OutboxLimits, BugCapsuleTransport, UploadResult, UploadStatus;
export 'src/config.dart';
export 'src/integration.dart';
export 'src/overlay.dart';
export 'src/state_tracker.dart';
export 'src/remote_config.dart'
    show ConfigFetchFailed, ConfigFetchResult, ConfigFetched, RemoteCaptureConfig;
export 'src/bug_capsule.dart';
