import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Platform protection of the SDK's storage root (BC-ENT-038): on iOS,
/// exclusion from iCloud and device backups and the
/// `completeUntilFirstUserAuthentication` file protection class. Dart has no
/// API for either, so a native plugin provides it: `bug_capsule_native`
/// registers itself as [instance] when it is a dependency of the app.
/// Android needs none: the root is in `noBackupFilesDir` ([sdkStorageRoot]).
abstract class BugCapsuleStorageProtection {
  static BugCapsuleStorageProtection? instance;

  /// Applies the protection to [root] and what it holds. Best effort: a
  /// failure is reported by the implementation and never reaches the app.
  Future<void> protect(Directory root);
}

Future<Directory>? _root;

/// The SDK's storage root: `<application support>/bugcapsule`, except on
/// Android, where it is `<noBackupFilesDir>/bugcapsule` so Auto Backup never
/// copies captures off the device. Resolved once per process; the first
/// call moves an Android root left in `files/` by an older SDK.
Future<Directory> sdkStorageRoot() {
  final pending = _root ??= _resolve();
  // A failure (no binding yet, plugin missing) is not cached.
  pending.then((_) {}, onError: (Object _) => _root = null);
  return pending;
}

Future<Directory> _resolve() async {
  final support = await getApplicationSupportDirectory();
  final legacy = Directory('${support.path}/bugcapsule');
  final noBackup = Platform.isAndroid
      ? androidNoBackupDirectory(support)
      : null;
  final root = noBackup == null
      ? legacy
      : Directory('${noBackup.path}/bugcapsule');
  if (noBackup != null) await moveLegacyRoot(legacy, root);
  final protection = BugCapsuleStorageProtection.instance;
  if (protection != null) {
    unawaited(
      root
          .create(recursive: true)
          .then(protection.protect)
          .then(
            (_) {},
            onError: (Object e) =>
                debugPrint('[bugcapsule] could not protect local storage: $e'),
          ),
    );
  }
  return root;
}

/// `Context.getNoBackupFilesDir()` is `<dataDir>/no_backup`, next to
/// `getFilesDir()` (`<dataDir>/files`), which is what path_provider returns
/// as the application support directory. Null when [support] is not laid
/// out like that; the root then stays in [support].
@visibleForTesting
Directory? androidNoBackupDirectory(Directory support) {
  final segments = support.uri.pathSegments.where((s) => s.isNotEmpty);
  if (segments.isEmpty || segments.last != 'files') return null;
  return Directory('${support.parent.path}/no_backup');
}

/// Moves what an older SDK kept in [legacy] to [root] (one rename on the
/// same volume); if [root] already exists, the leftover is deleted instead,
/// so nothing stays where backups reach it.
@visibleForTesting
Future<void> moveLegacyRoot(Directory legacy, Directory root) async {
  try {
    if (!await legacy.exists()) return;
    if (await root.exists()) {
      await legacy.delete(recursive: true);
    } else {
      await root.parent.create(recursive: true);
      await legacy.rename(root.path);
    }
  } catch (e) {
    debugPrint('[bugcapsule] could not move local data out of backups: $e');
  }
}
