import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/src/cli/crash_detection.dart';
import 'package:bug_capsule/src/cli/launcher.dart';
import 'package:bug_capsule/src/cli/launchers/android.dart';
import 'package:bug_capsule/src/cli/project_config.dart';
import 'package:bug_capsule/src/cli/replay_server.dart';
import 'package:bug_capsule/src/core/core.dart';
import 'package:test/test.dart';

final _segv = FailureRecord.crash(
  type: 'SIGSEGV',
  message: 'Segmentation violation',
  t: 100,
  crash: const CrashInfo(
    mechanism: 'signal',
    signal: 11,
    inAppFrame: 'checkout_native',
  ),
);

ReplayReport _died(ObservedCrash crash, {int attempt = 1}) => ReplayReport(
  outcome: ReplayOutcome.error,
  attempt: attempt,
  durationMs: 10,
  strategy: ReplayStrategy.auto,
  message: 'the app exited before reporting',
  crash: crash,
);

const _logcat = '''
--------- beginning of crash
10-26 10:00:05.100  4242  4242 F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 4242 (fixture.app), pid 4242 (fixture.app)
10-26 10:00:05.300  4300  4300 F DEBUG   : backtrace:
10-26 10:00:05.300  4300  4300 F DEBUG   :       #00 pc 00000000000a1b2c  /apex/com.android.runtime/lib64/bionic/libc.so (memcpy+12)
10-26 10:00:05.300  4300  4300 F DEBUG   :       #01 pc 0000000000001234  /data/app/~~x==/fixture.app-y==/lib/arm64/libflutter.so (BuildId: 1)
10-26 10:00:05.300  4300  4300 F DEBUG   :       #02 pc 0000000000005678  /data/app/~~x==/fixture.app-y==/lib/arm64/libshop.so (checkout_native+40)
''';

const _exitBefore = '''
ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)
  package: fixture.app
    Historical Process Exit for uid=10123
        ApplicationExitInfo #0:
          timestamp=2026-10-26 09:00:00.000 pid=4000 realUid=10123 packageUid=10123 definingUid=10123 user=0
          process=fixture.app reason=10 (USER_REQUESTED) subreason=0 (UNKNOWN) status=0
''';

const _exitAfter = '''
ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)
  package: fixture.app
    Historical Process Exit for uid=10123
        ApplicationExitInfo #0:
          timestamp=2026-10-26 10:00:05.400 pid=4242 realUid=10123 packageUid=10123 definingUid=10123 user=0
          process=fixture.app reason=5 (CRASH_NATIVE) subreason=0 (UNKNOWN) status=11
        ApplicationExitInfo #1:
          timestamp=2026-10-26 09:00:00.000 pid=4000 realUid=10123 packageUid=10123 definingUid=10123 user=0
          process=fixture.app reason=10 (USER_REQUESTED) subreason=0 (UNKNOWN) status=0
''';

String _ips({String type = 'EXC_BAD_ACCESS', String signal = 'SIGSEGV'}) =>
    '${jsonEncode({'app_name': 'Runner', 'bundleID': 'com.shop.app', 'bug_type': '309'})}\n'
    '${jsonEncode({
      'pid': 777,
      'procName': 'Runner',
      'exception': {'type': type, 'signal': signal, 'subtype': 'KERN_INVALID_ADDRESS at 0x0'},
      'faultingThread': 0,
      'usedImages': [
        {'name': 'libsystem_platform.dylib', 'path': '/usr/lib/system/libsystem_platform.dylib'},
        {'name': 'Runner', 'path': '/Users/x/Library/Developer/CoreSimulator/Devices/y/data/Containers/Bundle/Application/z/Runner.app/Runner'},
      ],
      'threads': [
        {
          'triggered': true,
          'frames': [
            {'imageIndex': 0, 'symbol': '_platform_memmove'},
            {'imageIndex': 1, 'symbol': 'checkout_native'},
          ],
        },
      ],
    })}';

