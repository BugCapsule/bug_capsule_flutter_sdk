import 'dart:io';

import 'package:bug_capsule/src/cli/backend_client.dart';
import 'package:bug_capsule/src/cli/browser_login.dart';
import 'package:bug_capsule/src/cli/capsule_source.dart';
import 'package:test/test.dart';

/// The CLI writes, downloads and opens things a capsule or a server chose
/// (BC-ENT-033).
void main() {
  group('capsule file names (C1)', () {
    test('a plain id becomes <id>.bugcapsule', () {
      expect(capsuleFileName('cap-1_A.b'), 'cap-1_A.b.bugcapsule');
    });

    test('an id that could name another directory is refused', () {
      for (final id in ['../evil', 'a/b', '..', '.', r'a\b', '', 'x' * 101]) {
        expect(() => capsuleFileName(id), throwsStateError, reason: id);
      }
    });
  });

  group('sign-in page (browser login)', () {
    final api = Uri.parse('https://api.bugcapsule.com');

    test('opens an https page of the same site', () {
      expect(
        isTrustedLoginPage(
          Uri.parse('https://app.bugcapsule.com/cli/login?code=X'),
          api,
        ),
        isTrue,
      );
    });

    test('refuses another site, plain http and user info', () {
      for (final page in [
        'https://evil.example/cli/login',
        'http://app.bugcapsule.com/cli/login',
        'https://user:pw@app.bugcapsule.com/cli/login',
        'file:///etc/passwd',
        'javascript:alert(1)',
      ]) {
        expect(
          isTrustedLoginPage(Uri.tryParse(page), api),
          isFalse,
          reason: page,
        );
      }
    });

    test('allows http only between local development hosts', () {
      expect(
        isTrustedLoginPage(
          Uri.parse('http://127.0.0.1:5173/cli/login'),
          Uri.parse('http://127.0.0.1:8787'),
        ),
        isTrue,
      );
    });
  });

  group('downloads', () {
    late HttpServer server;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() => server.close(force: true));

    test('a response larger than the cap is refused while streaming', () async {
      server.listen((req) async {
        req.response.headers.contentType = ContentType.binary;
        // Endless stream: the client must stop reading at the cap.
        final chunk = List<int>.filled(1024 * 1024, 0);
        try {
          for (var i = 0; i < maxResponseBytes ~/ chunk.length + 2; i++) {
            req.response.add(chunk);
            await req.response.flush();
          }
          await req.response.close();
        } catch (_) {
          // client went away
        }
      });
      final client = BackendClient(
        Credentials(url: 'http://127.0.0.1:${server.port}', token: 'bcp_test'),
      );
      await expectLater(
        client.downloadCapsule('cap-1'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'response_too_large',
          ),
        ),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test(
    'saved credentials are never readable by others (C config mode)',
    () async {
      if (Platform.isWindows) return;
      final dir = await Directory.systemTemp.createTemp('bc_creds');
      try {
        final file = File('${dir.path}/config.json');
        const Credentials(
          url: 'https://api.example',
          token: 'bcp_secret',
        ).saveTo(file);
        final mode = (await Process.run('stat', [
          Platform.isMacOS ? '-f%Lp' : '-c%a',
          file.path,
        ])).stdout;
        expect('$mode'.trim(), '600');
        expect(File('${file.path}.tmp').existsSync(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
