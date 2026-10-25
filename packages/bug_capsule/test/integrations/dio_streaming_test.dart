import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule/bug_capsule.dart';

/// Capture must stream: bytes reach the app as they arrive, only a bounded
/// prefix is retained, and nothing is buffered when bodies are off.

class StreamSession implements BugCapsuleSession {
  StreamSession({this.bodies = true, this.maxBody = 1024, this.replay});

  bool bodies;
  final int maxBody;
  final List<BugCapsuleEvent> events = [];

  @override
  final ReplayContext? replay;
  @override
  BugCapsuleConfig get config =>
      const BugCapsuleConfig(appVersion: '1', appBuild: '1');
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
  int now() => events.length;
  @override
  void record(String type, [Map<String, Object?> data = const {}]) =>
      events.add(
        BugCapsuleEvent(
          seq: events.length + 1,
          t: now(),
          type: type,
          data: data,
        ),
      );
  @override
  void reportError(Object error, StackTrace? stack) {}

  List<Map<String, Object?>> get http => [
    for (final e in events)
      if (e.type == EventTypes.http) e.data,
  ];
}

class Replay implements ReplayContext {
  Replay(List<BugCapsuleEvent> events)
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
        checkpoint: const Checkpoint(
          kind: CheckpointKind.launch,
          t: 0,
          wallClockMs: 0,
          afterSeq: 0,
        ),
        events: events,
      );

  @override
  final Capsule capsule;
  @override
  final FixtureStore fixtures;
  @override
  ReplaySettings settings = const ReplaySettings();
  final List<String> divergences = [];

  @override
  void diverge(String type, String detail) => divergences.add('$type $detail');
  @override
  void fixtureServed() {}
  @override
  void Function() beginWork() => () {};
  @override
  void activity() {}
}

/// A server whose response body is a stream the test controls.
class StreamingServer implements HttpClientAdapter {
  StreamingServer({
    this.contentType = 'application/octet-stream',
    this.status = 200,
  });

