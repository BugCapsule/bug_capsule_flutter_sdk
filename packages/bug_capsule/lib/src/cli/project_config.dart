import 'dart:convert';
import 'dart:io';

import '../core/core.dart';

/// `bugcapsule.json` at the root of the app project: which runtime the
/// project is and how the CLI builds, installs and launches it for replay.
///
/// ```json
/// {
///   "runtime": "android",
///   "android": {"module": "app", "applicationId": "com.example.shop"},
///   "timeouts": {"buildSeconds": 900, "attemptSeconds": 120}
/// }
/// ```
///
/// Every key is optional; see `docs/cli-runtimes.md` for the full list per
/// runtime. Without the file the runtime is detected from the project
/// (`pubspec.yaml` → flutter, `settings.gradle(.kts)` → android,
/// `*.xcodeproj`/`*.xcworkspace` → ios, `package.json` → web).
class ProjectConfig {
  ProjectConfig._(this.dir, this.file, this.json);

  static const fileName = 'bugcapsule.json';
  static const runtimes = ['flutter', 'android', 'ios', 'web'];

  /// Loads `<dir>/bugcapsule.json` (an empty config when it is missing).
  /// Throws [StateError] for unreadable or mistyped files.
  static ProjectConfig load(String dir) {
    final file = File('$dir/$fileName');
    if (!file.existsSync()) return ProjectConfig._(dir, null, const {});
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw StateError('${file.path} is not valid JSON: ${e.message}');
    }
    if (json is! Map) throw StateError('${file.path} must hold a JSON object');
    final config = ProjectConfig._(dir, file, json.cast<String, Object?>());
    final runtime = config.json['runtime'];
    if (runtime != null && (runtime is! String || !runtimes.contains(runtime))) {
      throw StateError('${file.path}: "runtime" must be one of ${runtimes.join(', ')}');
    }
    return config;
  }

  final String dir;
  final File? file;
  final Map<String, Object?> json;

  String? get declaredRuntime => json['runtime'] as String?;

  /// The runtime's own section, e.g. `"android": {...}`.
  Map<String, Object?> section(String runtime) {
    final s = json[runtime];
    if (s == null) return const {};
    if (s is! Map) throw StateError('$fileName: "$runtime" must be an object');
    return s.cast<String, Object?>();
  }

  Map<String, Object?> get _timeouts => (json['timeouts'] as Map?)?.cast<String, Object?>() ?? const {};

  /// Build/install budget.
  Duration get buildTimeout => Duration(seconds: _int(_timeouts['buildSeconds']) ?? 1200);

  /// Per-attempt budget when set (otherwise derived from the capsule).
  Duration? get attemptTimeout {
    final s = _int(_timeouts['attemptSeconds']);
    return s == null ? null : Duration(seconds: s);
  }

  static int? _int(Object? v) => v is int ? v : v is String ? int.tryParse(v) : null;

  /// Typed accessors for a runtime section.
  String? string(String runtime, String key) {
    final v = section(runtime)[key];
    if (v == null) return null;
    if (v is! String) throw StateError('$fileName: "$runtime.$key" must be a string');
    return v;
  }

  /// The project's runtime: [override] (`--runtime`), else the file, else
  /// detection from the files in [dir]; null when nothing matches.
  String? resolveRuntime({String? override}) {
    if (override != null) return override;
    if (declaredRuntime != null) return declaredRuntime;
    return detectRuntime(dir);
  }

  static String? detectRuntime(String dir) {
    bool exists(String name) => File('$dir/$name').existsSync();
    if (exists('pubspec.yaml')) return 'flutter';
    if (exists('settings.gradle.kts') || exists('settings.gradle')) return 'android';
    final d = Directory(dir);
    if (d.existsSync() &&
        d.listSync().any((e) => e.path.endsWith('.xcodeproj') || e.path.endsWith('.xcworkspace'))) {
      return 'ios';
    }
    if (exists('package.json')) return 'web';
    return null;
  }
}

/// Why a capsule cannot replay in [projectRuntime], or null when it can.
/// Cross-runtime replay is not implemented (spec/runtimes-v1.md §12).
String? runtimeMismatch(Capsule capsule, String projectRuntime) {
  final captured = capsule.manifest.runtimeName;
  if (captured == projectRuntime) return null;
  return 'capsule was captured by the $captured runtime (${capsule.manifest.sdkName}); '
      'this project is $projectRuntime. Cross-runtime replay is not supported';
}
