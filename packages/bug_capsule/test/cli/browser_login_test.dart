import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:bug_capsule/src/cli/browser_login.dart';
import 'package:bug_capsule/src/cli/commands.dart';
import 'package:test/test.dart';

/// A backend that answers the CLI sign-in routes from a script.
class FakeBackend {
  FakeBackend(this.polls, {this.startStatus = 201});

  /// Answers to successive polls, last one repeated.
  final List<Map<String, Object?>> polls;
  final int startStatus;
  final requests = <(String, Map<String, Object?>)>[];
  late final HttpServer _server;
  var _poll = 0;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final body = (jsonDecode(await utf8.decodeStream(req)) as Map)
          .cast<String, Object?>();
      requests.add((req.uri.path, body));
      final res = req.response..headers.contentType = ContentType.json;
      if (req.uri.path == '/v1/console/cli/logins') {
        res.statusCode = startStatus;
        res.write(
          jsonEncode(
            startStatus == 201
                ? {
                    'deviceCode': 'd' * 43,
                    'userCode': 'BCDF-GHJK',
                    'verificationUrl': 'http://dash.test/cli/login',
                    'verificationUrlComplete':
                        'http://dash.test/cli/login?code=BCDF-GHJK',
                    'expiresAt': DateTime.now()
                        .add(const Duration(minutes: 10))
                        .toUtc()
                        .toIso8601String(),
                    'interval': 2,
                  }
                : {'code': 'not_found', 'title': 'Not Found'},
          ),
        );
      } else {
        res.write(
          jsonEncode(polls[_poll < polls.length ? _poll++ : polls.length - 1]),
        );
      }
      await res.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

const approved = {
  'status': 'approved',
  'token': 'bcp_new',
  'expiresAt': '2027-01-23T10:00:00.000Z',
  'project': {'id': 'p-1', 'name': 'Shop'},
  'user': {'email': 'dev@example.test', 'displayName': 'Dev'},
};

void main() {
  late FakeBackend backend;
  final opened = <String>[];
  final out = StringBuffer();

  BrowserLogin login({
    bool launch = true,
    bool openWorks = true,
    DateTime Function()? now,
  }) => BrowserLogin(
    url: backend.url,
    launch: launch,
    open: (u) async {
      opened.add(u);
      return openWorks;
    },
    sleep: (_) async {},
    now: now,
    out: out,
  );

  setUp(() {
    opened.clear();
    out.clear();
  });
  tearDown(() => backend.close());

  test(
    'opens the approval page, shows the code, polls until approved',
    () async {
      backend = FakeBackend([
        {'status': 'pending'},
        {'status': 'pending'},
        approved,
      ]);
      await backend.start();
      final r = await login().run();
      expect(r.token, 'bcp_new');
      expect(r.projectName, 'Shop');
      expect(r.email, 'dev@example.test');
      expect(opened, ['http://dash.test/cli/login?code=BCDF-GHJK']);
      expect(out.toString(), contains('BCDF-GHJK'));
      expect(backend.requests.first.$1, '/v1/console/cli/logins');
      expect(backend.requests.first.$2['clientName'], isNotEmpty);
      expect(
        backend.requests.where((r) => r.$1 == '/v1/console/cli/logins/poll'),
        hasLength(3),
      );
      expect(backend.requests.last.$2, {'deviceCode': 'd' * 43});
    },
  );

  test('--no-browser only prints the address', () async {
    backend = FakeBackend([approved]);
    await backend.start();
    await login(launch: false).run();
    expect(opened, isEmpty);
    expect(
      out.toString(),
      contains('Open http://dash.test/cli/login?code=BCDF-GHJK'),
    );
  });

  test('says so when no browser opens, and keeps waiting', () async {
    backend = FakeBackend([approved]);
    await backend.start();
    final r = await login(openWorks: false).run();
    expect(r.token, 'bcp_new');
    expect(out.toString(), contains('open the address above on any device'));
  });

  test('a canceled request ends with a clear message', () async {
    backend = FakeBackend([
      {'status': 'pending'},
      {'status': 'denied'},
    ]);
    await backend.start();
    expect(
      login().run(),
      throwsA(
        isA<BrowserLoginException>().having(
          (e) => e.message,
          'message',
          contains('canceled'),
        ),
      ),
    );
  });

  test('stops at the request’s expiry', () async {
    backend = FakeBackend([
      {'status': 'pending'},
    ]);
    await backend.start();
    expect(
      login(now: () => DateTime.now().add(const Duration(hours: 1))).run(),
      throwsA(
        isA<BrowserLoginException>().having(
          (e) => e.message,
          'message',
          contains('expired'),
        ),
      ),
    );
  });

  test('a backend without browser sign-in points to --token', () async {
    backend = FakeBackend([], startStatus: 404);
    await backend.start();
    expect(
      login().run(),
      throwsA(
        isA<BrowserLoginException>().having(
          (e) => e.message,
          'message',
          contains('--token'),
        ),
      ),
    );
  });

  test('an SDK token passed to --token says where it belongs', () async {
    backend = FakeBackend([]);
    await backend.start();
    for (final t in ['bcsdk.v1.eyJhcGkiOiJ4In0', 'bct_abc']) {
      expect(
        buildRunner().run(['login', '--url', backend.url, '--token', t]),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            allOf(contains('SDK token'), contains('bugcapsule login')),
          ),
        ),
      );
    }
  });

  test('the machine name is printable and short', () {
    final n = clientName();
    expect(n, isNotEmpty);
    expect(n.length, lessThanOrEqualTo(60));
    expect(n, isNot(contains('\n')));
  });
}
