/// Shorebird hotfix adapter for BugCapsule emergency recovery:
/// [BugCapsuleShorebird] reports which Shorebird patch a release runs and
/// downloads an available patch when the app asks. A downloaded patch
/// becomes active on the next app start; the app is never restarted.
///
/// ```dart
/// await BugCapsule.emergency.initialize(EmergencyConfig(
///   trustAnchor: 'bcek.v1.…',
///   hotfixProvider: BugCapsuleShorebird(),
/// ));
/// ```
library;

export 'package:shorebird_code_push/shorebird_code_push.dart' show UpdateTrack;

export 'src/shorebird.dart';
