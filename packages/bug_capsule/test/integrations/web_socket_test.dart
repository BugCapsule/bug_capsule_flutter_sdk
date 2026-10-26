import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A quote server: on `subscribe` it pushes two identical quotes at once,
/// a binary frame and a third quote 150 ms later, then closes with 4000.
Future<HttpServer> quoteServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (protocols) => protocols.first,
    );
    socket.listen((message) async {
      final m = jsonDecode(message as String) as Map;
      if (m['op'] == 'subscribe') {
        const quote = '{"symbol":"ACME","price":12.5}';
        socket
          ..add(quote)
          ..add(quote)
          ..add([1, 2, 3]);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        socket.add('{"symbol":"ACME","price":11.0}');
        await socket.close(4000, 'bye');
      }
    });
  });
  return server;
}

Future<List<Object?>> runScenario(BugCapsuleWebSocket sockets, Uri url) async {
  final channel = sockets.connect(url, protocols: ['quotes.v1']);
  await channel.ready;
  final received = <Object?>[];
  final done = Completer<void>();
  channel.stream.listen(
    (m) => received.add(m is String ? m : 'binary:${(m as List).length}'),
    onDone: done.complete,
  );
  channel.sink.add('{"op":"subscribe","symbol":"ACME"}');
  await done.future.timeout(const Duration(seconds: 5));
  return [
    ...received,
    channel.protocol,
    channel.closeCode,
    channel.closeReason,
  ];
}

