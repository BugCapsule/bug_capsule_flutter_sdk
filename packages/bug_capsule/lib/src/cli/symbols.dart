import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';

import '../core/core.dart';
import 'backend_client.dart';
import 'term.dart';

/// The GNU build id (`NT_GNU_BUILD_ID` note) of an ELF file, as bytes, or
/// null when [bytes] is not ELF or has no build-id note. Reads section
/// headers first, then program headers.
List<int>? elfBuildId(Uint8List bytes) {
  if (bytes.length < 52 ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46) {
    return null;
  }
  final is64 = bytes[4] == 2;
  final endian = bytes[5] == 2 ? Endian.big : Endian.little;
  final data = ByteData.sublistView(bytes);
  int u16(int o) => data.getUint16(o, endian);
  int u32(int o) => data.getUint32(o, endian);
  int word(int o) =>
      is64 ? data.getUint64(o, endian) : data.getUint32(o, endian);

  List<int>? notes(int offset, int size) {
    var p = offset;
    final end = offset + size;
    if (offset < 0 || end > bytes.length) return null;
    while (p + 12 <= end) {
      final nameSize = u32(p);
      final descSize = u32(p + 4);
      final type = u32(p + 8);
      final nameStart = p + 12;
      final descStart = nameStart + ((nameSize + 3) & ~3);
      if (descStart + descSize > end) return null;
      final name = String.fromCharCodes(
        bytes.sublist(nameStart, nameStart + nameSize),
      ).replaceAll('\x00', '');
      if (type == 3 && name == 'GNU') {
        return bytes.sublist(descStart, descStart + descSize);
      }
      p = descStart + ((descSize + 3) & ~3);
    }
    return null;
  }

  try {
    final shoff = word(is64 ? 0x28 : 0x20);
    final shentsize = u16(is64 ? 0x3a : 0x2e);
    final shnum = u16(is64 ? 0x3c : 0x30);
    for (var i = 0; i < shnum; i++) {
      final sh = shoff + i * shentsize;
      if (sh + shentsize > bytes.length) break;
      if (u32(sh + 4) != 7) continue; // SHT_NOTE
      final found = notes(
        word(sh + (is64 ? 0x18 : 0x10)),
        word(sh + (is64 ? 0x20 : 0x14)),
      );
      if (found != null) return found;
    }
    final phoff = word(is64 ? 0x20 : 0x1c);
    final phentsize = u16(is64 ? 0x36 : 0x2a);
    final phnum = u16(is64 ? 0x38 : 0x2c);
    for (var i = 0; i < phnum; i++) {
      final ph = phoff + i * phentsize;
      if (ph + phentsize > bytes.length) break;
      if (u32(ph) != 4) continue; // PT_NOTE
      final found = notes(
        word(ph + (is64 ? 0x08 : 0x04)),
        word(ph + (is64 ? 0x20 : 0x10)),
      );
      if (found != null) return found;
    }
  } on RangeError {
    return null;
  }
  return null;
}

/// The `LC_UUID` of a Mach-O file (thin, or the first slice of a fat
/// file), or null. Dart writes AOT snapshots and their `--split-debug-info`
/// files as Mach-O on iOS and macOS, and prints this UUID as `build_id`.
List<int>? machoUuid(Uint8List bytes) {
  if (bytes.length < 32) return null;
  final data = ByteData.sublistView(bytes);
  final magicBe = data.getUint32(0, Endian.big);
  if (magicBe == 0xcafebabe) {
    // Fat: big-endian header, first architecture's slice.
    if (data.getUint32(4, Endian.big) == 0 || bytes.length < 28) return null;
    final offset = data.getUint32(16, Endian.big);
    final size = data.getUint32(20, Endian.big);
    if (offset + size > bytes.length) return null;
    return machoUuid(Uint8List.sublistView(bytes, offset, offset + size));
  }
  final Endian endian;
  final bool is64;
  switch (data.getUint32(0, Endian.little)) {
    case 0xfeedfacf:
      (endian, is64) = (Endian.little, true);
    case 0xfeedface:
      (endian, is64) = (Endian.little, false);
    default:
      switch (magicBe) {
        case 0xfeedfacf:
          (endian, is64) = (Endian.big, true);
        case 0xfeedface:
          (endian, is64) = (Endian.big, false);
        default:
          return null;
      }
  }
  final ncmds = data.getUint32(16, endian);
  var p = is64 ? 32 : 28;
  for (var i = 0; i < ncmds && p + 8 <= bytes.length; i++) {
    final cmd = data.getUint32(p, endian);
    final size = data.getUint32(p + 4, endian);
    if (cmd == 0x1b && p + 24 <= bytes.length) {
      return bytes.sublist(p + 8, p + 24); // LC_UUID
    }
    if (size < 8) return null;
    p += size;
  }
  return null;
}

/// The id Dart prints as `build_id` in non-symbolic stack traces: the GNU
/// build id of an ELF file, or the `LC_UUID` of a Mach-O file.
List<int>? snapshotBuildId(Uint8List bytes) =>
    elfBuildId(bytes) ?? machoUuid(bytes);

/// One file sent (or, with `dryRun`, to be sent) to `POST /v1/debug-files`.
class DebugFileUpload {
  const DebugFileUpload(this.kind, this.file, this.query);

  final String kind;
  final File file;
  final Map<String, String> query;

