import 'dart:convert';
import 'dart:io';
import 'package:bug_capsule/src/core/core.dart';
import 'package:bug_capsule/src/cli/launcher.dart';
import 'package:bug_capsule/src/cli/launchers/android.dart';
import 'package:bug_capsule/src/cli/project_config.dart';
import 'package:bug_capsule/src/cli/replay_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'waits for instrumentation cleanup before the next replay attempt',
    () async {
      final dir = Directory.systemTemp.createTempSync('bc-android-cleanup-');
      final server = await ReplayServer.start();
      final adb = File('${dir.path}/platform-tools/adb')
        ..createSync(recursive: true);
      adb.writeAsStringSync(r'''#!/usr/bin/env python3
import sys, pathlib, json, time, urllib.request
root=pathlib.Path(__file__).resolve().parent.parent
args=sys.argv[1:]
if args and args[0]=='-s': args=args[2:]
if args==['devices']: print('List of devices attached\nfixture\tdevice')
elif args[:2]==['shell','getprop']: print('34' if args[-1].endswith('.sdk') else 'Fixture')
elif args[:3]==['shell','pm','clear'] or args[:1]==['install']: print('Success')
elif args[:3]==['shell','am','instrument']:
    pending=root/'cleanup-pending'
    if pending.exists():
        print('INSTRUMENTATION_FAILED: previous attempt still cleaning up',flush=True)
        sys.exit(1)
    pending.write_text('pending')
    url=args[args.index('bugcapsuleReplayUrl')+1]
    settings=json.load(urllib.request.urlopen(url+'/settings'))
    report={'outcome':'reproduced','attempt':settings['attempt'],'attemptId':settings['attemptId'],
            'durationMs':1,'strategy':'pointer','eventsDispatched':1,'eventsExpected':1,'fixturesServed':0}
    print('BUGCAPSULE_RESULT::'+json.dumps(report),flush=True)
    time.sleep(0.4)
    pending.unlink()
    (root/('cleaned-'+str(settings['attempt']))).write_text('done')
''');
      await Process.run('chmod', ['+x', adb.path]);
      final apk = File('${dir.path}/app.apk')..writeAsStringSync('fixture');
      File('${dir.path}/bugcapsule.json').writeAsStringSync(
        jsonEncode({
          'runtime': 'android',
          'android': {'sdkDir': dir.path, 'applicationId': 'fixture.app'},
        }),
      );
      final launcher = AndroidLauncher(
        LaunchOptions(
          runtime: 'android',
          projectDir: dir.path,
          config: ProjectConfig.load(dir.path),
          artifacts: {'apk': apk.path, 'test-apk': apk.path},
        ),
      );
      try {
        await launcher.prepare(server);
        for (var attempt = 1; attempt <= 2; attempt++) {
          final report = await launcher.attempt(
            server,
            [1],
            ReplaySettings(attempt: attempt, runtime: 'android'),
            const Duration(seconds: 5),
          );
          expect(report.outcome, ReplayOutcome.reproduced);
          expect(
            File('${dir.path}/cleaned-$attempt').existsSync(),
            isTrue,
            reason: 'the HTTP/status result precedes ActivityScenario cleanup',
          );
        }
      } finally {
        await launcher.dispose();
        await server.close();
        dir.deleteSync(recursive: true);
      }
    },
    skip: Platform.isWindows ? 'uses a POSIX fake adb executable' : false,
  );
}
