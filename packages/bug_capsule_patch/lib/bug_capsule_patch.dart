/// BugCapsule patch runtime: runs signed replacements of the module logic an
/// app registers, on an installed release build, with local rollback.
///
/// This replaces [PatchModule]s only. It cannot change arbitrary Dart code,
/// add plugins or permissions, or update the Flutter engine.
///
/// ```dart
/// final patch = BugCapsulePatch.open(config, modules: [coupon]);
/// final result = patch.call(coupon, cart); // never throws
/// if (firstScreenIsUsable) patch.markHealthy('first_screen');
/// ```
library;

export 'src/hotfix.dart';
export 'src/runtime.dart';