  final String contentType;
  final int status;
  final StreamController<Uint8List> body = StreamController<Uint8List>();
  final BytesBuilder received = BytesBuilder();
  bool upstreamCancelled = false;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        received.add(chunk);
      }
    }
    body.onCancel = () => upstreamCancelled = true;
    return ResponseBody(
      body.stream,
      status,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers every request with a fixed JSON body.
class JsonServer implements HttpClientAdapter {
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    calls++;
    return ResponseBody.fromString(
      jsonEncode({'ok': calls}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<Dio> dioFor(
  BugCapsuleDio bugCapsule,
  BugCapsuleSession session,
  HttpClientAdapter server,
) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = server;
  await bugCapsule.setUp(session);
  bugCapsule.attach(dio);
  return dio;
}

Uint8List randomBytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

void main() {
  test('delivers the first chunk before the response completes', () async {
    final session = StreamSession();
    final server = StreamingServer();
    final dio = await dioFor(BugCapsuleDio(), session, server);

    final response = await dio.get<ResponseBody>(
      '/download',
      options: Options(responseType: ResponseType.stream),
    );
    final first = Completer<Uint8List>();
    final sub = response.data!.stream.listen((c) {
      if (!first.isCompleted) first.complete(c);
    });
    server.body.add(Uint8List.fromList([1, 2, 3]));
    expect(await first.future.timeout(const Duration(seconds: 2)), [1, 2, 3]);
    expect(
      session.http,
      isEmpty,
      reason: 'recorded only once the body completes',
    );
    await server.body.close();
    await sub.asFuture<void>();
    expect(session.http.single['bodyEncoding'], 'base64');
    expect(base64Decode(session.http.single['responseBody'] as String), [
      1,
      2,
      3,
    ]);
  });

  test(
    'a large download streams through unchanged while retention stays bounded',
    () async {
      final session = StreamSession(maxBody: 64 * 1024);
      final server = StreamingServer();
      final dio = await dioFor(
        BugCapsuleDio(maxBinaryBytes: 64 * 1024),
        session,
        server,
      );
      final payload = randomBytes(4 * 1024 * 1024, 1);

      final response = await dio.get<ResponseBody>(
        '/big',
        options: Options(responseType: ResponseType.stream),
      );
      final got = BytesBuilder(copy: false);
      final done = response.data!.stream.listen(got.add).asFuture<void>();
      for (var i = 0; i < payload.length; i += 32 * 1024) {
        server.body.add(
          Uint8List.sublistView(payload, i, min(i + 32 * 1024, payload.length)),
        );
        await Future<void>.delayed(Duration.zero);
        if (i == 128 * 1024) {
          // Past the limit the exchange is already recorded as truncated, while
          // the body is still streaming.
          expect(session.http.single['bodyEncoding'], 'truncated');
          expect(session.http.single['responseBody'], isNull);
        }
      }
      await server.body.close();
      await done;
      expect(got.toBytes(), payload);
      expect(session.http, hasLength(1));
    },
  );

  test(
    'with bodies off nothing is buffered: recorded at headers, stream untouched',
    () async {
      final session = StreamSession(bodies: false);
      final server = StreamingServer(contentType: 'application/json');
      final dio = await dioFor(BugCapsuleDio(), session, server);

      final response = await dio.get<ResponseBody>(
        '/feed',
        options: Options(responseType: ResponseType.stream),
      );
      expect(session.http.single['bodyEncoding'], 'omitted');
      expect(session.http.single['responseBody'], isNull);
      final got = <int>[];
      final done = response.data!.stream.listen(got.addAll).asFuture<void>();
      server.body.add(
        Uint8List.fromList(utf8.encode('{"token":"synthetic-secret"}')),
      );
      await server.body.close();
      await done;
      expect(
        utf8.decode(got),
        '{"token":"synthetic-secret"}',
        reason: 'app sees the real bytes',
      );
      expect(
        jsonEncode(session.events.map((e) => e.data).toList()),
        isNot(contains('synthetic-secret')),
      );
    },
  );

  test(
    'cancelling mid-stream cancels upstream and records the cancellation',
    () async {
      final session = StreamSession();
      final server = StreamingServer();
      final dio = await dioFor(BugCapsuleDio(), session, server);
      final cancel = CancelToken();

      final response = await dio.get<ResponseBody>(
        '/slow',
        cancelToken: cancel,
        options: Options(responseType: ResponseType.stream),
      );
      final errors = <Object>[];
      response.data!.stream.listen((_) {}, onError: errors.add);
      server.body.add(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);
      // Dio cancels the adapter's stream through the CancelToken.
      cancel.cancel('user left the screen');
      await Future<void>.delayed(Duration.zero);
      expect(server.upstreamCancelled, isTrue);
      expect(errors.single, isA<DioException>());
      expect(session.http.single['bodyEncoding'], 'truncated');
      expect((session.http.single['error'] as Map)['type'], 'cancel');
    },
  );

  test('a stream error reaches the app and is recorded', () async {
    final session = StreamSession();
    final server = StreamingServer();
    final dio = await dioFor(BugCapsuleDio(), session, server);
    final response = await dio.get<ResponseBody>(
      '/broken',
      options: Options(responseType: ResponseType.stream),
    );
    final errors = <Object>[];
    final done = Completer<void>();
    response.data!.stream.listen(
      (_) {},
      onError: errors.add,
      onDone: done.complete,
    );
    server.body.addError(const SocketExceptionLike('connection reset'));
    await server.body.close();
    await done.future;
    expect(errors, hasLength(1));
    expect(session.http.single['error'], isNotNull);
  });

  test(
    'a long-lived stream is recorded as truncated after maxBodyWait',
    () async {
      final session = StreamSession();
      final server = StreamingServer(contentType: 'application/x-ndjson');
      final dio = await dioFor(
        BugCapsuleDio(maxBodyWait: const Duration(milliseconds: 50)),
        session,
        server,
      );
      final response = await dio.get<ResponseBody>(
        '/stream',
        options: Options(responseType: ResponseType.stream),
      );
      final sub = response.data!.stream.listen((_) {});
      server.body.add(Uint8List.fromList(utf8.encode('{"n":1}\n')));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(session.http.single['bodyEncoding'], 'truncated');
      server.body.add(Uint8List.fromList(utf8.encode('{"n":2}\n')));
      await server.body.close();
      await sub.asFuture<void>();
      expect(session.http, hasLength(1));
    },
  );

  test('a large upload streams with progress and is not retained', () async {
    final session = StreamSession(maxBody: 1024);
    final server = JsonServerCollecting();
    final dio = await dioFor(
      BugCapsuleDio(maxKeyBodyBytes: 1024),
      session,
      server,
    );
    final payload = randomBytes(2 * 1024 * 1024, 2);
    final progress = <int>[];
    await dio.post<Object?>(
      '/upload',
      data: Stream.fromIterable([
        for (var i = 0; i < payload.length; i += 64 * 1024)
          payload.sublist(i, min(i + 64 * 1024, payload.length)),
      ]),
      options: Options(
        contentType: 'application/octet-stream',
        headers: {Headers.contentLengthHeader: payload.length},
      ),
      onSendProgress: (sent, _) => progress.add(sent),
    );
    expect(
      server.received.toBytes(),
      payload,
      reason: 'server got the exact bytes',
    );
    expect(
      progress.length,
      greaterThan(2),
      reason: 'progress is reported as the body streams',
    );
    final event = session.http.single;
    expect(event['requestEncoding'], 'truncated');
    expect(event['requestBody'], isNull);
    expect(
      event['key'],
      'POST api.test/upload',
      reason: 'large bodies are keyed without a hash',
    );
  });

  for (final bodies in [true, false]) {
    test(
      'capture (bodies ${bodies ? 'on' : 'off'}) and replay compute the same request key',
      () async {
        final capture = StreamSession(bodies: bodies);
        final dio = await dioFor(BugCapsuleDio(), capture, JsonServer());
        await dio.post<Object?>(
          '/cart',
          data: {'sku': 'cap', 'password': 'synthetic-pass'},
        );
        await dio.post<Object?>('/cart', data: {'sku': 'mug'});
        final recorded = capture.events
            .where((e) => e.type == EventTypes.http)
            .toList();
        expect(
          recorded[0].data['key'],
          isNot(recorded[1].data['key']),
          reason: 'bodies are keyed',
        );
        expect(
          jsonEncode(recorded.map((e) => e.data).toList()),
          isNot(contains('synthetic-pass')),
        );

        final replay = Replay(recorded);
        final replayServer = JsonServer();
        final replayDio = await dioFor(
          BugCapsuleDio(),
          StreamSession(replay: replay),
          replayServer,
        );
        await replayDio.post<Object?>(
          '/cart',
          data: {'sku': 'cap', 'password': 'synthetic-pass'},
        );
        await replayDio.post<Object?>('/cart', data: {'sku': 'mug'});
        expect(replayServer.calls, 0);
        expect(
          replay.divergences.where((d) => d.startsWith('network.unrecorded')),
          isEmpty,
        );
      },
    );
  }

  test(
    'a POST that never reached the server is keyed like its replay (connection error)',
    () async {
      final capture = StreamSession();
      final dio = await dioFor(BugCapsuleDio(), capture, RefusingServer());
      await expectLater(
        dio.post<Object?>('/pay', data: {'amount': 5}),
        throwsA(isA<DioException>()),
      );
      final recorded = capture.events
          .where((e) => e.type == EventTypes.http)
          .toList();
      expect(
        recorded.single.data['key'],
        contains('#'),
        reason: 'body hash present',
      );
      expect(recorded.single.data['requestBody'], {'amount': 5});

      final replay = Replay(recorded);
      final replayDio = await dioFor(
        BugCapsuleDio(),
        StreamSession(replay: replay),
        JsonServer(),
      );
      await expectLater(
        replayDio.post<Object?>('/pay', data: {'amount': 5}),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.connectionError,
          ),
        ),
      );
      expect(
        replay.divergences,
        isEmpty,
        reason: 'served from the recording, not unrecorded',
      );
    },
  );

  test(
    'concurrent identical requests keep their start order when they finish out of order',
    () async {
      final capture = StreamSession();
      final server = ControlledServer();
      final dio = await dioFor(BugCapsuleDio(), capture, server);
      final first = dio.get<Map<String, Object?>>('/cart');
      final second = dio.get<Map<String, Object?>>('/cart');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      server.finish(1, {'n': 'second'}); // the second request answers first
      server.finish(0, {'n': 'first'});
      expect((await first).data, {'n': 'first'});
      expect((await second).data, {'n': 'second'});

      final recorded = capture.events
          .where((e) => e.type == EventTypes.http)
          .toList();
      final replay = Replay(recorded);
      final replayDio = await dioFor(
        BugCapsuleDio(),
        StreamSession(replay: replay),
        JsonServer(),
      );
      final r1 = replayDio.get<Map<String, Object?>>('/cart');
      final r2 = replayDio.get<Map<String, Object?>>('/cart');
      expect((await r1).data, {
        'n': 'first',
      }, reason: 'occurrence 0 is the request that started first');
      expect((await r2).data, {'n': 'second'});
    },
  );

  test('a URL the redactor cannot parse never breaks the request', () async {
    final session = StreamSession();
    final dio = await dioFor(BugCapsuleDio(), session, JsonServer());
    final res = await dio.get<Object?>(
      'https://api.test/search?q=%FF&token=synthBad',
    );
    expect(res.statusCode, 200);
    expect(jsonEncode(session.http), isNot(contains('synthBad')));
  });

  test('excluded requests record no headers or bodies', () async {
    final session = StreamSession();
    final dio = await dioFor(
      BugCapsuleDio(exclude: (o) => o.path.endsWith('/login')),
      session,
      JsonServer(),
    );
    await dio.post<Object?>(
      '/login',
      data: {'user': 'a', 'note': 'synthetic-note'},
      options: Options(headers: {'X-Device': 'synthetic-device'}),
    );
    final event = session.http.single;
    expect(event['excluded'], isTrue);
    expect(event.containsKey('requestHeaders'), isFalse);
    expect(event.containsKey('responseHeaders'), isFalse);
    expect(event['responseBody'], isNull);
    expect(jsonEncode(event), isNot(contains('synthetic-')));
  });
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike(this.message);
  final String message;
  @override
  String toString() => 'SocketExceptionLike: $message';
}

class JsonServerCollecting extends JsonServer {
  final BytesBuilder received = BytesBuilder();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        received.add(chunk);
      }
    }
    return super.fetch(options, null, cancelFuture);
  }
}

/// Fails every request before reading its body, like a refused connection.
class RefusingServer implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers requests in the order the test chooses.
class ControlledServer implements HttpClientAdapter {
  final List<Completer<Map<String, Object?>>> pending = [];

  void finish(int i, Map<String, Object?> body) => pending[i].complete(body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final c = Completer<Map<String, Object?>>();
    pending.add(c);
    final body = await c.future;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
