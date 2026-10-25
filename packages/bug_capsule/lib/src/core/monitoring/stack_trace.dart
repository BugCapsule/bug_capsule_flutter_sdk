import 'model.dart';

/// Which Dart packages are app code (`inApp`). Defaults: the app's own
/// package; `dart:` libraries and `package:flutter/` are never app code.
class InAppRules {
  const InAppRules({this.includes = const [], this.excludes = const []});

  /// Package names (`shop_app`) whose frames are app code.
  final List<String> includes;

  /// Package names that are never app code, even when listed in [includes].
  final List<String> excludes;

  bool? isInApp(String? package, String? absPath) {
    if (absPath != null &&
        (absPath.startsWith('dart:') ||
            absPath.startsWith('org-dartlang-sdk:'))) {
      return false;
    }
    if (package == null) return absPath == null ? null : false;
    if (package == 'flutter' ||
        package == 'bug_capsule' ||
        excludes.contains(package)) {
      return false;
    }
    return includes.contains(package);
  }
}

/// A parsed Dart stack trace.
class ParsedStack {
  const ParsedStack(
    this.frames, {
    this.debugImages = const [],
    this.native = false,
  });

  /// Oldest call first, crashing frame last.
  final List<EventFrame> frames;

  /// The `elf` image of an AOT trace (`--split-debug-info` / obfuscated builds).
  final List<Map<String, Object?>> debugImages;

  /// True for an AOT non-symbolic trace (frames carry `instructionAddr`).
  final bool native;
}

final _vmFrame = RegExp(r'^#\d+\s+(.+?) \((.+)\)$');
final _location = RegExp(r'^(.*?)(?::(\d+))?(?::(\d+))?$');
final _aotFrame = RegExp(
  r'^\s*#\d+\s+abs\s+([0-9a-fA-F]+)(?:\s+virt\s+([0-9a-fA-F]+))?\s*(.*)$',
);
final _v8Frame = RegExp(r'^\s*at (?:(.+?) \((.+)\)|(.+))$');
final _terseFrame = RegExp(r'^(\S+) (\d+):(\d+)\s+(.*)$');
final _buildId = RegExp(r"build_id: '([0-9a-fA-F]+)'");
final _dsoBase = RegExp(r'isolate_dso_base: ([0-9a-fA-F]+)');
final _osArch = RegExp(r'os: (\S+) arch: (\S+)');

/// Parses the VM (JIT and symbolic AOT), AOT non-symbolic
/// (`--split-debug-info`, `--obfuscate`), Chrome/V8 and `package:stack_trace`
/// terse formats. Unrecognised lines are skipped; asynchronous suspension
/// markers are dropped.
ParsedStack parseDartStack(
  String trace, {
  InAppRules rules = const InAppRules(),
}) {
  final lines = trace.split('\n');
  if (trace.contains('*** *** ***') ||
      lines.any((l) => _aotFrame.hasMatch(l))) {
    return _parseNative(lines);
  }
  final frames = <EventFrame>[];
  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.isEmpty || line.contains('<asynchronous suspension>')) continue;
    final frame =
        _parseVm(line, rules) ??
        _parseV8(line, rules) ??
        _parseTerse(line, rules);
    if (frame != null) frames.add(frame);
  }
  return ParsedStack(frames.reversed.toList());
}

EventFrame? _parseVm(String line, InAppRules rules) {
  final m = _vmFrame.firstMatch(line.trimLeft());
  if (m == null) return null;
  final loc = _location.firstMatch(m[2]!)!;
  return _frame(
    m[1]!,
    loc[1]!,
    int.tryParse(loc[2] ?? ''),
    int.tryParse(loc[3] ?? ''),
    rules,
  );
}

EventFrame? _parseV8(String line, InAppRules rules) {
  final m = _v8Frame.firstMatch(line);
  if (m == null) return null;
  final loc = _location.firstMatch(m[2] ?? m[3]!)!;
  return _frame(
    m[1] ?? '<anonymous>',
    loc[1]!,
    int.tryParse(loc[2] ?? ''),
    int.tryParse(loc[3] ?? ''),
    rules,
  );
}

EventFrame? _parseTerse(String line, InAppRules rules) {
  final m = _terseFrame.firstMatch(line.trim());
  if (m == null) return null;
  return _frame(m[4]!, m[1]!, int.parse(m[2]!), int.parse(m[3]!), rules);
}

