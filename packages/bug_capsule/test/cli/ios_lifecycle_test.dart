import 'dart:convert';
import 'dart:io';
import 'package:bug_capsule/src/cli/processes.dart';
import 'package:test/test.dart';

void main() {
  test('captured commands retain output and nonzero status', () async {
    final result = await runCaptured('/bin/sh', [
      '-c',
      'printf out; printf err >&2; exit 7',
    ]);
    expect(result.exitCode, 7);
    expect(result.stdout, 'out');
    expect(result.stderr, 'err');
  }, skip: Platform.isWindows ? 'uses POSIX fake executables' : false);
  for (final runtime in ['flutter', 'native']) {
    for (final mode in [
      'cleanup',
      'terminate',
      if (runtime == 'flutter') ...[
        'container',
        'launch',
        'budget',
      ] else
        'uninstall',
    ]) {
      test(
        '$runtime $mode is bounded and kills only its own lifecycle command',
        () async {
          final dir = Directory.systemTemp.createTempSync('bc-ios-lifecycle-');
          final root = dir.path;
          File(
            '$root/build/ios/iphonesimulator/Fixture.app/Info.plist',
          ).createSync(recursive: true);
          File('$root/products/fixture.xctestrun').createSync(recursive: true);
          File('$root/bugcapsule.json').writeAsStringSync(
            jsonEncode({
              'runtime': runtime == 'native' ? 'ios' : 'flutter',
              'ios': {'bundleId': 'fixture.app', 'startupSeconds': 0},
            }),
          );
          final bin = Directory('$root/bin')..createSync();
          const script = r'''#!/usr/bin/python3
import sys,os,pathlib,json,time,signal,urllib.request
root=pathlib.Path(os.environ['FIXTURE_ROOT']); mode=os.environ['FIXTURE_MODE']
args=sys.argv[1:]; exe=pathlib.Path(sys.argv[0]).name
if exe=='flutter': sys.exit(0)
if exe=='plutil': print('fixture.app'); sys.exit(0)
def hang():
    with (root/'pids').open('a') as f: f.write(str(os.getpid())+'\n')
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    time.sleep(30)
if args[:2]==['simctl','list']:
    print(json.dumps({'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-18-0':[{'udid':'fixture','name':'Fixture','state':'Booted','isAvailable':True}]}})); sys.exit(0)
if args[:2]==['simctl','terminate']:
    countfile=root/'terminations'; n=int(countfile.read_text())+1 if countfile.exists() else 1; countfile.write_text(str(n))
    if mode=='budget' and n==1: time.sleep(1.2)
    if (mode=='cleanup' and n==2) or (mode=='terminate' and n==1): hang()
    sys.exit(1) # The app was already stopped; this is benign.
if args[:2]==['simctl','get_app_container']:
    if mode=='container': hang()
    if mode=='budget':
        with (root/'pids').open('a') as f: f.write(str(os.getpid())+'\n')
        time.sleep(1.2)
    print(root/'data'); sys.exit(0)
if args[:2]==['simctl','uninstall']:
    if mode=='uninstall': hang()
    sys.exit(0)
if args[:2]==['simctl','launch'] or args[:1]==['xcodebuild']:
    if mode=='launch': hang()
    url=os.environ.get('TEST_RUNNER_BUGCAPSULE_REPLAY_URL')
    if not url: url=json.loads((root/'data/Library/Application Support/bugcapsule/replay_request.json').read_text())['url']
    settings=json.load(urllib.request.urlopen(url+'/settings'))
    report={'outcome':'not_reproduced','attempt':settings['attempt'],'attemptId':settings['attemptId'],'durationMs':1,'strategy':'semantic','eventsDispatched':1,'eventsExpected':1,'fixturesServed':0}
    urllib.request.urlopen(urllib.request.Request(url+'/result',data=json.dumps(report).encode(),headers={'Content-Type':'application/json'})).read()
    print('fixture.app: 999999'); sys.exit(0)
sys.exit(0)
''';
          for (final name in ['xcrun', 'flutter', 'plutil']) {
            final file = File('${bin.path}/$name')..writeAsStringSync(script);
            await Process.run('chmod', ['+x', file.path]);
          }
          Process? driver;
          try {
            final packages = File(
              '../../.dart_tool/package_config.json',
            ).absolute.path;
            driver = await Process.start(
              'dart',
              [
                '--packages=$packages',
                'test/cli/fixtures/ios_lifecycle_driver.dart',
                root,
                runtime,
              ],
              environment: {
                'PATH': '${bin.path}:${Platform.environment['PATH']}',
                'FIXTURE_ROOT': root,
                'FIXTURE_MODE': mode,
              },
            );
            final output = driver.stdout.transform(utf8.decoder).join();
            final errors = driver.stderr.transform(utf8.decoder).join();
            final code = await driver.exitCode.timeout(
              const Duration(seconds: 15),
            );
            final out = await output;
            expect(code, 0, reason: await errors);
            final result =
                jsonDecode(
                      out.split('\n').lastWhere((line) => line.startsWith('{')),
                    )
                    as Map;
            if (mode == 'cleanup') {
              expect(result['outcome'], 'notReproduced', reason: out);
              expect(result['elapsedMs'], lessThan(8000));
            } else {
              expect(result['error'], contains('timed out'), reason: out);
              expect(
                result['elapsedMs'],
                lessThan(mode == 'budget' ? 4000 : 2500),
              );
            }
            final pids = File('$root/pids').readAsLinesSync();
            expect(pids, hasLength(1));
            for (final pid in pids) {
              expect(
                (await Process.run('kill', ['-0', pid])).exitCode,
                isNot(0),
                reason: 'timed-out fixture child must be dead',
              );
            }
          } finally {
            driver?.kill(ProcessSignal.sigkill);
            final owned = File('$root/pids');
            if (owned.existsSync()) {
              for (final pid in owned.readAsLinesSync()) {
                final command = await Process.run('ps', [
                  '-p',
                  pid,
                  '-o',
                  'command=',
                ]);
                if ('${command.stdout}'.contains(root)) {
                  Process.killPid(int.parse(pid), ProcessSignal.sigkill);
                }
              }
            }
            dir.deleteSync(recursive: true);
          }
        },
        skip: Platform.isWindows ? 'uses POSIX fake executables' : false,
      );
    }
  }
}
