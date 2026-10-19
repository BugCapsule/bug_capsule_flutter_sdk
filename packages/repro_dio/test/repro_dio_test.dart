import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:repro_dio/repro_dio.dart';
import 'package:repro_flutter/repro_flutter.dart';

/// Server that answers with an incrementing counter, so capture vs replay
/// differences are visible.
class CountingServer implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    await requestStream?.drain<void>();
    calls++;
    return ResponseBody.fromString(
      jsonEncode({'call': calls, 'token': 'secret-$calls'}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class FakeSession implements ReproSession {
  FakeSession({this.replay});

  final List<ReproEvent> events = [];
  int _t = 0;

  @override
  final ReplayContext? replay;
  @override
  ReproConfig get config => const ReproConfig(appVersion: '1', appBuild: '1');
  @override
  CaptureMode get mode => CaptureMode.qa;
  @override
  bool get isRecording => replay == null;
  @override
  bool get isReplaying => replay != null;
  @override
  final Redactor redactor = Redactor();
  @override
  bool get captureNetworkBodies => true;
  @override
  int get maxBodyBytes => 1 << 20;
  @override
  int now() => _t += 10;
  @override
  void record(String type, [Map<String, Object?> data = const {}]) =>
      events.add(ReproEvent(seq: events.length + 1, t: now(), type: type, data: data));
  @override
  void reportError(Object error, StackTrace? stack) {}
}

class FakeReplay implements ReplayContext {
  FakeReplay(List<ReproEvent> events)
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
              kind: CheckpointKind.launch, t: 0, wallClockMs: 0, afterSeq: 0),
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

  @override
  void diverge(String type, String detail) => divergences.add('$type $detail');
  @override
  void fixtureServed() => served++;
}

Future<Dio> dioWith(ReproDio repro, ReproSession session, HttpClientAdapter server) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))..httpClientAdapter = server;
  await repro.setUp(session);
  repro.attach(dio);
  return dio;
}

void main() {
  test('captures exchanges with redaction and replays them in order', () async {
    final capture = FakeSession();
    final server = CountingServer();
    final dio = await dioWith(
      ReproDio(rules: [EndpointRule('POST', '/pay', ignoreBodyFields: {'nonce'})]),
      capture,
      server,
    );

    await dio.get<Map<String, Object?>>('/items', options: Options(headers: {'Authorization': 'Bearer t'}));
    await dio.get<Map<String, Object?>>('/items');
    await dio.post<Map<String, Object?>>('/pay', data: {'amount': 5, 'nonce': 1});

    final http = capture.events.where((e) => e.type == EventTypes.http).toList();
    expect(http, hasLength(3));
    expect(http[0].data['occurrence'], 0);
    expect(http[1].data['occurrence'], 1);
    expect((http[0].data['requestHeaders'] as Map)['authorization'], Redactor.placeholder);
    expect((http[0].data['responseBody'] as Map)['token'], Redactor.placeholder);

    // Replay: the real server must not be called; responses come back in
    // recorded occurrence order, and the volatile nonce does not matter.
    final replay = FakeReplay(http);
    final replayServer = CountingServer();
    final replayDio = await dioWith(
      ReproDio(rules: [EndpointRule('POST', '/pay', ignoreBodyFields: {'nonce'})]),
      FakeSession(replay: replay),
      replayServer,
    );
    final first = await replayDio.get<Map<String, Object?>>('/items');
    final second = await replayDio.get<Map<String, Object?>>('/items');
    final pay = await replayDio.post<Map<String, Object?>>('/pay', data: {'amount': 5, 'nonce': 999});

    expect(first.data!['call'], 1);
    expect(second.data!['call'], 2);
    expect(pay.data!['call'], 3);
    expect(replayServer.calls, 0);
    expect(replay.served, 3);
    expect(replay.divergences, isEmpty);
  });

  test('strict replay fails unrecorded requests and reports a divergence', () async {
    final replay = FakeReplay(const []);
    final dio = await dioWith(ReproDio(), FakeSession(replay: replay), CountingServer());
    await expectLater(dio.get<Object?>('/unknown'), throwsA(isA<DioException>()));
    expect(replay.divergences.single, startsWith('network.unrecorded GET api.test/unknown'));
  });

  test('replays recorded transport errors', () async {
    const event = ReproEvent(seq: 1, t: 0, type: EventTypes.http, data: {
      'key': 'GET api.test/down',
      'occurrence': 0,
      'status': 0,
      'durationMs': 5,
      'bodyEncoding': 'omitted',
      'error': {'type': 'connectionTimeout', 'message': 'timed out'},
    });
    final replay = FakeReplay(const [event]);
    final dio = await dioWith(ReproDio(), FakeSession(replay: replay), CountingServer());
    await expectLater(
      dio.get<Object?>('/down'),
      throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.connectionTimeout)),
    );
  });
}
