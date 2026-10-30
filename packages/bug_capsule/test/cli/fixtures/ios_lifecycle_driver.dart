import 'dart:convert';
import 'dart:io';
import 'package:bug_capsule/src/cli/launcher.dart';
import 'package:bug_capsule/src/cli/launchers/ios.dart';
import 'package:bug_capsule/src/cli/processes.dart';
import 'package:bug_capsule/src/cli/project_config.dart';
import 'package:bug_capsule/src/cli/replay_server.dart';
import 'package:bug_capsule/src/core/core.dart';

Future<void> main(List<String> args) async {
  final root = args[0];
  final native = args[1] == 'native';
  final server = await ReplayServer.start();
  final options = LaunchOptions(
    projectDir: root,
    device: const Device('fixture', 'Fixture', 'ios', true),
    config: ProjectConfig.load(root),
    artifacts: {'xctestrun': '$root/products/fixture.xctestrun'},
  );
  final AppLauncher launcher = native
      ? IosNativeLauncher(options)
      : IosSimulatorLauncher(options);
  try {
    await launcher.prepare(server);
    final clock = Stopwatch()..start();
    try {
      final report = await launcher.attempt(
        server,
        [1],
        const ReplaySettings(kind: 'verify', attempt: 1),
        Duration(
          milliseconds: Platform.environment['FIXTURE_MODE'] == 'cleanup'
              ? 3000
              : Platform.environment['FIXTURE_MODE'] == 'budget'
              ? 2000
              : 800,
        ),
      );
      print(
        jsonEncode({
          'outcome': report.outcome.name,
          'elapsedMs': clock.elapsedMilliseconds,
        }),
      );
    } catch (e) {
      print(
        jsonEncode({'error': '$e', 'elapsedMs': clock.elapsedMilliseconds}),
      );
    }
  } finally {
    await launcher.dispose();
    await server.close();
    await Processes.stopAll();
  }
}
