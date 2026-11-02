import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule/bug_capsule.dart';

class _RealHttp extends HttpOverrides {}

/// When replay can't start, the failure is reported and the app's own startup
/// does not run: without the replay engine nothing stands between it and live
/// services (BC-ENT-014).
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bc_fail_closed');
  });
  tearDown(() async {
    await BugCapsule.resetForTest();
    BugCapsule.debugOverrides = null;
    await dir.delete(recursive: true);
  });

  Future<(Map<String, Object?>, bool)> replayWith(
    void Function(HttpRequest request) capsule,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final report = Completer<Map<String, Object?>>();
    server.listen((request) async {
      if (request.uri.path == '/settings') {
        request.response.write('{}');
      } else if (request.uri.path == '/capsule') {
        capsule(request);
      } else if (request.uri.path == '/result') {
        report.complete(
          (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
              .cast<String, Object?>(),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    var appStarted = false;
    try {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: dir,
      );
      await HttpOverrides.runWithHttpOverrides(
        () => BugCapsule.init(
          config: BugCapsuleConfig(
            appVersion: '1',
            appBuild: '1',
            mode: CaptureMode.qa,
            replayUrl: 'http://127.0.0.1:${server.port}',
          ),
          appRunner: () => appStarted = true,
        ),
        _RealHttp(),
      ).timeout(const Duration(seconds: 2));
      final result = await report.future.timeout(const Duration(seconds: 1));
      return (result, appStarted);
    } finally {
      await server.close(force: true);
    }
  }

  test('a capsule that cannot be downloaded does not start the app', () async {
    final (report, appStarted) = await replayWith(
      (r) => r.response.statusCode = 500,
    );
    expect(report['outcome'], anyOf('error', 'incompatible'));
    expect(appStarted, isFalse);
  });

  test('an unreadable capsule does not start the app', () async {
    final (report, appStarted) = await replayWith(
      (r) => r.response.add(utf8.encode('not a capsule')),
    );
    expect(report['outcome'], anyOf('error', 'incompatible'));
    expect(appStarted, isFalse);
  });
}
