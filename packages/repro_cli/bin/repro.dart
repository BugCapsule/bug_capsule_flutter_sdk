import 'dart:io';

import 'package:repro_cli/repro_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runRepro(args);
  await stdout.flush();
  exit(exitCode);
}
