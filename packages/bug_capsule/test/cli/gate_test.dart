import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:bug_capsule/src/cli/backend_client.dart';
import 'package:bug_capsule/src/cli/commands.dart';
import 'package:bug_capsule/src/cli/gate.dart';
import 'package:bug_capsule/src/cli/launcher.dart';
import 'package:bug_capsule/src/cli/replay_server.dart';
import 'package:bug_capsule/src/core/core.dart';
import 'package:test/test.dart';

const _signature = 'exception:StateError:Bad state: Cart total is negative (#)';

/// A capsule the backend serves for [id].
List<int> _capsule(String id) {
  final doc =
      (jsonDecode(
                File(
                  '../../spec/fixtures/capsule-v1/valid/minimal.json',
                ).readAsStringSync(),
              )
              as Map)['document']
          as Map<String, Object?>;
  final manifest = (doc['manifest'] as Map).cast<String, Object?>();
  manifest['capsuleId'] = id;
  manifest['sdk'] = {'name': 'bugcapsule-android', 'version': '0.5.0'};
  manifest['failure'] = {
    'kind': 'exception',
    'signature': _signature,
    'type': 'StateError',
    'message': 'Bad state: Cart total is negative (-3)',
    't': 10,
  };
  return gzip.encode(utf8.encode(jsonEncode(doc)));
}

/// The parts of the backend the gate talks to (verification.md §3).
class FakeGateBackend {
  late HttpServer _server;
  List<Map<String, Object?>> plan = [];
  int planStatus = 200;
  int runStatus = 201;
  final List<(String, Map<String, Object?>)> runs = [];
  final List<Map<String, Object?>> reports = [];
  final List<Uri> planRequests = [];
  final List<String?> auth = [];

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    auth.add(req.headers.value(HttpHeaders.authorizationHeader));
    final path = req.uri.path;
    final body = await utf8.decoder.bind(req).join();
    final res = req.response;
    Future<void> json(int status, Object value) async {
      res
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(value));
      await res.close();
    }

    if (req.method == 'GET' && path == '/v1/verification/plan') {
      planRequests.add(req.uri);
      if (planStatus != 200) {
        return json(planStatus, {'code': 'internal', 'detail': 'boom'});
      }
      return json(200, {
        'release': req.uri.queryParameters['release'],
        'items': plan,
      });
    }
    final file = RegExp(r'^/v1/capsules/([^/]+)/file$').firstMatch(path);
    if (req.method == 'GET' && file != null) {
      res.headers.contentType = ContentType.binary;
      res.add(_capsule(file[1]!));
      return res.close();
    }
    final run = RegExp(r'^/v1/capsules/([^/]+)/runs$').firstMatch(path);
    if (req.method == 'POST' && run != null) {
      if (runStatus >= 400) {
        return json(runStatus, {
          'code': 'internal',
          'detail': 'run store down',
        });
      }
      runs.add((run[1]!, (jsonDecode(body) as Map).cast<String, Object?>()));
      return json(201, {'id': 'run-${runs.length}'});
    }
    if (req.method == 'POST' && path == '/v1/verification/reports') {
      reports.add((jsonDecode(body) as Map).cast<String, Object?>());
      return json(201, {'id': 'report-${reports.length}'});
    }
    return json(404, {'code': 'not_found'});
  }
}

ReplayReport _attempt(ReplaySettings s, {required bool reproduced}) =>
    ReplayReport(
      outcome: reproduced
          ? ReplayOutcome.reproduced
          : ReplayOutcome.notReproduced,
      attempt: s.attempt,
      durationMs: 5,
      strategy: ReplayStrategy.semantic,
      expectedSignature: _signature,
      eventsDispatched: 1,
      eventsExpected: 1,
      attemptId: s.attemptId,
    );

/// Scripted attempts by capsule id: `pass`, `reproduce`, `flaky`, `throw`.
class FakeLauncher implements AppLauncher {
  FakeLauncher(this.options, this.script);

  @override
  final LaunchOptions options;
  final Map<String, String> script;
  int prepares = 0;
  final List<String> attempts = [];
  bool failBuild = false;

  @override
  String get target => 'fake device';

  @override
  AppRelease? get release =>
      const AppRelease(appId: 'com.shop.app', version: '1.5.0', build: '60');

  @override
  Future<void> prepare(ReplayServer server) async {
    prepares++;
    if (failBuild) throw StateError('gradle failed');
  }

  @override
  Future<ReplayReport> attempt(
    ReplayServer server,
    List<int> capsule,
    ReplaySettings settings,
    Duration timeout,
  ) async {
    final id = CapsuleCodec.decode(capsule).manifest.capsuleId;
    attempts.add(id);
    return switch (script[id] ?? 'pass') {
      'reproduce' => _attempt(settings, reproduced: true),
      'flaky' => _attempt(settings, reproduced: settings.attempt == 1),
      'throw' => throw StateError('device went away'),
      _ => _attempt(settings, reproduced: false),
    };
  }