void main() {
  late HttpServer server;
  late Uri url;

  setUp(() async {
    server = await quoteServer();
    url = Uri.parse(
      'ws://127.0.0.1:${server.port}/v1/stream?token=s3cr3t&ts=9',
    );
  });
  tearDown(() => server.close(force: true));

  Future<(InteractionHarness, List<Object?>)> capture({
    bool captureBinary = false,
  }) async {
    final h = InteractionHarness.capture();
    final sockets = BugCapsuleWebSocket(captureBinary: captureBinary);
    await h.setUp([sockets]);
    final seen = await runScenario(sockets, url);
    return (h, seen);
  }

  test('records the connection, frames and the server close', () async {
    final (h, seen) = await capture();
    expect(seen, [
      '{"symbol":"ACME","price":12.5}',
      '{"symbol":"ACME","price":12.5}',
      'binary:3',
      '{"symbol":"ACME","price":11.0}',
      'quotes.v1',
      4000,
      'bye',
    ]);
    final types = [for (final e in h.events) e.type];
    expect(types, [
      'ws.connect',
      'ws.open',
      'ws.send',
      'ws.message',
      'ws.message',
      'ws.message',
      'ws.message',
      'ws.close',
    ]);
    final connect = h.events.first.data;
    expect(connect['url'], isNot(contains('s3cr3t')));
    expect(connect['key'], startsWith('ws://127.0.0.1:'));
    expect(connect['key'], isNot(contains('ts=')));
    expect(connect['occurrence'], 0);
    final binary = h.events[5].data['payload'] as Map;
    expect(binary['mode'], 'metadata');
    expect(binary['replayable'], isFalse);
    expect(binary['bytes'], 3);
    expect(h.events.last.data, containsPair('initiator', 'server'));
    expect(h.events.last.data, containsPair('code', 4000));

    final [dep] = h.dependencies();
    expect(dep.adapter, 'bug_capsule.web_socket_channel');
    expect(dep.required, isTrue);
    expect(dep.coverage, DependencyCoverage.partial);
    expect(dep.gaps.single.code, DependencyGaps.payloadBinaryMetadata);
    expect(h.eligibility().status, EligibilityStatus.partial);
  });

  test('replays offline with the recorded order and timing', () async {
    final (h, seen) = await capture(captureBinary: true);
    await server.close(force: true);

    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final sockets = BugCapsuleWebSocket(captureBinary: true);
    await replay.setUp([sockets]);
    final sw = Stopwatch()..start();
    final replayed = await runScenario(sockets, url);
    expect(replayed, seen);
    // The last quote came ~150 ms after the subscribe when capturing.
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(120));
    expect(replay.finish(), isEmpty);
  });

  test('a metadata-only frame cannot be served', () async {
    final (h, _) = await capture();
    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final sockets = BugCapsuleWebSocket();
    await replay.setUp([sockets]);
    final replayed = await runScenario(sockets, url);
    expect(replayed, isNot(contains('binary:3')));
    expect([for (final d in replay.finish()) d.type], ['ws.noPayload']);
  });

  test('an unrecorded connection fails without touching the network', () async {
    final (h, _) = await capture();
    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final sockets = BugCapsuleWebSocket();
    await replay.setUp([sockets]);
    final other = sockets.connect(Uri.parse('wss://elsewhere.example.com/'));
    await expectLater(other.ready, throwsA(isA<Exception>()));
    final divergences = replay.finish();
    expect(divergences.first.type, 'ws.unrecorded');
    // The recorded connection was never made: its traffic is unused.
    expect(divergences.map((d) => d.type), contains('ws.unused'));
  });

  test('a different send is a mismatch', () async {
    final (h, _) = await capture(captureBinary: true);
    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final sockets = BugCapsuleWebSocket(captureBinary: true);
    await replay.setUp([sockets]);
    final channel = sockets.connect(url, protocols: ['quotes.v1']);
    await channel.ready;
    final done = channel.stream.drain<void>();
    channel.sink
      ..add('{"op":"subscribe","symbol":"OTHER"}')
      ..add('{"op":"extra"}');
    await done;
    expect(
      [for (final d in replay.finish()) d.type],
      ['ws.mismatch', 'ws.unrecorded'],
    );
  });

  test('concurrent identical connections keep their own traffic', () async {
    final h = InteractionHarness.capture();
    final sockets = BugCapsuleWebSocket(captureBinary: true);
    await h.setUp([sockets]);
    final both = await Future.wait([
      runScenario(sockets, url),
      runScenario(sockets, url),
    ]);
    final connects = [
      for (final e in h.events)
        if (e.type == 'ws.connect') e.data,
    ];
    expect([for (final c in connects) c['occurrence']], [0, 1]);
    expect(connects[0]['key'], connects[1]['key']);

    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final replaySockets = BugCapsuleWebSocket(captureBinary: true);
    await replay.setUp([replaySockets]);
    final replayed = await Future.wait([
      runScenario(replaySockets, url),
      runScenario(replaySockets, url),
    ]);
    expect(replayed, both);
    expect(replay.finish(), isEmpty);
  });

  test('dart:io sockets record and replay the same way', () async {
    Future<List<Object?>> io(BugCapsuleWebSocket sockets) async {
      final socket = await sockets.connectIo(
        url.toString(),
        protocols: ['quotes.v1'],
      );
      final received = <Object?>[];
      final done = Completer<void>();
      socket.listen(received.add, onDone: done.complete);
      socket.add('{"op":"subscribe","symbol":"ACME"}');
      await done.future.timeout(const Duration(seconds: 5));
      return [
        for (final r in received) r is String ? r : 'binary',
        socket.closeCode,
      ];
    }

    final h = InteractionHarness.capture();
    final sockets = BugCapsuleWebSocket(captureBinary: true);
    await h.setUp([sockets]);
    final seen = await io(sockets);
    expect(seen.last, 4000);
    await server.close(force: true);

    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final replaySockets = BugCapsuleWebSocket(captureBinary: true);
    await replay.setUp([replaySockets]);
    expect(await io(replaySockets), seen);
    expect(replay.finish(), isEmpty);
  });

  test('the remote kill switch stops capture for this adapter only', () async {
    final h = InteractionHarness.capture();
    h.interactions.disabledAdapters = {'bug_capsule.web_socket_channel'};
    final sockets = BugCapsuleWebSocket();
    await h.setUp([sockets]);
    await runScenario(sockets, url);
    expect(h.events, isEmpty);
    expect(h.dependencies(), isEmpty);
  });

  test('connections beyond the active limit are not captured', () async {
    final h = InteractionHarness.capture(
      limits: const InteractionLimits(maxActive: 1),
    );
    final sockets = BugCapsuleWebSocket();
    await h.setUp([sockets]);
    await Future.wait([runScenario(sockets, url), runScenario(sockets, url)]);
    expect(h.events.where((e) => e.type == 'ws.connect'), hasLength(1));
    expect(
      sockets.stats.gaps.map((g) => g.code),
      contains(DependencyGaps.connectionsLimit),
    );
  });

  test('a capsule without WebSocket traffic never connects for real', () async {
    final replay = InteractionHarness.replay(const [], dependencies: const []);
    final sockets = BugCapsuleWebSocket();
    await replay.setUp([sockets]);
    final channel = sockets.connect(url);
    await expectLater(channel.ready, throwsA(isA<Exception>()));
    expect([for (final d in replay.finish()) d.type], ['ws.unrecorded']);
  });

  test('failed and cancelled connections free their capture slot', () async {
    final h = InteractionHarness.capture(
      limits: const InteractionLimits(maxActive: 1),
    );
    final sockets = BugCapsuleWebSocket();
    await h.setUp([sockets]);
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = dead.port;
    await dead.close();
    final failed = sockets.connect(Uri.parse('ws://127.0.0.1:$deadPort/'));
    await expectLater(failed.ready, throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final channel = sockets.connect(url);
    await channel.ready;
    final sub = channel.stream.listen((_) {});
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sockets.openInteractions(), isEmpty);

    await runScenario(sockets, url);
    expect(h.events.where((e) => e.type == 'ws.connect'), hasLength(3));
    expect(
      h.events.where(
        (e) => e.type == 'ws.close' && e.data['cancelled'] == true,
      ),
      hasLength(1),
    );
    expect(
      sockets.stats.gaps.map((g) => g.code),
      isNot(contains('connections.limit')),
    );
  });

  test('closing early in replay stops deliveries and reports them', () async {
    final (h, _) = await capture(captureBinary: true);
    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final sockets = BugCapsuleWebSocket(captureBinary: true);
    await replay.setUp([sockets]);
    final channel = sockets.connect(url, protocols: ['quotes.v1']);
    await channel.ready;
    final received = <Object?>[];
    channel.stream.listen(received.add);
    await channel.sink.close(1000);
    await channel.sink.done.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(received, isEmpty);
    expect(replay.finish().map((d) => d.type), contains('ws.unused'));
  });
}