  @override
  String toString() =>
      '$kind ${file.uri.pathSegments.last} (${[for (final e in query.entries) '${e.key}=${e.value}'].join(', ')})';
}

final _symbolsName = RegExp(r'^app\.([a-z]+)-([a-z0-9_]+)\.symbols$');
final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$',
);

/// The uploads for a `--split-debug-info` directory (each `*.symbols` file,
/// `kind=elf`, debug id from its build id with the same rule the SDK applies
/// to the `build_id` of a stack trace; ELF on Android, Mach-O on iOS/macOS) and an obfuscation map
/// (`kind=dart_obfuscation`, debug id = the build's
/// `BUGCAPSULE_OBFUSCATION_ID`). Throws [StateError] for unusable input.
Future<List<DebugFileUpload>> planSymbolUploads({
  String? splitDebugInfo,
  String? obfuscationMap,
  String? obfuscationId,
  String? release,
}) async {
  final plan = <DebugFileUpload>[];
  if (splitDebugInfo != null) {
    final dir = Directory(splitDebugInfo);
    if (!dir.existsSync()) throw StateError('$splitDebugInfo does not exist');
    final files = [
      await for (final e in dir.list(recursive: true))
        if (e is File && e.path.endsWith('.symbols')) e,
    ]..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      throw StateError('no *.symbols files in $splitDebugInfo');
    }
    for (final f in files) {
      final buildId = snapshotBuildId(await f.readAsBytes());
      if (buildId == null) {
        throw StateError(
          '${f.path} has no build id (neither an ELF build-id note nor a Mach-O LC_UUID)',
        );
      }
      final name = f.uri.pathSegments.last;
      final arch = _symbolsName.firstMatch(name)?[2];
      plan.add(
        DebugFileUpload('elf', f, {
          'debugId': debugIdFromBuildIdBytes(buildId),
          if (arch != null)
            'arch': switch (arch) {
              'x64' => 'x86_64',
              'ia32' => 'x86',
              _ => arch,
            },
          'name': name,
        }),
      );
    }
  }
  if (obfuscationMap != null) {
    final f = File(obfuscationMap);
    if (!f.existsSync()) throw StateError('$obfuscationMap does not exist');
    if (obfuscationId == null || !_uuid.hasMatch(obfuscationId)) {
      throw StateError(
        '--obfuscation-id must be the UUID passed as --dart-define=BUGCAPSULE_OBFUSCATION_ID',
      );
    }
    plan.add(
      DebugFileUpload('dart_obfuscation', f, {
        'debugId': obfuscationId.toLowerCase(),
        'release': ?release,
      }),
    );
  }
  if (plan.isEmpty) {
    throw StateError(
      'nothing to upload: pass --split-debug-info and/or --obfuscation-map',
    );
  }
  return plan;
}

class SymbolsCommand extends Command<int> {
  SymbolsCommand() {
    addSubcommand(_SymbolsUploadCommand());
    addSubcommand(_SymbolsNewIdCommand());
  }

  @override
  String get name => 'symbols';
  @override
  String get description =>
      'Upload Flutter debug symbols and obfuscation maps for symbolication.';
}

class _SymbolsUploadCommand extends Command<int> {
  _SymbolsUploadCommand() {
    argParser
      ..addOption(
        'split-debug-info',
        help: 'The directory passed to flutter build --split-debug-info.',
      )
      ..addOption(
        'obfuscation-map',
        help:
            'The file written by --extra-gen-snapshot-options=--save-obfuscation-map=.',
      )
      ..addOption(
        'obfuscation-id',
        help:
            'The UUID the build embedded with --dart-define=BUGCAPSULE_OBFUSCATION_ID (see `symbols new-id`).',
      )
      ..addOption(
        'release',
        help: 'Release the obfuscation map belongs to (com.shop.app@1.4.0+52).',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print what would be uploaded.',
      );
  }

  @override
  String get name => 'upload';
  @override
  String get description =>
      'Upload --split-debug-info symbols (kind=elf) and the obfuscation map '
      '(kind=dart_obfuscation) with the project secret key.';
  @override
  String get invocation =>
      'bugcapsule symbols upload --split-debug-info build/symbols '
      '[--obfuscation-map build/obfuscation.json --obfuscation-id <uuid>]';

  @override
  Future<int> run() async {
    final a = argResults!;
    final plan = await planSymbolUploads(
      splitDebugInfo: a['split-debug-info'] as String?,
      obfuscationMap: a['obfuscation-map'] as String?,
      obfuscationId: a['obfuscation-id'] as String?,
      release: a['release'] as String?,
    );
    if (a['dry-run'] == true) {
      for (final u in plan) {
        stdout.writeln('would upload $u');
      }
      return 0;
    }
    final creds = Credentials.load();
    if (creds == null) {
      throw StateError(
        'no backend configured; run `bugcapsule login`',
      );
    }
    final client = BackendClient(creds);
    for (final u in plan) {
      await client.uploadDebugFile(u.kind, u.query, await u.file.readAsBytes());
      stdout.writeln(green('uploaded $u'));
    }
    return 0;
  }
}

class _SymbolsNewIdCommand extends Command<int> {
  @override
  String get name => 'new-id';
  @override
  String get description =>
      'Print a new obfuscation id for --dart-define=BUGCAPSULE_OBFUSCATION_ID.';

  @override
  Future<int> run() async {
    stdout.writeln(uuidV4());
    return 0;
  }
}