void main() {
  group('resolveCrash (crash-capsules §4)', () {
    test('the same crash type reproduces the crash capsule', () {
      final report = resolveCrash(
        _died(
          const ObservedCrash(
            type: 'SIGSEGV',
            signal: 11,
            inAppFrame: 'checkout_native',
          ),
        ),
        _segv,
      );
      expect(report.outcome, ReplayOutcome.reproduced);
      expect(report.expectedSignature, 'crash:SIGSEGV');
      expect(report.observed!.signature, 'crash:SIGSEGV');
      final run = evaluateRun(RunKind.verify, 1, [report]);
      expect(run.verdict, Verdict.stillFailing);
      expect(run.reasonCodes, isEmpty);
    });

    test('another in-app frame still reproduces, with its reason code', () {
      final report = resolveCrash(
        _died(const ObservedCrash(type: 'SIGSEGV', inAppFrame: 'pay_native')),
        _segv,
      );
      final run = evaluateRun(RunKind.replay, 1, [report]);
      expect(run.verdict, Verdict.reproduced);
      expect(run.reasonCodes, ['failure.different_frame']);
    });

    test('a signal number matches the recorded type (iOS Mach + signal)', () {
      final report = resolveCrash(
        _died(const ObservedCrash(type: 'EXC_BAD_ACCESS', signal: 11)),
        _segv,
      );
      expect(report.outcome, ReplayOutcome.reproduced);
    });

    test('another crash type is inconclusive: failure.different', () {
      final report = resolveCrash(
        _died(const ObservedCrash(type: 'SIGABRT', signal: 6)),
        _segv,
      );
      expect(report.outcome, ReplayOutcome.notReproduced);
      expect(report.otherFailures.single.signature, 'crash:SIGABRT');
      final run = evaluateRun(RunKind.verify, 2, [
        report,
        resolveCrash(
          _died(const ObservedCrash(type: 'SIGABRT'), attempt: 2),
          _segv,
        ),
      ]);
      expect(run.verdict, Verdict.inconclusive);
      expect(run.reasonCodes, ['failure.different']);
    });

    test('a crash while replaying an exception capsule proves nothing', () {
      final expected = FailureRecord.exception(StateError('x'), null, 0);
      final report = resolveCrash(
        _died(const ObservedCrash(type: 'SIGSEGV')),
        expected,
      );
      final run = evaluateRun(RunKind.verify, 1, [report]);
      expect(run.verdict, Verdict.inconclusive);
      expect(run.reasonCodes, ['failure.different']);
    });

    test('an unknown cause is an error; no death leaves the report', () {
      final unknown = resolveCrash(
        _died(const ObservedCrash(source: 'process_exit')),
        _segv,
      );
      expect(unknown.outcome, ReplayOutcome.error);
      expect(unknown.message, contains('cause is unknown'));

      const alive = ReplayReport(
        outcome: ReplayOutcome.notReproduced,
        attempt: 1,
        durationMs: 10,
        strategy: ReplayStrategy.auto,
        expectedSignature: 'crash:SIGSEGV',
      );
      expect(identical(resolveCrash(alive, _segv), alive), isTrue);
      expect(
        evaluateRun(RunKind.verify, 1, [alive]).verdict,
        Verdict.fixed,
        reason: 'the window replayed to the end and the app is alive',
      );
    });

    test('the crash field round-trips through the result JSON', () {
      final json = _died(
        const ObservedCrash(type: 'SIGSEGV', signal: 11, source: 'xctest'),
      ).toJson();
      final back = ReplayReport.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, Object?>,
      );
      expect(back.crash!.type, 'SIGSEGV');
      expect(back.crash!.signal, 11);
      expect(back.crash!.source, 'xctest');
    });
  });

  group('crash detection', () {
    test('logcat: the signal and the in-app frame', () {
      final crash = CrashDetection.fromLog(_logcat)!;
      expect(crash.type, 'SIGSEGV');
      expect(crash.signal, 11);
      expect(crash.inAppFrame, 'checkout_native');
    });

    test('logcat: a managed crash and an ANR', () {
      final java = CrashDetection.fromLog('''
E AndroidRuntime: FATAL EXCEPTION: main
E AndroidRuntime: Process: fixture.app, PID: 4242
E AndroidRuntime: java.lang.IllegalStateException: cart is empty
''')!;
      expect(java.type, 'java.lang.IllegalStateException');
      expect(java.mechanism, 'exception');
      final anr = CrashDetection.fromLog(
        'E ActivityManager: ANR in fixture.app (fixture.app/.MainActivity)',
      )!;
      expect(anr.type, 'ApplicationNotResponding');
    });

    test('exit-info: the record the attempt added, named by the log', () {
      final exit = CrashDetection.fromExitInfo(_exitBefore, _exitAfter)!;
      expect(exit.type, 'SIGSEGV');
      expect(exit.signal, 11);
      expect(exit.source, 'exit_info');
      final both = CrashDetection.fromExitInfo(
        _exitBefore,
        _exitAfter,
        log: _logcat,
      )!;
      expect(both.inAppFrame, 'checkout_native');
      expect(CrashDetection.fromExitInfo(_exitAfter, _exitAfter), isNull);
    });

    test('an iOS crash report', () {
      final crash = CrashDetection.fromIps(_ips())!;
      expect(crash.type, 'EXC_BAD_ACCESS');
      expect(crash.signal, 11);
      expect(crash.mechanism, 'mach_exception');
      expect(crash.inAppFrame, 'checkout_native');
    });

    test('finds the crash report of the bundle written since the attempt', () {
      final dir = Directory.systemTemp.createTempSync('bc-ips-');
      try {
        File(
          '${dir.path}/Other.ips',
        ).writeAsStringSync('${jsonEncode({'bundleID': 'com.other'})}\n{}');
        File('${dir.path}/Runner-2026.ips').writeAsStringSync(_ips());
        final crash = CrashDetection.findIosCrashReport(
          'com.shop.app',
          since: DateTime.now().subtract(const Duration(minutes: 1)),
          directory: dir,
        );
        expect(crash?.type, 'EXC_BAD_ACCESS');
        expect(
          CrashDetection.findIosCrashReport(
            'com.shop.app',
            since: DateTime.now().add(const Duration(minutes: 1)),
            directory: dir,
          ),
          isNull,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('flutter run, xcodebuild and instrumentation output', () {
      expect(
        CrashDetection.fromFlutterRun(
          'F/libc ( 4242): Fatal signal 6 (SIGABRT), code -1 in tid 4242\nLost connection to device.',
        )!.type,
        'SIGABRT',
      );
      final lost = CrashDetection.fromFlutterRun('Lost connection to device.')!;
      expect(lost.type, isNull, reason: 'died, cause unknown');
      expect(CrashDetection.fromFlutterRun('Built build/app.apk'), isNull);
      expect(
        CrashDetection.fromXctestLog(
          'Runner (777) crashed in checkout_native: EXC_BAD_ACCESS (SIGSEGV)',
        )!.signal,
        11,
      );
      expect(
        CrashDetection.fromInstrumentationStatus(
          'INSTRUMENTATION_STATUS: bugcapsule_crash={"type":"ApplicationNotResponding","mechanism":"anr"}',
        )!.type,
        'ApplicationNotResponding',
      );
    });
  });

  test(
    'the Android launcher turns a crashed instrumentation into the crash it saw',
    () async {
      final dir = Directory.systemTemp.createTempSync('bc-android-crash-');
      final server = await ReplayServer.start();
      File('${dir.path}/logcat.txt').writeAsStringSync(_logcat);
      File('${dir.path}/exit-before.txt').writeAsStringSync(_exitBefore);
      File('${dir.path}/exit-after.txt').writeAsStringSync(_exitAfter);
      final adb = File('${dir.path}/platform-tools/adb')
        ..createSync(recursive: true);
      adb.writeAsStringSync(r'''#!/usr/bin/env python3
import sys, pathlib
root=pathlib.Path(__file__).resolve().parent.parent
args=sys.argv[1:]
if args and args[0]=='-s': args=args[2:]
if args==['devices']: print('List of devices attached\nfixture\tdevice')
elif args[:2]==['shell','getprop']: print('34' if args[-1].endswith('.sdk') else 'Fixture')
elif args[:3]==['shell','pm','clear'] or args[:1]==['install']: print('Success')
elif args[:3]==['shell','dumpsys','package']: print('    versionCode=60 minSdk=24 targetSdk=35\n    versionName=1.5.0')
elif args[:4]==['shell','dumpsys','activity','exit-info']:
    crashed=(root/'crashed').exists()
    print((root/('exit-after.txt' if crashed else 'exit-before.txt')).read_text())
elif args[:3]==['logcat','-b','crash']:
    if '-d' in args and (root/'crashed').exists(): print((root/'logcat.txt').read_text())
elif args[:3]==['shell','am','instrument']:
    (root/'crashed').write_text('yes')
    print('INSTRUMENTATION_RESULT: shortMsg=Process crashed.')
    print('INSTRUMENTATION_CODE: 0')
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
        expect(launcher.release.toString(), 'fixture.app@1.5.0+60');
        final report = await launcher.attempt(
          server,
          [1],
          const ReplaySettings(attempt: 1, runtime: 'android', kind: 'verify'),
          const Duration(seconds: 10),
        );
        expect(report.crash!.type, 'SIGSEGV');
        expect(report.crash!.inAppFrame, 'checkout_native');
        final resolved = resolveCrash(report, _segv);
        expect(resolved.outcome, ReplayOutcome.reproduced);
        expect(
          evaluateRun(RunKind.verify, 1, [resolved]).verdict,
          Verdict.stillFailing,
        );
      } finally {
        await launcher.dispose();
        await server.close();
        dir.deleteSync(recursive: true);
      }
    },
    skip: Platform.isWindows ? 'uses a POSIX fake adb executable' : false,
  );

  group('release of the build under test', () {
    test('pubspec version with the Android application id', () {
      final dir = Directory.systemTemp.createTempSync('bc-release-');
      try {
        File(
          '${dir.path}/pubspec.yaml',
        ).writeAsStringSync('name: shop\nversion: 1.5.0+60\n');
        File('${dir.path}/android/app/build.gradle.kts')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'android {\n  defaultConfig {\n    applicationId = "com.shop.app"\n  }\n}\n',
          );
        final id = AppRelease.flutterAppId(dir.path, android: true);
        expect(id, 'com.shop.app');
        expect(
          AppRelease.fromPubspec(dir.path, appId: id).toString(),
          'com.shop.app@1.5.0+60',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
