import 'dart:io';

/// The persisted collection (consent) switch, BC-ENT-038: one file under the
/// SDK storage root, `1` or `0`. It survives `clearLocalData` and is read at
/// `init` before anything is captured or sent. Every access is guarded: a
/// choice that cannot be stored lasts for the process only.
File consentFile(Directory root) => File('${root.path}/collection_enabled');

/// The persisted choice, or null when none was made (or it is unreadable).
Future<bool?> readConsent(Directory root) async {
  try {
    final f = consentFile(root);
    if (!await f.exists()) return null;
    return switch ((await f.readAsString()).trim()) {
      '1' => true,
      '0' => false,
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// Persists the choice; false when it could not be stored.
Future<bool> writeConsent(Directory root, bool enabled) async {
  try {
    await root.create(recursive: true);
    final f = consentFile(root);
    final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsString(enabled ? '1' : '0', flush: true);
    await tmp.rename(f.path);
    return true;
  } catch (_) {
    return false;
  }
}