EventFrame _frame(
  String member,
  String uri,
  int? line,
  int? column,
  InAppRules rules,
) {
  String? package;
  String? filename;
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    package = slash < 0 ? rest : rest.substring(0, slash);
    filename = slash < 0 ? rest : rest.substring(slash + 1);
  } else if (uri.startsWith('packages/') || uri.contains('/packages/')) {
    // Flutter web (DDC): `packages/<package>/<path>`.
    final rest = uri.substring(uri.indexOf('packages/') + 'packages/'.length);
    final slash = rest.indexOf('/');
    package = slash < 0 ? rest : rest.substring(0, slash);
    filename = slash < 0 ? rest : rest.substring(slash + 1);
  } else if (uri.startsWith('dart:')) {
    filename = uri.substring('dart:'.length);
  } else {
    final segments = Uri.tryParse(uri)?.pathSegments ?? const <String>[];
    filename = segments.isEmpty ? uri : segments.last;
  }
  return EventFrame(
    function: member.trim(),
    filename: filename,
    absPath: uri,
    lineno: line,
    colno: column,
    package: package,
    inApp: rules.isInApp(package, uri),
  );
}

ParsedStack _parseNative(List<String> lines) {
  String? buildId;
  String? dsoBase;
  String? os;
  String? arch;
  final frames = <EventFrame>[];
  for (final line in lines) {
    buildId ??= _buildId.firstMatch(line)?[1];
    dsoBase ??= _dsoBase.firstMatch(line)?[1];
    final osArch = _osArch.firstMatch(line);
    if (osArch != null) {
      os = osArch[1];
      arch = osArch[2];
    }
    final m = _aotFrame.firstMatch(line);
    if (m == null) continue;
    final abs = BigInt.parse(m[1]!, radix: 16);
    if (dsoBase == null && m[2] != null) {
      // Older VMs print no `isolate_dso_base`: abs - virt is the load address.
      dsoBase = (abs - BigInt.parse(m[2]!, radix: 16)).toRadixString(16);
    }
    final symbol = m[3]!.trim();
    // The first frame printed is the crashing one and carries the exact PC;
    // every caller frame carries a return address, so step back into the
    // call instruction (monitoring-v1 §3: the backend resolves as sent).
    final pc = frames.isEmpty ? abs : abs - BigInt.one;
    frames.add(
      EventFrame(
        instructionAddr: '0x${pc.toRadixString(16)}',
        // `_kDartIsolateSnapshotInstructions+0x1c3f3b` is not a function name.
        function: symbol.isEmpty || symbol.startsWith('_kDart') ? null : symbol,
        inApp: true,
      ),
    );
  }
  final images = <Map<String, Object?>>[];
  if (buildId != null) {
    final base = dsoBase == null ? null : BigInt.parse(dsoBase, radix: 16);
    images.add({
      'type': 'elf',
      'debugId': debugIdFromBuildId(buildId),
      'codeId': buildId.toLowerCase(),
      'codeFile': switch (os) {
        'ios' => 'App.framework/App',
        'macos' => 'App.framework/Versions/A/App',
        _ => 'libapp.so',
      },
      if (base != null) 'imageAddr': '0x${base.toRadixString(16)}',
      'arch': ?_arch(arch),
    });
    if (base != null) {
      for (final f in frames) {
        f.imageAddr = '0x${base.toRadixString(16)}';
      }
    }
  }
  return ParsedStack(
    frames.reversed.toList(),
    debugImages: images,
    native: true,
  );
}

String? _arch(String? dartArch) => switch (dartArch) {
  null => null,
  'x64' => 'x86_64',
  'ia32' => 'x86',
  _ => dartArch,
};

/// GNU build id → debug id (monitoring-v1 §3): the first 16 bytes (zero
/// padded), with the first three UUID fields byte-swapped (little-endian),
/// formatted as a UUID — the same rule `bugcapsule symbols upload` applies
/// to the `.symbols` file's build-id note.
String debugIdFromBuildId(String hex) {
  final clean = hex.toLowerCase().replaceAll(RegExp('[^0-9a-f]'), '');
  return debugIdFromBuildIdBytes([
    for (var i = 0; i + 1 < clean.length && i < 32; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String debugIdFromBuildIdBytes(List<int> buildId) {
  final b = [...buildId.take(16), for (var i = buildId.length; i < 16; i++) 0];
  final swapped = [
    b[3],
    b[2],
    b[1],
    b[0],
    b[5],
    b[4],
    b[7],
    b[6],
    ...b.sublist(8),
  ];
  final h = swapped.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}
