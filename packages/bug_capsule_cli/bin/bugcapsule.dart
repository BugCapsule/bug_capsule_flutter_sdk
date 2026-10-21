import 'dart:io';

import 'package:bug_capsule_cli/bug_capsule_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runBugCapsule(args);
  await stdout.flush();
  exit(exitCode);
}
