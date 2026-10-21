import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule_cli/src/project_config.dart';
import 'package:bug_capsule_cli/src/replay.dart';
import 'package:bug_capsule_cli/src/replay_server.dart';
import 'package:bug_capsule_core/bug_capsule_core.dart';
import 'package:test/test.dart';

Future<(int, String)> _req(String method, String url, {String? body, Map<String, String> headers = const {}}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse(url));
    headers.forEach(req.headers.set);
    if (body != null) req.write(body);
    final res = await req.close();
    return (res.statusCode, await utf8.decodeStream(res));
  } finally {
    client.close(force: true);
  }
}

String _report({String? attemptId, String outcome = 'reproduced'}) => jsonEncode({
      'outcome': outcome,
      'attempt': 1,
      'durationMs': 5,
      'strategy': 'semantic',
      'expectedSignature': 'assertion:x:',
      'attemptId': ?attemptId,
    });

void main() {
  late ReplayServer server;
  setUp(() async => server = await ReplayServer.start());
  tearDown(() => server.close());

  test('serves settings with a fresh attemptId and the capsule under the attempt token', () async {
    final armed = server.arm([1, 2, 3], const ReplaySettings(attempt: 2, runtime: 'web'));
    expect(armed.url, startsWith('http://127.0.0.1:${server.port}/a/'));
    final (status, body) = await _req('GET', '${armed.url}/settings');
    expect(status, 200);
    final settings = ReplaySettings.fromJson((jsonDecode(body) as Map).cast<String, Object?>());
    expect(settings.attemptId, armed.attemptId);
    expect(settings.attempt, 2);
    expect(settings.runtime, 'web');
    final client = HttpClient();
    final res = await (await client.getUrl(Uri.parse('${armed.url}/capsule'))).close();
    expect(await res.fold<List<int>>([], (a, b) => a..addAll(b)), [1, 2, 3]);
    client.close();
  });

  test('unknown tokens and the legacy unprefixed paths get 404', () async {
    final armed = server.arm([1], const ReplaySettings());
    expect((await _req('GET', 'http://127.0.0.1:${server.port}/capsule')).$1, 404);
    expect((await _req('GET', 'http://127.0.0.1:${server.port}/a/not-the-token/capsule')).$1, 404);
    expect((await _req('GET', '${armed.url}/other')).$1, 404);
  });

  test('a report for the attempt completes it; a second one is stale (410)', () async {
    final armed = server.arm([1], const ReplaySettings());
    expect((await _req('POST', '${armed.url}/result', body: _report(attemptId: armed.attemptId))).$1, 204);
    expect((await armed.report).outcome, ReplayOutcome.reproduced);
    expect((await _req('POST', '${armed.url}/result', body: _report(attemptId: armed.attemptId))).$1, 410);
    expect((await _req('GET', '${armed.url}/settings')).$1, 410);
  });

  test('a report with another attemptId is rejected (409) and does not complete the attempt', () async {
    final armed = server.arm([1], const ReplaySettings());
    expect((await _req('POST', '${armed.url}/result', body: _report(attemptId: 'someone-else'))).$1, 409);
    expect((await _req('POST', '${armed.url}/result', body: _report())).$1, 204,
        reason: 'reports without attemptId (Flutter 0.2) are bound by the token');
  });

  test('a late report from a previous attempt never counts for the next one', () async {
    final first = server.arm([1], const ReplaySettings(attempt: 1));
    first.close(); // timed out
    final second = server.arm([1], const ReplaySettings(attempt: 2));
    expect((await _req('POST', '${first.url}/result', body: _report(attemptId: first.attemptId))).$1, 404);
    expect(second.isClosed, isFalse);
    expect((await _req('POST', '${second.url}/result', body: _report(attemptId: second.attemptId, outcome: 'not_reproduced'))).$1, 204);
    expect((await second.report).outcome, ReplayOutcome.notReproduced);
  });

  test('closing an attempt rejects its report with 410', () async {
    final armed = server.arm([1], const ReplaySettings());
    armed.close();
    expect((await _req('POST', '${armed.url}/result', body: _report())).$1, 410);
  });

  test('browser requests (Origin header) are refused', () async {
    final armed = server.arm([1], const ReplaySettings());
    final (status, _) = await _req('GET', '${armed.url}/settings', headers: {'Origin': 'http://evil.test'});
    expect(status, 403);
  });

  test('malformed reports are a 400 and do not complete the attempt', () async {
    final armed = server.arm([1], const ReplaySettings());
    expect((await _req('POST', '${armed.url}/result', body: '{"nope"')).$1, 400);
    expect(armed.isClosed, isFalse);
  });

  test('stdout fallback is bound to the attempt', () async {
    final armed = server.arm([1], const ReplaySettings());
    expect(server.offerLine(armed, 'noise'), isFalse);
    expect(server.offerLine(armed, 'I/flutter: ${ReplayProtocol.stdoutPrefix}${_report()}'), isTrue);
    expect(server.offerLine(armed, '${ReplayProtocol.stdoutPrefix}${_report()}'), isFalse);
  });

  test('binds loopback only by default', () async {
    expect(server.host, '127.0.0.1');
  });

  group('project config', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('bc-config'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('declared runtime wins over detection; --runtime wins over both', () {
      File('${dir.path}/package.json').writeAsStringSync('{}');
      File('${dir.path}/bugcapsule.json').writeAsStringSync('{"runtime":"android","timeouts":{"attemptSeconds":90}}');
      final c = ProjectConfig.load(dir.path);
      expect(c.resolveRuntime(), 'android');
      expect(c.resolveRuntime(override: 'web'), 'web');
      expect(c.attemptTimeout, const Duration(seconds: 90));
    });

    test('detection', () {
      expect(ProjectConfig.detectRuntime(dir.path), isNull);
      File('${dir.path}/package.json').writeAsStringSync('{}');
      expect(ProjectConfig.detectRuntime(dir.path), 'web');
      File('${dir.path}/settings.gradle.kts').writeAsStringSync('');
      expect(ProjectConfig.detectRuntime(dir.path), 'android');
      File('${dir.path}/pubspec.yaml').writeAsStringSync('');
      expect(ProjectConfig.detectRuntime(dir.path), 'flutter');
    });

    test('rejects unknown runtimes and bad JSON', () {
      File('${dir.path}/bugcapsule.json').writeAsStringSync('{"runtime":"symbian"}');
      expect(() => ProjectConfig.load(dir.path), throwsStateError);
      File('${dir.path}/bugcapsule.json').writeAsStringSync('{');
      expect(() => ProjectConfig.load(dir.path), throwsStateError);
    });

    test('a capsule from another runtime is INCOMPATIBLE without launching', () {
      final fixture = jsonDecode(File('../../spec/fixtures/capsule-v1/valid/android-runtime.json').readAsStringSync()) as Map;
      final capsule = CapsuleCodec.fromJson((fixture['document'] as Map).cast<String, Object?>());
      expect(capsule.manifest.runtimeName, 'android');
      expect(runtimeMismatch(capsule, 'android'), isNull);
      final why = runtimeMismatch(capsule, 'web')!;
      final s = incompatibleSummary(ReplayKind.verify, 3, why, runtime: 'web');
      expect(s.verdict, Verdict.incompatible);
      expect(exitCodeFor(s), 3);
      expect(s.reports.single.divergences.single.type, 'runtime.mismatch');
    });

    test('legacy Flutter capsules infer the flutter runtime', () {
      final fixture = jsonDecode(File('../../spec/fixtures/capsule-v1/valid/full.json').readAsStringSync()) as Map;
      final capsule = CapsuleCodec.fromJson((fixture['document'] as Map).cast<String, Object?>());
      expect(capsule.manifest.runtime, isNull);
      expect(capsule.manifest.runtimeName, 'flutter');
    });
  });
}
