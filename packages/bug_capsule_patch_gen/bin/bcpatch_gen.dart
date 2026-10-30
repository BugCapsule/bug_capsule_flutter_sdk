import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule_patch_gen/bug_capsule_patch_gen.dart';

/// `bcpatch_gen stubs <file.dart>` writes `<file>.patch.g.dart`.
/// `bcpatch_gen lower <file.dart> <out-dir>` writes one `.bpl` per function.
void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: bcpatch_gen stubs <file.dart> | lower <file.dart> <out-dir>');
    exit(64);
  }
  final file = File(args[1]);
  try {
    final unit = Unit(file.readAsStringSync());
    if (args[0] == 'stubs') {
      final name = file.uri.pathSegments.last;
      File(file.path.replaceAll(RegExp(r'\.dart$'), '.patch.g.dart')).writeAsStringSync(unit.stubs(name));
    } else {
      final dir = Directory(args[2])..createSync(recursive: true);
      for (final f in unit.patchables) {
        File('${dir.path}/${f.id}.bpl').writeAsStringSync(unit.lower(f));
      }
      stdout.writeln(jsonEncode([for (final f in unit.patchables) f.id]));
    }
  } on Unsupported catch (e) {
    stderr.writeln('${file.path}: $e');
    exit(2);
  }
}
