import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:repro_flutter/repro_flutter.dart';
import 'package:repro_go_router/repro_go_router.dart';

class FakeSession implements ReproSession {
  FakeSession({this.replay});

  final List<ReproEvent> events = [];
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
  int get maxBodyBytes => 1024;
  @override
  int now() => events.length;
  @override
  void record(String type, [Map<String, Object?> data = const {}]) =>
      events.add(ReproEvent(seq: events.length + 1, t: now(), type: type, data: data));
  @override
  void reportError(Object error, StackTrace? stack) {}
}

class FakeReplay implements ReplayContext {
  final List<String> divergences = [];
  @override
  void diverge(String type, String detail) => divergences.add(type);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

GoRouter routerFor(String initial) => GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('home')),
        GoRoute(path: '/reset/:code', builder: (_, _) => const Text('reset')),
        GoRoute(path: '/cart', builder: (_, _) => const Text('cart')),
      ],
    );

void main() {
  testWidgets('events and checkpoints redact the same sensitive parameters', (tester) async {
    final session = FakeSession();
    final repro = ReproGoRouter();
    await repro.setUp(session);
    final router = routerFor('/');
    repro.attach(router);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    router.go('/cart?access_token=synthRouteToken1&ref=email#id_token=synthFragment2');
    await tester.pumpAndSettle();

    final event = session.events.where((e) => e.type == EventTypes.route).last.data['location'] as String;
    final snapshot = repro.snapshot(CheckpointKind.periodic)! as Map;
    for (final recorded in [event, snapshot['location'] as String, jsonEncode(snapshot)]) {
      expect(recorded, isNot(contains('synthRouteToken1')));
      expect(recorded, isNot(contains('synthFragment2')));
      expect(recorded, contains('ref=email'));
    }
    expect(snapshot['location'], event, reason: 'one redaction path for both');
  });

  testWidgets('sanitizeLocation covers secrets in path segments', (tester) async {
    final session = FakeSession();
    final repro = ReproGoRouter(
        sanitizeLocation: (l) => l.replaceAll(RegExp(r'/reset/[^/?#]+'), '/reset/:code'));
    await repro.setUp(session);
    final router = routerFor('/');
    repro.attach(router);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/reset/synthPathSecret3');
    await tester.pumpAndSettle();
    expect(jsonEncode(session.events.map((e) => e.data).toList()), isNot(contains('synthPathSecret3')));
    expect(jsonEncode(repro.snapshot(CheckpointKind.periodic)), isNot(contains('synthPathSecret3')));
  });

  test('restoring a redacted location is reported', () async {
    final replay = FakeReplay();
    final repro = ReproGoRouter();
    await repro.restore({'location': '/cart?access_token=%5BREDACTED%5D', 'hasExtra': false},
        FakeSession(replay: replay));
    expect(repro.initialLocation('/'), startsWith('/cart'));
    expect(replay.divergences, ['route.redacted']);
  });
}
