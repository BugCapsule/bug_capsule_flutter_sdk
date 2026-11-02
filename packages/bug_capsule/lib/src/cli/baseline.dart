import 'dart:convert';
import 'dart:io';

import '../core/core.dart';
import '../version.dart';
import 'patch_client.dart' show patchSha256;

/// How long a baseline result is reused (spec/verdict-v2.md).
const baselineCacheTtl = Duration(days: 7);

/// Identifies a baseline: the same capsule, the same baseline revision and
/// the same harness settings give the same answer.
String baselineKey({
  required List<int> capsuleBytes,
  required String revision,
  required String harness,
}) => patchSha256(
  utf8.encode(
    '${patchSha256(capsuleBytes)}|$revision|$bugCapsuleVersion|$harness',
  ),
).substring('sha256:'.length);

/// Baseline results under `<project>/bugcapsule/.cache/baselines/`.
class BaselineCache {
  BaselineCache(String projectDir)
    : _dir = Directory('$projectDir/bugcapsule/.cache/baselines');

  final Directory _dir;

  File _file(String key) => File('${_dir.path}/$key.json');

  /// A result younger than [baselineCacheTtl], marked cached; else null.
  BaselineResult? read(String key, {DateTime? now}) {
    final f = _file(key);
    try {
      if (!f.existsSync()) return null;
      final age = (now ?? DateTime.now()).difference(f.lastModifiedSync());
      if (age > baselineCacheTtl) return null;
      final r = BaselineResult.fromJson(
        (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>(),
      );
      return BaselineResult(
        revision: r.revision,
        attempts: r.attempts,
        reproduced: r.reproduced,
        cached: true,
      );
    } catch (_) {
      return null; // unreadable entries are re-run, never trusted
    }
  }

  void write(String key, BaselineResult result) {
    try {
      _dir.createSync(recursive: true);
      // Machine-local results: never committed with the project.
      final ignore = File('${_dir.parent.path}/.gitignore');
      if (!ignore.existsSync()) ignore.writeAsStringSync('*\n');
      _file(key).writeAsStringSync(jsonEncode(result.toJson()));
    } catch (_) {
      // a cache that can't be written only costs a re-run
    }
  }
}
