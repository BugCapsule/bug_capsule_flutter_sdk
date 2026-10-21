import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bug_capsule/bug_capsule.dart';

class FakeSession implements BugCapsuleSession {
  FakeSession({this.replay, this.bodies = true, this.maxBody = 1 << 20});

  final List<BugCapsuleEvent> events = [];
  final bool bodies;
  final int maxBody;
  int _t = 0;

  @override
  final ReplayContext? replay;
  @override
  BugCapsuleConfig get config => const BugCapsuleConfig(appVersion: '1', appBuild: '1');
  @override
  CaptureMode get mode => CaptureMode.qa;
  @override
  bool get isRecording => replay == null;
  @override
  bool get isReplaying => replay != null;
  @override
  final Redactor redactor = Redactor();
  @override
  bool get captureNetworkBodies => bodies;
  @override
  int get maxBodyBytes => maxBody;
  @override
  int now() => _t += 10;
  @override
  void record(String type, [Map<String, Object?> data = const {}]) =>
      events.add(BugCapsuleEvent(seq: events.length + 1, t: now(), type: type, data: data));
  @override
  void reportError(Object error, StackTrace? stack) {}

  List<BugCapsuleEvent> get http => [for (final e in events) if (e.type == EventTypes.http) e];
}

class FakeReplay implements ReplayContext {
  FakeReplay(List<BugCapsuleEvent> events)
      : fixtures = FixtureStore(events),
        capsule = Capsule(
          manifest: CapsuleManifest.fromJson(const {
            'capsuleId': 'x',
            'createdAt': '2026-10-19T00:00:00Z',
            'mode': 'qa',
            'app': {'version': '1', 'build': '1'},
            'platform': {'os': 'ios'},
            'session': {
              'id': 's',
              'startedAt': '2026-10-19T00:00:00Z',
              'wallClockAtAnchorMs': 0,
              'seed': 1,
              'durationMs': 0,
            },
            'eligibility': {'status': 'eligible', 'missing': []},
          }),
          checkpoint: const Checkpoint(kind: CheckpointKind.launch, t: 0, wallClockMs: 0, afterSeq: 0),
          events: events,
        );

  @override
  final Capsule capsule;
  @override
  final FixtureStore fixtures;
  @override
  ReplaySettings settings = const ReplaySettings();
  final List<String> divergences = [];
  int served = 0;
  int work = 0;

  @override
  void diverge(String type, String detail) => divergences.add('$type $detail');
  @override
  void fixtureServed() => served++;
  @override
  void Function() beginWork() {
    work++;
    return () => work--;
  }

  @override
  void activity() {}
}

/// Answers with an incrementing counter, so capture vs replay differences
/// are visible, and remembers the request bodies it received.
class CountingServer {
  int calls = 0;
  final List<String> received = [];

  late final MockClient client = MockClient((request) async {
    calls++;
    received.add(request.body);
    return http.Response(jsonEncode({'call': calls, 'token': 'secret-$calls'}), 200,
        headers: {'content-type': 'application/json', 'content-length': '999'}, reasonPhrase: 'OK');
  });
}

Future<http.Client> clientWith(BugCapsuleHttp bugCapsule, BugCapsuleSession session, http.Client server) async {
  await bugCapsule.setUp(session);
  return bugCapsule.client(server);
}

final api = Uri.parse('https://api.test');

