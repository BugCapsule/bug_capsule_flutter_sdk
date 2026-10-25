import 'dart:io';

import 'package:bug_capsule/src/cli/launcher.dart';
import 'package:bug_capsule/src/cli/launchers/web.dart';
import 'package:bug_capsule/src/cli/project_config.dart';
import 'package:bug_capsule/src/cli/replay_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late ReplayServer server;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('bc-web');
    server = await ReplayServer.start();
  });
  tearDown(() async {
    await server.close();
    dir.deleteSync(recursive: true);
  });

  WebLauncher launcher(
    String json, {
    Map<String, String> artifacts = const {},
  }) {
    File('${dir.path}/bugcapsule.json').writeAsStringSync(json);
    return WebLauncher(
      LaunchOptions(
        runtime: 'web',
        projectDir: dir.path,
        config: ProjectConfig.load(dir.path),
        artifacts: artifacts,
      ),
    );
  }

  void installRunner() {
    final bin = File(
      '${dir.path}/node_modules/@bugcapsule/web-replay/bin/bugcapsule-web-runner.js',
    )..createSync(recursive: true);
    bin.writeAsStringSync('// stub');
  }

  test(
    'refuses to serve over something already listening on web.url (it may be an old build)',
    () async {
      installRunner();
      final busy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      busy.listen((r) => r.response.close());
      try {
        final l = launcher(
          '{"runtime":"web","web":{"url":"http://127.0.0.1:${busy.port}/","serveCommand":"true"}}',
        );
        await expectLater(
          l.prepare(server),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('already serves'),
            ),
          ),
        );
      } finally {
        await busy.close(force: true);
      }
    },
  );

  test(
    'uses an already running app with --app-url, and requires it to respond',
    () async {
      installRunner();
      final app = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      app.listen((r) => r.response.close());
      try {
        final l = launcher(
          '{"runtime":"web"}',
          artifacts: {'app-url': 'http://127.0.0.1:${app.port}/'},
        );
        await l.prepare(server);
        expect(l.target, contains('127.0.0.1:${app.port}'));
      } finally {
        await app.close(force: true);
      }
      final dead = launcher(
        '{"runtime":"web"}',
        artifacts: {'app-url': 'http://127.0.0.1:1/'},
      );
      await expectLater(dead.prepare(server), throwsA(isA<StateError>()));
    },
  );

  test('explains a missing @bugcapsule/web-replay', () async {
    final l = launcher(
      '{"runtime":"web"}',
      artifacts: {'app-url': 'http://127.0.0.1:1/'},
    );
    await expectLater(
      l.prepare(server),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('@bugcapsule/web-replay'),
        ),
      ),
    );
  });

  test('only chromium is accepted', () async {
    installRunner();
    final l = launcher('{"runtime":"web","web":{"browser":"firefox"}}');
    await expectLater(
      l.prepare(server),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('chromium'),
        ),
      ),
    );
  });

  test(
    'a serve command that exits early fails prepare with its output',
    () async {
      installRunner();
      final l = launcher(
        '{"runtime":"web","web":{"url":"http://127.0.0.1:9/","serveCommand":"echo boom; exit 3","readyTimeoutSeconds":5}}',
      );
      await expectLater(
        l.prepare(server),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('boom'),
          ),
        ),
      );
    },
  );
}
