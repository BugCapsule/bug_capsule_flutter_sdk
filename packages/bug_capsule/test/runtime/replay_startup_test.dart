import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

List<int> capsuleBytes({
  bool incompatibleSchema = false,
  bool missingAdapter = false,
}) {
  final fixture =
      jsonDecode(
            File(
              '../../spec/fixtures/capsule-v1/valid/minimal.json',
            ).readAsStringSync(),
          )
          as Map;
  final document = (fixture['document'] as Map).cast<String, Object?>();
  final manifest = document['manifest'] as Map;
  if (incompatibleSchema) {
    manifest['stateSchemaVersion'] = 2;
    (document['checkpoint'] as Map)['kind'] = 'periodic';
  }
  if (missingAdapter) {
    document['specVersion'] = 2;
    manifest['dependencies'] = [
      const CapsuleDependency(
        id: 'socket',
        kind: 'websocket',
        adapter: 'bug_capsule.web_socket',
        adapterVersion: '1.0.0',
        schema: 1,
        required: true,
        coverage: DependencyCoverage.complete,
      ).toJson(),
    ];
  }
  // Validate fixtures before serving them so preflight tests cannot pass
  // accidentally because the capsule failed to decode instead.
  return CapsuleCodec.encode(CapsuleCodec.fromJson(document));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHttpOverrides = HttpOverrides.current;
  setUp(() => HttpOverrides.global = null);
  tearDown(() async {
    await BugCapsule.resetForTest();
    BugCapsule.debugOverrides = null;
    HttpOverrides.global = previousHttpOverrides;
  });

  for (final failure in [
    'download',
    'malformed capsule',
    'state schema',
    'dependency',
  ]) {
    test('replay $failure failure reports and never starts the app', () async {
      final bytes = failure == 'malformed capsule'
          ? utf8.encode('not a capsule')
          : capsuleBytes(
              incompatibleSchema: failure == 'state schema',
              missingAdapter: failure == 'dependency',
            );
      final reports = <Map<String, Object?>>[];
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        switch (request.uri.path) {
          case '/settings':
            request.response.write(jsonEncode(const ReplaySettings().toJson()));
          case '/capsule':
            if (failure == 'download') {
              request.response.statusCode = 503;
            } else {
              request.response.add(bytes);
            }
          case '/result':
            reports.add(
              (jsonDecode(await utf8.decodeStream(request)) as Map)
                  .cast<String, Object?>(),
            );
          default:
            request.response.statusCode = 404;
        }
        await request.response.close();
      });

      var appStarts = 0;
      var transportCalls = 0;
      final integration = BugCapsuleHttp();
      final client = integration.client(
        MockClient((_) async {
          transportCalls++;
          return http.Response('synthetic response', 200);
        }),
      );
      addTearDown(client.close);
      await BugCapsule.init(
        config: BugCapsuleConfig(
          appVersion: '1',
          appBuild: '1',
          stateSchemaVersion: 1,
          replayUrl: 'http://127.0.0.1:${server.port}',
        ),
        integrations: [integration],
        appRunner: () async {
          appStarts++;
          await client.post(Uri.parse('https://synthetic.invalid/startup'));
        },
      );

      expect(requests, ['GET /settings', 'GET /capsule', 'POST /result']);
      expect(reports, hasLength(1));
      expect(
        reports.single['outcome'],
        failure == 'download' ? 'error' : 'incompatible',
      );
      expect(
        reports.single['message'],
        contains(switch (failure) {
          'download' => 'capsule download failed: HTTP 503',
          'malformed capsule' => 'not a gzip file',
          'state schema' => 'state schema v2 captured, app is v1',
          _ => 'dependency.unsupported:',
        }),
      );
      expect(
        appStarts,
        0,
        reason: 'Rejected replay must not enter application startup',
      );
      expect(
        transportCalls,
        0,
        reason: 'Rejected replay must not send startup requests',
      );
      expect(BugCapsule.isRecording, isFalse);
    });
  }

  test(
    'normal capture storage failure still starts the app and permits its requests',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bugcapsule-capture-failure-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/not-a-directory')
        ..writeAsStringSync('x');
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: Directory(file.path),
      );
      var appStarts = 0;
      var transportCalls = 0;
      final integration = BugCapsuleHttp();
      final client = integration.client(
        MockClient((_) async {
          transportCalls++;
          return http.Response('synthetic response', 200);
        }),
      );
      addTearDown(client.close);
      await BugCapsule.init(
        config: const BugCapsuleConfig(
          appVersion: '1',
          appBuild: '1',
          mode: CaptureMode.qa,
        ),
        integrations: [integration],
        appRunner: () async {
          appStarts++;
          await client.post(Uri.parse('https://synthetic.invalid/startup'));
        },
      );
      expect(appStarts, 1);
      expect(transportCalls, 1);
      expect(BugCapsule.isRecording, isFalse);
    },
  );
}
