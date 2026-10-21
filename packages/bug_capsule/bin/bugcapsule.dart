import 'dart:io';

import 'package:bug_capsule/src/cli/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runBugCapsule(args);
  await stdout.flush();
  exit(exitCode);
}
