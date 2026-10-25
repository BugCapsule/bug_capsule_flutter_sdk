import 'dart:io';

import 'package:test/test.dart';

/// The `bugcapsule` CLI runs on the plain Dart VM, so it and the core it
/// shares with the runtime must not reach Flutter or the Flutter-only
/// libraries the integrations use.
void main() {
  test('core and CLI import nothing that needs Flutter', () {
    final allowed = RegExp(
      r"^import '(dart:(?!ui)|package:args/|package:bug_capsule/src/(core|cli)/|(?![a-z]+:)(?!.*(runtime|integrations)/))",
    );
    final offenders = <String>[];
    for (final dir in ['lib/src/core', 'lib/src/cli', 'bin']) {
      for (final file in Directory(
        dir,
      ).listSync(recursive: true).whereType<File>()) {
        for (final line in file.readAsLinesSync()) {
          if (line.startsWith('import ') && !allowed.hasMatch(line)) {
            offenders.add('${file.path}: $line');
          }
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
