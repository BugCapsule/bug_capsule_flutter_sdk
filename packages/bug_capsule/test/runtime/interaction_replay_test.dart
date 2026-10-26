import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/actions.dart';
import 'package:bug_capsule/src/runtime/replay_engine.dart';
import 'package:bug_capsule/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// The planted bug: after a reconnect the server replays the last quote,
/// and the buggy book treats the duplicate as going back in time.
class QuoteBook {
  QuoteBook({required this.fixed});

  final bool fixed;
  int lastSeq = 0;

  void onQuote(Object? message) {
    final seq = (jsonDecode(message! as String) as Map)['seq'] as int;
    if (seq <= lastSeq) {
      if (fixed) return;
      throw StateError('Quote went stale ($seq after $lastSeq)');
    }
    lastSeq = seq;
  }
}

Future<HttpServer> quoteServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var connection = 0;
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    // Reading the socket lets the server answer the client's close frame.
    socket.listen((_) {});
    final n = connection++;
    if (n == 0) {
      socket.add('{"seq":1}');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      socket.add('{"seq":2}');
      await socket.close(4001, 'restart');
    } else {
      // The race: the replayed quote arrives together with the next one.
      socket
        ..add('{"seq":2}')
        ..add('{"seq":3}');
    }
  });
  return server;
}

/// The app: connects, reconnects once when the server restarts.
Future<void> runApp(
  BugCapsuleWebSocket sockets,
  Uri url,
  QuoteBook book,
  void Function(Object error, StackTrace st) onError,
) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    final channel = sockets.connect(url);
    await channel.ready;
    final done = Completer<void>();
    channel.stream.listen((m) {
      try {
        book.onQuote(m);
      } catch (e, st) {
        onError(e, st);
      }
    }, onDone: done.complete);
    if (attempt == 0) {
      await done.future;
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await channel.sink.close(1000);
    }
  }
}

/// A replay session backed by a real [ReplayEngine].
class EngineSession implements InteractionSession {
  EngineSession(this.engine);

  final ReplayEngine engine;
  final Stopwatch _clock = Stopwatch()..start();

  @override
  final InteractionHost interactions = InteractionHost();
  @override
  final Redactor redactor = Redactor();
  @override
  BugCapsuleConfig get config => const BugCapsuleConfig();
  @override
  CaptureMode get mode => CaptureMode.qa;
  @override
  bool get isRecording => false;
  @override
  bool get isReplaying => true;
  @override
  bool get captureNetworkBodies => true;
  @override
  int get maxBodyBytes => 256 * 1024;
  @override
  int now() => _clock.elapsedMilliseconds;
  @override
  void record(String type, [Map<String, Object?> data = const {}]) {}
  @override
  ReplayContext? get replay => engine;
  @override
  void reportError(Object error, StackTrace? stack) {}
}

Capsule capsuleFrom(InteractionHarness h, FailureRecord failure) {
  final events = h.encodedEvents();
  return Capsule(
    manifest: CapsuleManifest(
      capsuleId: uuidV4(),
      createdAt: DateTime.now(),
      mode: CaptureMode.qa,
      app: const AppInfo(version: '1.0.0', build: '1'),
      sdkName: 'bug_capsule_flutter',
      sdkVersion: '0.5.0',
      stateSchemaVersion: 1,
      platform: const PlatformInfo(
        os: 'android',
        osVersion: '16',
        locale: 'en',
        screenWidth: 400,
        screenHeight: 800,
        pixelRatio: 2,
        dartVersion: '3.11.0',
      ),
      session: SessionInfo(
        id: 's',
        startedAt: DateTime.now(),
        wallClockAtAnchorMs: 0,
        seed: 1,
        durationMs: 1000,
      ),
      failure: failure,
      eligibility: const Eligibility(EligibilityStatus.eligible, []),
      integrations: const ['web_socket'],
      eventCount: events.length,
      droppedEvents: 0,
      checkpointKind: CheckpointKind.launch,
      dependencies: h.dependencies(),
    ),
    checkpoint: const Checkpoint(
      kind: CheckpointKind.launch,
      t: 0,
      wallClockMs: 0,
      afterSeq: 0,
    ),
    events: events,
  );
}