  @override
  Future<void> dispose() async {}
}

Map<String, Object?> _item(String id, String title, {String reason = 'fix'}) =>
    {
      'capsuleId': id,
      'issueId': 'issue-$id',
      'issueTitle': title,
      'reason': reason,
      'platform': 'android',
      'runtime': 'android',
      'status': reason == 'fix' ? 'reproduced' : 'fixed',
      'eligibility': 'eligible',
    };

void main() {
  late FakeGateBackend backend;
  late Directory project;
  FakeLauncher? launcher;

  setUp(() async {
    backend = FakeGateBackend();
    await backend.start();
    project = Directory.systemTemp.createTempSync('bc-gate-');
    File(
      '${project.path}/bugcapsule.json',
    ).writeAsStringSync(jsonEncode({'runtime': 'android'}));
    launcher = null;
  });

  tearDown(() async {
    await backend.close();
    project.deleteSync(recursive: true);
  });

  Future<int> gate(
    List<String> args, {
    Map<String, String> script = const {},
    bool failBuild = false,
  }) async {
    final runner = CommandRunner<int>('bugcapsule', 'test')
      ..addCommand(
        GateCommand(
          launcherFactory: (options) =>
              launcher = FakeLauncher(options, script)..failBuild = failBuild,
        ),
      );
    return await runner.run([
          'gate',
          '--release',
          'com.shop.app@1.5.0+60',
          '--platform',
          'android',
          '--project',
          project.path,
          '--url',
          backend.url,
          '--token',
          'bcv_gate_test',
          '--attempts',
          '2',
          ...args,
        ]) ??
        0;
  }

  test('an empty plan passes, says so and still reports', () async {
    expect(await gate([]), 0);
    expect(launcher, isNull, reason: 'nothing to build');
    expect(backend.planRequests.single.queryParameters, {
      'release': 'com.shop.app@1.5.0+60',
      'platform': 'android',
      'scope': 'all',
    });
    expect(backend.auth.first, 'Bearer bcv_gate_test');
    final report = backend.reports.single;
    expect(report['passed'], isTrue);
    expect(report['results'], isEmpty);
  });

  test(
    'all pass: one build, a verify run per capsule with the release, a report',
    () async {
      backend.plan = [
        _item('cap-1', 'Cart total is negative'),
        _item('cap-2', 'Checkout crashes', reason: 'regression'),
      ];
      final junit = '${project.path}/out/gate.xml';
      expect(await gate(['--junit', junit, '--environment', 'staging']), 0);
      expect(launcher!.prepares, 1);
      expect(launcher!.attempts, ['cap-1', 'cap-1', 'cap-2', 'cap-2']);
      expect(backend.runs.map((r) => r.$1), ['cap-1', 'cap-2']);
      for (final (_, run) in backend.runs) {
        expect(run['kind'], 'verify');
        expect(run['outcome'], 'not_reproduced');
        expect(run['attempts'], 2);
        expect(run['release'], 'com.shop.app@1.5.0+60');
        expect(run['environment'], 'staging');
      }
      final report = backend.reports.single;
      expect(report['release'], 'com.shop.app@1.5.0+60');
      expect(report['platform'], 'android');
      expect(report['passed'], isTrue);
      expect(report['results'], [
        {
          'capsuleId': 'cap-1',
          'runId': 'run-1',
          'reason': 'fix',
          'outcome': 'not_reproduced',
        },
        {
          'capsuleId': 'cap-2',
          'runId': 'run-2',
          'reason': 'regression',
          'outcome': 'not_reproduced',
        },
      ]);
      final xml = File(junit).readAsStringSync();
      expect(xml, contains('tests="2" failures="0"'));
      expect(xml, contains('name="Cart total is negative (cap-1)"'));
      expect(xml, isNot(contains('<failure')));
    },
  );

  test('a reproduced item fails the gate with exit 1', () async {
    backend.plan = [
      _item('cap-1', 'Cart total is negative'),
      _item('cap-2', 'Checkout <crashes> & "stalls"'),
    ];
    final junit = '${project.path}/gate.xml';
    expect(await gate(['--junit', junit], script: {'cap-2': 'reproduce'}), 1);
    expect(backend.runs.last.$2['outcome'], 'reproduced');
    expect(backend.reports.single['passed'], isFalse);
    final xml = File(junit).readAsStringSync();
    expect(xml, contains('failures="1"'));
    expect(
      xml,
      contains(
        'name="Checkout &lt;crashes&gt; &amp; &quot;stalls&quot; (cap-2)"',
      ),
    );
    expect(xml, contains('<failure type="reproduced"'));
  });

  test(
    'flaky exits 2 by default and passes without flaky in --fail-on',
    () async {
      backend.plan = [_item('cap-1', 'Cart total is negative')];
      expect(await gate([], script: {'cap-1': 'flaky'}), 2);
      expect(backend.reports.last['passed'], isFalse);
      expect(backend.runs.last.$2['outcome'], 'flaky');

      expect(
        await gate(['--fail-on', 'reproduced'], script: {'cap-1': 'flaky'}),
        0,
      );
      expect(backend.reports.last['passed'], isTrue);
    },
  );

  test('an item that cannot run fails only with error in --fail-on', () async {
    backend.plan = [_item('cap-1', 'Cart total is negative')];
    expect(await gate([], script: {'cap-1': 'throw'}), 0);
    expect(backend.runs.single.$2['outcome'], 'inconclusive');
    expect(
      await gate(
        ['--fail-on', 'reproduced,flaky,error'],
        script: {'cap-1': 'throw'},
      ),
      3,
    );
  });

  test('a failed build reports every item as error', () async {
    backend.plan = [_item('cap-1', 'Cart total is negative')];
    expect(await gate(['--fail-on', 'error'], failBuild: true), 3);
    expect(backend.runs, isEmpty, reason: 'no run happened');
    expect(backend.reports.single['results'], [
      {
        'capsuleId': 'cap-1',
        'runId': null,
        'reason': 'fix',
        'outcome': 'error',
      },
    ]);
  });

  test(
    'backend errors: the plan throws (exit 1), a lost run exits 1',
    () async {
      backend.planStatus = 500;
      await expectLater(gate([]), throwsA(isA<ApiException>()));
      expect(await runBugCapsule(['gate', '--platform', 'android']), 64);

      backend
        ..planStatus = 200
        ..plan = [_item('cap-1', 'Cart total is negative')]
        ..runStatus = 500;
      expect(await gate([]), 1);
      expect(backend.reports.single['results'], [
        {
          'capsuleId': 'cap-1',
          'runId': null,
          'reason': 'fix',
          'outcome': 'not_reproduced',
        },
      ]);
    },
  );

  test('usage errors', () async {
    expect(
      () => gate(['--fail-on', 'reproduced,sometimes']),
      throwsA(isA<UsageException>()),
    );
    expect(() => gate(['--attempts', '0']), throwsA(isA<UsageException>()));
  });

  group('outputs', () {
    final item = GateItem.fromJson(_item('cap-1', 'Cart total is negative'));
    final at = DateTime.utc(2026, 10, 27, 9);

    test('exit codes follow --fail-on, most serious first', () {
      final results = [
        GateResult(item, 'flaky'),
        GateResult(item, 'inconclusive'),
        GateResult(item, 'reproduced'),
      ];
      expect(gateExitCode(results, {'reproduced', 'flaky', 'error'}), 1);
      expect(gateExitCode(results.take(2), {'reproduced', 'flaky'}), 2);
      expect(gateExitCode(results.skip(1).take(1), {'error'}), 3);
      expect(gateExitCode(results.take(2), {'reproduced'}), 0);
      expect(gateExitCode(const [], {'reproduced', 'flaky', 'error'}), 0);
    });

    test('JUnit: failures by --fail-on, skipped for what could not run', () {
      final xml = gateJunit(
        release: 'com.shop.app@1.5.0+60',
        platform: 'android',
        gitSha: 'a1b2c3d',
        results: [
          GateResult(item, 'not_reproduced', runId: 'run-1'),
          GateResult(item, 'flaky', runId: 'run-2'),
          GateResult(item, 'incompatible', error: 'runtime mismatch'),
        ],
        failOn: {'reproduced', 'flaky'},
        startedAt: at,
        finishedAt: at.add(const Duration(seconds: 90)),
      );
      expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(
        xml,
        contains(
          '<testsuites name="bugcapsule gate" tests="3" failures="1" errors="0" skipped="1" time="90.000">',
        ),
      );
      expect(xml, contains('<property name="gitSha" value="a1b2c3d"/>'));
      expect(
        xml,
        contains(
          '<testcase classname="bugcapsule.gate.fix" name="Cart total is negative (cap-1)" time="0.000"/>',
        ),
      );
      expect(xml, contains('<failure type="flaky"'));
      expect(
        xml,
        contains('<skipped message="could not verify (incompatible)"/>'),
      );
      expect(xml, contains('runtime mismatch'));
    });

    test('JSON carries the results and the exit code', () {
      final doc =
          jsonDecode(
                gateJson(
                  release: 'r',
                  platform: 'android',
                  scope: 'all',
                  results: [GateResult(item, 'reproduced', runId: 'run-1')],
                  passed: false,
                  exitCode: 1,
                  reportId: 'report-1',
                ),
              )
              as Map;
      expect(doc['passed'], isFalse);
      expect(doc['exitCode'], 1);
      expect(doc['failed'], 1);
      expect((doc['results'] as List).single, containsPair('runId', 'run-1'));
    });
  });
}