void main() {
  test('captures exchanges with redaction and replays them in order', () async {
    final capture = FakeSession();
    final server = CountingServer();
    final client = await clientWith(
      BugCapsuleHttp(rules: [EndpointRule('POST', '/pay', ignoreBodyFields: {'nonce'})]),
      capture,
      server.client,
    );

    await client.get(api.resolve('/items'), headers: {'Authorization': 'Bearer t'});
    await client.get(api.resolve('/items'));
    await client.post(api.resolve('/pay'),
        headers: {'content-type': 'application/json'}, body: jsonEncode({'amount': 5, 'nonce': 1}));

    // The server saw the app's request untouched.
    expect(server.received.last, jsonEncode({'amount': 5, 'nonce': 1}));

    final recorded = capture.http;
    expect(recorded, hasLength(3));
    expect(recorded[0].data['key'], 'GET api.test/items');
    expect(recorded[0].data['occurrence'], 0);
    expect(recorded[1].data['occurrence'], 1);
    expect(recorded[0].data['statusMessage'], 'OK');
    expect((recorded[0].data['requestHeaders'] as Map)['authorization'], Redactor.placeholder);
    expect((recorded[0].data['responseBody'] as Map)['token'], Redactor.placeholder);
    expect(recorded[2].data['requestBody'], {'amount': 5, 'nonce': 1});

    // Replay: the real server is not called; responses come back in recorded
    // occurrence order, and the volatile nonce does not matter.
    final replay = FakeReplay(recorded);
    final replayServer = CountingServer();
    final replayClient = await clientWith(
      BugCapsuleHttp(rules: [EndpointRule('POST', '/pay', ignoreBodyFields: {'nonce'})]),
      FakeSession(replay: replay),
      replayServer.client,
    );
    final first = await replayClient.get(api.resolve('/items'));
    final second = await replayClient.get(api.resolve('/items'));
    final pay = await replayClient.post(api.resolve('/pay'),
        headers: {'content-type': 'application/json'}, body: jsonEncode({'amount': 5, 'nonce': 999}));

    expect((jsonDecode(first.body) as Map)['call'], 1);
    expect((jsonDecode(second.body) as Map)['call'], 2);
    expect((jsonDecode(pay.body) as Map)['call'], 3);
    // Recorded length described the original bytes, not the replayed ones.
    expect(first.headers['content-length'], isNot('999'));
    expect(replayServer.calls, 0);
    expect(replay.served, 3);
    expect(replay.divergences, isEmpty);
  });

  test('requests keep the same key as Dio for the same exchange', () async {
    final session = FakeSession();
    final client = await clientWith(BugCapsuleHttp(), session, CountingServer().client);
    await client.get(api.resolve('/items?b=2&a=1&ts=99'));
    expect(session.http.single.data['key'], 'GET api.test/items?a=1&b=2');
  });

  test('integrations of one session number requests in one order', () async {
    final session = FakeSession();
    final one = await clientWith(BugCapsuleHttp(), session, CountingServer().client);
    final two = await clientWith(BugCapsuleHttp(), session, CountingServer().client);
    await one.get(api.resolve('/items'));
    await two.get(api.resolve('/items'));
    expect([for (final e in session.http) e.data['occurrence']], [0, 1]);
  });

  test('requests sent before setup pass through unrecorded', () async {
    final server = CountingServer();
    final client = BugCapsuleHttp().client(server.client);
    final response = await client.get(api.resolve('/early'));
    expect(response.statusCode, 200);
    expect(server.calls, 1);
  });

  test('strict replay fails unrecorded requests and reports a divergence', () async {
    final replay = FakeReplay(const []);
    final server = CountingServer();
    final client = await clientWith(BugCapsuleHttp(), FakeSession(replay: replay), server.client);
    await expectLater(client.get(api.resolve('/unknown')), throwsA(isA<http.ClientException>()));
    expect(replay.divergences.single, 'network.unrecorded GET api.test/unknown');
    expect(server.calls, 0);
  });

  test('replays recorded transport errors and cancellations', () async {
    BugCapsuleEvent failed(String path, String type) => BugCapsuleEvent(seq: 1, t: 0, type: EventTypes.http, data: {
          'key': 'GET api.test$path',
          'occurrence': 0,
          'status': 0,
          'durationMs': 5,
          'bodyEncoding': 'omitted',
          'error': {'type': type, 'message': 'timed out'},
        });
    final replay = FakeReplay([failed('/down', 'connectionTimeout'), failed('/gone', 'cancel')]);
    final client = await clientWith(BugCapsuleHttp(), FakeSession(replay: replay), CountingServer().client);
    await expectLater(
      client.get(api.resolve('/down')),
      throwsA(isA<http.ClientException>().having((e) => e.message, 'message', 'timed out')),
    );
    await expectLater(client.get(api.resolve('/gone')), throwsA(isA<http.RequestAbortedException>()));
  });

  test('a replayed response keeps its recorded latency and can be aborted', () async {
    const event = BugCapsuleEvent(seq: 1, t: 0, type: EventTypes.http, data: {
      'key': 'GET api.test/slow',
      'occurrence': 0,
      'status': 200,
      'durationMs': 200,
      'responseHeaders': {'content-type': 'application/json'},
      'responseBody': {'ok': true},
      'bodyEncoding': 'json',
    });
    final replay = FakeReplay(const [event, event]);
    final client = await clientWith(BugCapsuleHttp(), FakeSession(replay: replay), CountingServer().client);

    final watch = Stopwatch()..start();
    final response = client.get(api.resolve('/slow'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(replay.work, 1);
    expect(jsonDecode((await response).body), {'ok': true});
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(200));
    expect(replay.work, 0);

    final abort = Completer<void>();
    final request = http.AbortableRequest('GET', api.resolve('/slow'), abortTrigger: abort.future);
    final aborted = client.send(request);
    abort.complete();
    await expectLater(aborted, throwsA(isA<http.RequestAbortedException>()));
  });

  test('response bytes stream through; large bodies are truncated, not buffered', () async {
    final session = FakeSession(maxBody: 16);
    final chunks = StreamController<List<int>>();
    final server = MockClient.streaming((request, body) async {
      await body.drain<void>();
      return http.StreamedResponse(chunks.stream, 200, headers: {'content-type': 'text/plain'});
    });
    final client = await clientWith(BugCapsuleHttp(), session, server);
    final response = await client.send(http.Request('GET', api.resolve('/big')));
    final received = <List<int>>[];
    final done = response.stream.listen(received.add).asFuture<void>();
    chunks
      ..add(utf8.encode('0123456789'))
      ..add(utf8.encode('abcdefghij'));
    await chunks.close();
    await done;

    expect(received.map(utf8.decode).join(), '0123456789abcdefghij');
    expect(session.http.single.data['bodyEncoding'], 'truncated');
    expect(session.http.single.data.containsKey('responseBody'), isFalse);
  });

  test('with bodies off, the exchange is recorded when headers arrive', () async {
    final session = FakeSession(bodies: false);
    final client = await clientWith(BugCapsuleHttp(), session, CountingServer().client);
    final response = await client.post(api.resolve('/pay'),
        headers: {'content-type': 'application/json'}, body: jsonEncode({'amount': 5}));
    expect((jsonDecode(response.body) as Map)['call'], 1);
    final data = session.http.single.data;
    expect(data['bodyEncoding'], 'omitted');
    expect(data['requestEncoding'], 'omitted');
    expect(data['requestBody'], isNull);
    // The body hash still takes part in the key, so replay can match it.
    expect(data['key'], startsWith('POST api.test/pay#'));
  });

  test('excluded requests record no headers or bodies', () async {
    final session = FakeSession();
    final client = await clientWith(
      BugCapsuleHttp(exclude: (r) => r.url.path == '/login'),
      session,
      CountingServer().client,
    );
    await client.post(api.resolve('/login'), body: 'user=a&password=b');
    final data = session.http.single.data;
    expect(data['excluded'], isTrue);
    expect(data.containsKey('requestHeaders'), isFalse);
    expect(data.containsKey('responseHeaders'), isFalse);
    expect(data['bodyEncoding'], 'omitted');
  });

  test('transport errors are recorded and rethrown', () async {
    final session = FakeSession();
    final server = MockClient((_) async => throw http.ClientException('connection refused'));
    final client = await clientWith(BugCapsuleHttp(), session, server);
    await expectLater(client.get(api.resolve('/down')), throwsA(isA<http.ClientException>()));
    final data = session.http.single.data;
    expect(data['status'], 0);
    expect(data['error'], {'type': 'connectionError', 'message': 'connection refused'});
  });

  test('responses without a body make the capsule partial', () async {
    final session = FakeSession(bodies: false);
    final bugCapsule = BugCapsuleHttp();
    final client = await clientWith(bugCapsule, session, CountingServer().client);
    await client.get(api.resolve('/items'));
    final eligibility = EligibilityBuilder();
    bugCapsule.describeEligibility(
      eligibility,
      RecordedWindow(
        checkpoint: const Checkpoint(kind: CheckpointKind.launch, t: 0, wallClockMs: 0, afterSeq: 0),
        events: session.events,
        droppedEvents: 0,
        hasGap: false,
      ),
    );
    expect(eligibility.build().status, EligibilityStatus.partial);
  });

  test('streamed uploads reach a real server through the default client', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'echo': body, 'length': request.headers.contentLength}));
      await request.response.close();
    });

    final session = FakeSession();
    final bugCapsule = BugCapsuleHttp();
    await bugCapsule.setUp(session);
    final client = bugCapsule.client();
    addTearDown(client.close);

    final request = http.StreamedRequest('PUT', Uri.parse('http://127.0.0.1:${server.port}/upload'))
      ..headers['content-type'] = 'text/plain'
      ..contentLength = 10;
    final sent = client.send(request);
    request.sink
      ..add(utf8.encode('hello'))
      ..add(utf8.encode('world'));
    await request.sink.close();
    final response = await http.Response.fromStream(await sent);

    expect(jsonDecode(response.body), {'echo': 'helloworld', 'length': 10});
    final data = session.http.single.data;
    expect(data['requestBody'], 'helloworld');
    expect(data['responseBody'], {'echo': 'helloworld', 'length': 10});
  });
}