void main() {
  late Capsule capsule;
  late Uri url;

  setUpAll(() async {
    final server = await quoteServer();
    url = Uri.parse('ws://127.0.0.1:${server.port}/quotes');
    final h = InteractionHarness.capture();
    final sockets = BugCapsuleWebSocket();
    await h.setUp([sockets]);
    FailureRecord? failure;
    await runApp(sockets, url, QuoteBook(fixed: false), (e, st) {
      failure ??= FailureRecord.exception(e, st, h.now());
    });
    await server.close(force: true);
    expect(failure, isNotNull, reason: 'the bug fires while capturing');
    // Through the codec, as upload and download would: a valid v2 capsule.
    capsule = CapsuleCodec.decode(
      CapsuleCodec.encode(capsuleFrom(h, failure!)),
    );
  });

  Future<ReplayReport> replay(
    WidgetTester tester, {
    required bool fixed,
    bool connect = true,
    bool installAdapter = true,
  }) async {
    // The engine is created inside runAsync: completers made in the test's
    // fake-async zone would only complete when fake time is pumped.
    final report = await tester.runAsync(() async {
      final engine = ReplayEngine(
        capsule: capsule,
        settings: const ReplaySettings(settleTimeoutMs: 400),
        actions: ActionRegistry(),
        buildGitSha: null,
      );
      final sockets = BugCapsuleWebSocket();
      final blocked = engine.preflight(installAdapter ? [sockets] : const []);
      if (blocked != null) {
        return ReplayReport(
          outcome: ReplayOutcome.incompatible,
          attempt: 1,
          durationMs: 0,
          strategy: ReplayStrategy.auto,
          expectedSignature: capsule.manifest.failure?.signature,
          message: blocked,
        );
      }
      final session = EngineSession(engine);
      session.interactions.replay = engine.interactions;
      await sockets.setUp(session);
      final book = QuoteBook(fixed: fixed);
      if (connect) {
        unawaited(
          runApp(sockets, url, book, (e, st) {
            engine.onFailure(FailureRecord.exception(e, st, 0));
          }),
        );
      }
      return engine.run();
    });
    return report!;
  }

  test('the capsule is spec v2 with a required WebSocket dependency', () {
    expect(CapsuleCodec.toJson(capsule)['specVersion'], 2);
    final dep = capsule.manifest.dependencies.single;
    expect(dep.adapter, 'bug_capsule.web_socket_channel');
    expect(dep.required, isTrue);
    expect(capsule.events.where((e) => e.type == 'ws.connect'), hasLength(2));
  });

  testWidgets('offline replay reproduces the race on the buggy code', (
    tester,
  ) async {
    final report = await replay(tester, fixed: false);
    expect(
      report.outcome,
      ReplayOutcome.reproduced,
      reason: '${report.toJson()}',
    );
    final run = evaluateRun(RunKind.replay, 1, [report]);
    expect(run.verdict, Verdict.reproduced);
  });

  testWidgets('the same capsule verifies the fix', (tester) async {
    final report = await replay(tester, fixed: true);
    expect(report.outcome, ReplayOutcome.notReproduced);
    final material = report.divergences.where(DivergencePolicy.isMaterial);
    expect(material, isEmpty, reason: '${report.divergences}');
    final run = evaluateRun(RunKind.verify, 1, [report]);
    expect(run.verdict, Verdict.fixed);
  });

  testWidgets('a fix that skips the connection is not reported as fixed', (
    tester,
  ) async {
    final report = await replay(tester, fixed: true, connect: false);
    expect(report.outcome, ReplayOutcome.notReproduced);
    final run = evaluateRun(RunKind.verify, 1, [report]);
    expect(run.verdict, Verdict.inconclusive);
    expect(run.reasonCodes, contains('interaction.missing'));
  });

  testWidgets('a build without the adapter fails preflight', (tester) async {
    final report = await replay(tester, fixed: true, installAdapter: false);
    final run = evaluateRun(RunKind.verify, 1, [report]);
    expect(run.verdict, Verdict.incompatible);
    expect(run.reasonCodes, ['dependency.unsupported']);
  });
}
