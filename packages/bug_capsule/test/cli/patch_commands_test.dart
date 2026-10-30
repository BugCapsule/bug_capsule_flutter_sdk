import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:bug_capsule/src/cli/backend_client.dart';
import 'package:bug_capsule/src/cli/patch_commands.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late HttpServer server;
  late Credentials creds;
  late List<Map<String, Object?>> output;
  late List<(String, String, Map<String, Object?>)> calls;
  late Future<void> Function(HttpRequest, Map<String, Object?>) handle;
  late PatchProcess process;
  late Map<String, String> environment;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('patch-cli-test-');
    Directory('${dir.path}/engine/tools').createSync(recursive: true);
    File('${dir.path}/engine/tools/bcpatch.ts').writeAsStringSync('// fixture');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    creds = Credentials(
      url: 'http://127.0.0.1:${server.port}',
      token: 'bcp_fixture',
    );
    environment = {
      'BUGCAPSULE_PATCH_SESSION_TOKEN': 'bcw_fixture',
      'BUGCAPSULE_PATCH_PROJECT_ID': '11111111-2222-4333-8444-555555555555',
    };
    output = [];
    calls = [];
    handle = (r, b) async {
      r.response.write('{}');
      await r.response.close();
    };
    server.listen((r) async {
      final text = await utf8.decoder.bind(r).join();
      final body = text.startsWith('{')
          ? (jsonDecode(text) as Map).cast<String, Object?>()
          : <String, Object?>{};
      calls.add((r.method, r.uri.path, body));
      await handle(r, body);
    });
    process = (exe, args, cwd) async => ProcessResult(1, 0, '{}', '');
  });
  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });
  Future<int?> run(List<String> args) =>
      (CommandRunner<int>('bugcapsule', 'test')..addCommand(
            PatchCommand(
              credentials: creds,
              directory: dir.path,
              environment: environment,
              output: (s) =>
                  output.add((jsonDecode(s) as Map).cast<String, Object?>()),
              process: (e, a, d) => process(e, a, d),
            ),
          ))
          .run(['patch', ...args]);
  Map<String, Object?> result() =>
      (output.last['result'] as Map).cast<String, Object?>();

  test(
    'local engine subprocesses do not inherit management credentials',
    () async {
      if (Platform.isWindows) return;
      final node = File('${dir.path}/node-fixture');
      node.writeAsStringSync(r'''#!/bin/sh
if [ "$1" = "--version" ]; then
  echo v24.0.0
elif [ -n "$BUGCAPSULE_PATCH_SESSION_TOKEN$BUGCAPSULE_TOKEN$BUGCAPSULE_SECRET_KEY$BUGCAPSULE_INGEST_KEY" ]; then
  echo '{"credentialVisible":true}'
else
  echo '{"credentialVisible":false}'
fi
''');
      await Process.run('chmod', ['700', node.path]);
      final runner = CommandRunner<int>('bugcapsule', 'test')
        ..addCommand(
          PatchCommand(
            credentials: creds,
            directory: dir.path,
            environment: {
              ...environment,
              'BUGCAPSULE_TOKEN': 'bcp_fixture',
              'BUGCAPSULE_SECRET_KEY': 'bcs_fixture',
              'BUGCAPSULE_INGEST_KEY': 'bci_fixture',
            },
            output: (s) =>
                output.add((jsonDecode(s) as Map).cast<String, Object?>()),
          ),
        );
      expect(
        await runner.run([
          'patch',
          'doctor',
          '--engine',
          'engine',
          '--node',
          node.path,
        ]),
        0,
      );
      expect(
        (result()['capabilityProbe'] as Map)['credentialVisible'],
        isFalse,
      );
    },
  );

  test(
    'persistent CI tokens cannot silently become human deployment authority',
    () async {
      environment.clear();
      expect(
        await run([
          'deploy',
          'plan-1',
          '--reason',
          'reviewed',
          '--expected-version',
          '4',
        ]),
        77,
      );
      expect(calls, isEmpty);
      expect(output.last.toString(), contains('person_session_required'));
    },
  );

  test(
    'all proposed commands are registered without replacing existing command names',
    () async {
      final root = PatchCommand();
      expect(
        root.subcommands.keys,
        containsAll([
          'doctor',
          'init',
          'base',
          'build',
          'inspect',
          'classify',
          'validate',
          'upload',
          'plan',
          'deploy',
          'status',
          'rollback',
        ]),
      );
      expect(root.subcommands['base']!.subcommands.keys, ['register']);
      expect(await run(['init', '--platform', 'android']), 0);
      expect(File('${dir.path}/bugcapsule.patch.json').existsSync(), isTrue);
      final before = File(
        '${dir.path}/bugcapsule.patch.json',
      ).readAsStringSync();
      expect(await run(['init', '--platform', 'ios']), 1);
      expect(
        File('${dir.path}/bugcapsule.patch.json').readAsStringSync(),
        before,
      );
    },
  );
  test(
    'creates exact validation pending and submits only supplied evidence',
    () async {
      handle = (r, b) async {
        r.response.write('{"id":"validation-1","status":"PENDING"}');
        await r.response.close();
      };
      expect(
        await run([
          'validate',
          'artifact-1',
          '--capsule',
          'capsule-1',
          '--json',
        ]),
        2,
      );
      expect(calls.single.$3, {
        'artifactId': 'artifact-1',
        'capsuleIds': ['capsule-1'],
        'affectedPatchSetDigest': null,
        'requireRegressions': true,
        'acceptPartial': false,
        'deadlineHours': 48,
      });
      expect(result()['status'], 'PENDING');
      final evidence = {
        'kind': 'baseline',
        'capsuleId': 'capsule-1',
        'outcome': 'reproduced',
        'attempts': 3,
        'reproductions': 3,
        'platform': 'android',
        'identity': {
          'baseBuildId': 'base+1',
          'patchSetDigest': null,
          'engineAbi': 1,
          'hostAbiHash': 'hash',
        },
      };
      File('${dir.path}/evidence.json').writeAsStringSync(jsonEncode(evidence));
      await run(['validate', 'validation-1', '--evidence', 'evidence.json']);
      expect(calls.last.$2, '/v1/patches/validations/validation-1/evidence');
      expect(calls.last.$3, evidence);
    },
  );
  test(
    'deployment and rollback preserve explicit review and optimistic version',
    () async {
      handle = (r, b) async {
        r.response.statusCode = 202;
        r.response.write('{"result":"approval_required"}');
        await r.response.close();
      };
      expect(
        await run([
          'deploy',
          'plan-1',
          '--reason',
          'reviewed',
          '--expected-version',
          '4',
        ]),
        2,
      );
      expect(calls.single.$2, '/v1/patches/deployments/plan-1/request');
      expect(calls.single.$3, {'reason': 'reviewed', 'expectedVersion': 4});
      expect(
        await run([
          'rollback',
          'plan-1',
          '--reason',
          'regression',
          '--expected-version',
          '5',
        ]),
        64,
      );
      expect(calls.length, 1);
      await run([
        'rollback',
        'plan-1',
        '--reason',
        'regression',
        '--expected-version',
        '5',
        '--to-base',
      ]);
      expect(calls.last.$3, {
        'reason': 'regression',
        'expectedVersion': 5,
        'toArtifactDigest': null,
        'revoke': false,
      });
    },
  );
  test(
    'plans do not publish, reject bad stage order and retain honest receipt counts',
    () async {
      handle = (r, b) async {
        r.response.write(
          r.uri.path.endsWith('/receipts')
              ? '{"reportingInstallations":0,"rollback":{"devicesPending":4}}'
              : '{"state":"planned"}',
        );
        await r.response.close();
      };
      expect(
        await run([
          'plan',
          'artifact-1',
          '--environment',
          'staging',
          '--stages',
          '500,100,10000',
        ]),
        64,
      );
      expect(calls, isEmpty);
      expect(await run(['plan', 'artifact-1', '--environment', 'staging']), 0);
      expect(calls.single.$2, '/v1/patches/deployments');
      expect(calls.single.$3['rolloutStages'], [100, 500, 2500, 10000]);
      expect(await run(['status', 'plan-1']), 0);
      expect((result()['receipts'] as Map)['reportingInstallations'], 0);
      expect(result()['note'], contains('not activation'));
    },
  );
  test(
    'upload resumes a lost finalize response using its stored phase key',
    () async {
      File('${dir.path}/fix.bcpatch').writeAsStringSync('fixture-bytes');
      File('${dir.path}/diff.json').writeAsStringSync(
        '{"format":"unified","baseCommit":"a","headCommit":"b","diff":"diff"}',
      );
      var fail = true;
      final finalKeys = <String?>[];
      handle = (r, b) async {
        if (r.uri.path.endsWith('/finalize')) {
          finalKeys.add(r.headers.value('idempotency-key'));
          r.response.statusCode = fail ? 503 : 201;
          r.response.write(
            fail
                ? '{"code":"unavailable"}'
                : '{"id":"artifact-1","artifactDigest":"sha256:digest"}',
          );
        } else if (r.uri.path.endsWith('/content')) {
          expect(
            r.headers.contentType!.mimeType,
            'application/vnd.bugcapsule.bcpatch',
          );
          r.response.write('{"state":"received"}');
        } else {
          r.response.write('{"id":"upload-1"}');
        }
        await r.response.close();
      };
      final args = ['upload', 'fix.bcpatch', '--source-diff', 'diff.json'];
      expect(await run(args), 1);
      fail = false;
      expect(await run(args), 0);
      expect(calls.where((c) => c.$2 == '/v1/patches/uploads').length, 1);
      expect(finalKeys.toSet().length, 1);
      expect(calls.last.$3['sourceDiff'], containsPair('headCommit', 'b'));
      final count = calls.length;
      expect(await run(args), 0);
      expect(calls.length, count);
      File('${dir.path}/fix.bcpatch').writeAsStringSync('changed');
      expect(await run(args), 1);
      expect(calls.length, count);
    },
  );
  test(
    'classification exit codes remain explicit and never invoke pack',
    () async {
      for (final code in [3, 4]) {
        var packs = 0;
        process = (e, a, d) async {
          if (a.contains('pack')) packs++;
          return ProcessResult(
            1,
            code,
            jsonEncode({
              'verdict': code == 3 ? 'STORE_RELEASE_REQUIRED' : 'UNKNOWN',
              'findings': [],
            }),
            '',
          );
        };
        expect(
          await run([
            'classify',
            '--engine',
            'engine',
            '--registered',
            'registered.json',
            '--base-rev',
            'base',
          ]),
          code,
        );
        expect(packs, 0);
        expect(output.last['ok'], isFalse);
      }
    },
  );
  test(
    'build refuses unsupported or omitted classified changes before signing',
    () async {
      Directory('${dir.path}/modules').createSync();
      File('${dir.path}/modules/fix.bpl').writeAsStringSync('fixture');
      handle = (r, b) async {
        r.response.write(
          jsonEncode({
            'applicationId': 'app',
            'platform': 'android',
            'capabilityHash': 'cap',
            'hostAbiHash': 'host',
            'inventory': {'modules': [], 'surfaces': []},
          }),
        );
        await r.response.close();
      };
      var packed = false;
      var verdict = 'STORE_RELEASE_REQUIRED';
      process = (e, a, d) async {
        if (e == 'git') {
          return ProcessResult(1, 0, a.contains('status') ? '' : 'head', '');
        }
        if (a.contains('capability')) {
          return ProcessResult(
            1,
            0,
            '{"baseCapabilityHash":"cap","hostAbiHash":"host"}',
            '',
          );
        }
        if (a.contains('classify')) {
          return ProcessResult(
            1,
            verdict == 'PATCHABLE' ? 0 : 3,
            jsonEncode({
              'verdict': verdict,
              'findings': [
                {'path': 'other/fix.bpl', 'verdict': verdict},
              ],
            }),
            '',
          );
        }
        packed = true;
        return ProcessResult(1, 0, '{}', '');
      };
      final args = [
        'build',
        '--engine',
        'engine',
        '--base',
        'base+1',
        '--source',
        'modules',
        '--base-rev',
        'base',
        '--project',
        '11111111-2222-4333-8444-555555555555',
        '--patch-id',
        'fix',
        '--key',
        'key.pem',
        '--key-id',
        'key',
        '--out',
        'fix.bcpatch',
      ];
      expect(await run(args), 3);
      expect(packed, isFalse);
      verdict = 'PATCHABLE';
      expect(await run(args), 1);
      expect(packed, isFalse);
      expect(calls.first.$2, '/v1/patches/bases/base%2B1');
    },
  );
}
