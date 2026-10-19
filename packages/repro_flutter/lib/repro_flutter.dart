/// Repro Flutter SDK: capture the context around a failure into a portable
/// `.repro` capsule, and replay it locally with the `repro` CLI.
library;

export 'package:repro_core/repro_core.dart';

export 'src/backend.dart' show UploadResult, UploadStatus;
export 'src/config.dart';
export 'src/integration.dart';
export 'src/overlay.dart';
export 'src/repro.dart';
