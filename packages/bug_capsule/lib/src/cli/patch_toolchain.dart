import 'dart:convert';
import 'dart:io';

import 'patch_toolchain_data.dart';
export 'patch_toolchain_data.dart' show bundledPatchEngineCommit;

/// A fresh per-command directory avoids trusting a mutable shared compiler cache.
/// The caller deletes it after subprocesses finish, including on errors.
Directory materializePatchToolchain() {
  final files = (jsonDecode(
    utf8.decode(gzip.decode(base64Decode(bundledPatchToolchainBase64))),
  ) as Map).cast<String, String>();
  final directory = Directory.systemTemp.createTempSync('bugcapsule-compiler-');
  try {
    for (final entry in files.entries) {
      final parts = entry.key.split('/');
      if (parts.any((p) => p.isEmpty || p == '..' || p == '.') ||
          entry.key.contains('\\') ||
          entry.key.contains(':')) {
        throw StateError('Invalid embedded compiler path');
      }
      final file = File('${directory.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(base64Decode(entry.value), flush: true);
    }
    return directory;
  } on Object {
    directory.deleteSync(recursive: true);
    rethrow;
  }
}
