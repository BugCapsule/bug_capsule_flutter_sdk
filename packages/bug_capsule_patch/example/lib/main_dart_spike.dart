import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'loyalty.dart';
import 'main.dart' show processInbox;

const baseBuildId = String.fromEnvironment('BCPATCH_BASE_BUILD', defaultValue: 'flutter-dart-1');

/// Research gate: an ordinary Dart function, patched from its changed Dart
/// source, on an obfuscated release build.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final exchange = Platform.isAndroid ? (await getExternalStorageDirectory())! : await getApplicationDocumentsDirectory();
  final patch = BugCapsulePatch.open(
    PatchConfig(
      storeDir: '${support.path}/bcpatch-dart',
      projectId: 'demo',
      applicationId: 'dev.bugcapsule.patchlab.flutter',
      environment: 'staging',
      platform: Platform.isAndroid ? 'flutter_android' : 'flutter_ios',
      distributionProfile: 'development',
      baseBuildId: baseBuildId,
      installationId: 'device-1',
      trustRoots: const ['bcpk.v1.dev-root-1.BA4PNvbk7UmdPR93U56lG_Bpqwq3WgzIrI3zk7IuT-hKhRymUfOY4eQFQGei0tjUkzmpyqaHCZf3MtgxbBxq68U'],
    ),
    modules: patchableModules,
  );
  PatchDispatch.install(patch);
  final watch = Stopwatch()..start();
  final points = loyaltyPoints(12345, 2);
  final micros = watch.elapsedMicroseconds;
  final before = patch.status();
  final inbox = processInbox(patch, exchange);
  patch.markHealthy('first_screen');
  final running = before['running'] as Map<String, Object?>?;
  final record = {
    'at': DateTime.now().toUtc().toIso8601String(),
    'mode': const bool.fromEnvironment('dart.vm.product') ? 'release' : 'debug',
    'platform': Platform.operatingSystem,
    'baseBuildId': baseBuildId,
    'source': running == null ? 'bundled' : 'patched',
    'reason': null,
    'output': {'total': '$points', 'label': 'points'},
    'evalMicros': micros,
    'state': before['state'],
    'running': running,
    'inbox': inbox,
    'status': patch.status(),
  };
  File('${exchange.path}/results.jsonl').writeAsStringSync('${jsonEncode(record)}\n', mode: FileMode.append, flush: true);
  runApp(Directionality(textDirection: TextDirection.ltr, child: Center(child: Text('points $points'))));
}
