import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/monitoring/hub.dart';

class NotRecordingSession implements BugCapsuleSession {
  @override
  BugCapsuleConfig get config => const BugCapsuleConfig(appVersion: '1', appBuild: '1');
  @override
  CaptureMode get mode => CaptureMode.production;
  @override
  bool get isRecording => false;
  @override
  bool get isReplaying => false;
  @override
  ReplayContext? get replay => null;
  @override
  final Redactor redactor = Redactor();
  @override
  bool get captureNetworkBodies => true;
  @override
  int get maxBodyBytes => 1024;
  @override
  int now() => 0;
  @override
  void record(String type, [Map<String, Object?> data = const {}]) {}
  @override
  void reportError(Object error, StackTrace? stack) {}
}

/// A hub without storage or backend; transactions are observed through
/// `beforeSendTransaction`.
MonitoringHub hubFor(List<Map<String, Object?>> transactions, {bool interactions = false}) => MonitoringHub(
      options: MonitoringOptions(
        tracesSampleRate: 1,
        captureIsolateErrors: false,
        enableAppStartTracking: false,
        enableUserInteractionTracing: interactions,
        beforeSendTransaction: (t) {
          transactions.add(t);
          return t;
        },
      ),
      host: MonitoringHost(
        config: const BugCapsuleConfig(appVersion: '1', appBuild: '1', mode: CaptureMode.production),
        redactor: Redactor.new,
        remote: () => null,
        uploadsAllowed: () => false,
        ensureFreshConfig: () async {},
        refreshConfig: () async {},
        writeCapsule: (_, _) async => null,
        isRecording: () => false,
      ),
      sdkVersion: 'test',
      startedAt: DateTime.now(),
    );

void main() {
  tearDown(Scope.root.clear);

  testWidgets('navigator observer: screen transactions with frames and initial display', (tester) async {
    final txs = <Map<String, Object?>>[];
    final hub = hubFor(txs);
    await hub.start();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      navigatorObservers: [BugCapsuleNavigatorObserver()],
      initialRoute: '/',
      onGenerateRoute: (s) => MaterialPageRoute<void>(settings: s, builder: (_) => Text('${s.name}')),
    ));
    expect(Scope.root.transaction!.name, '/');

    unawaited(nav.currentState!.pushNamed('/product/42'));
    await tester.pumpAndSettle();
    final screen = Scope.root.transaction!;
    expect(screen.name, '/product/:id');
    expect(screen.op, 'navigation');

    unawaited(showDialog<void>(context: nav.currentContext!, builder: (_) => const Text('dialog')));
    await tester.pumpAndSettle();
    expect(Scope.root.transaction, same(screen), reason: 'dialogs are not screens');
    nav.currentState!.pop();
    await tester.pumpAndSettle();

    hub.onFrameDurations(const [Duration(milliseconds: 10), Duration(milliseconds: 40), Duration(milliseconds: 900)]);
    await tester.pump(const Duration(seconds: 4)); // idle timeout

    expect([for (final t in txs) t['name']], ['/', '/product/:id']);
    final product = txs.last;
    final m = product['measurements']! as Map;
    expect((m['frames_total'] as Map)['value'], 3);
    expect((m['frames_slow'] as Map)['value'], 1);
    expect((m['frames_frozen'] as Map)['value'], 1);
    expect(m['time_to_initial_display'], isNotNull);
    expect([for (final s in product['spans']! as List) (s as Map)['op']], contains('ui.load.initial_display'));

    final crumbs = hub.prepareException(StateError('x'), null, mechanism: Mechanism.manual)!.event.breadcrumbs;
    final nav2 = crumbs.where((c) => c.type == 'navigation').toList();
    expect(nav2.last.data, {'from': '/', 'to': '/product/42'});
    await hub.dispose();
  });

  testWidgets('GoRouter: transactions use the route pattern; breadcrumbs are redacted', (tester) async {
    final txs = <Map<String, Object?>>[];
    final hub = hubFor(txs);
    await hub.start();
    final integration = BugCapsuleGoRouter();
    await integration.setUp(NotRecordingSession());
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Text('home')),
      GoRoute(path: '/product/:id', builder: (_, _) => const Text('product')),
    ]);
    integration.attach(router);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/product/42?token=synthQueryToken002');
    await tester.pumpAndSettle();
    expect(Scope.root.transaction!.name, '/product/:id');
    final crumbs = hub.prepareException(StateError('x'), null, mechanism: Mechanism.manual)!.event.breadcrumbs;
    final to = crumbs.lastWhere((c) => c.type == 'navigation').data!['to'] as String;
    expect(to, startsWith('/product/42?token='));
    expect(to, isNot(contains('synthQueryToken002')));
    await hub.dispose();
  });

  testWidgets('user interaction tracing starts a ui.action.click transaction when idle', (tester) async {
    final txs = <Map<String, Object?>>[];
    final hub = hubFor(txs, interactions: true);
    await hub.start();
    hub.onUserAction('cart.checkout');
    final tx = Scope.root.transaction!;
    expect(tx.op, 'ui.action.click');
    tx.startChild('http.client').finish();
    await tester.pump(const Duration(seconds: 4));
    expect(txs.single['name'], 'cart.checkout');
    await hub.dispose();
  });

  testWidgets('feedback form validates and submits', (tester) async {
    String? submitted = 'not called';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: BugCapsuleFeedbackForm(onSubmitted: (id) => submitted = id)),
    ));
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(find.text('Please describe the problem.'), findsOneWidget);
    expect(submitted, 'not called');

    await tester.enterText(find.byKey(const ValueKey('bugcapsule.feedback.message')), 'It crashed');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(submitted, isNull, reason: 'BugCapsule is not initialized in this test');
  });

  testWidgets('showBugCapsuleFeedback opens a sheet that can be cancelled', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    final result = showBugCapsuleFeedback(ctx);
    await tester.pumpAndSettle();
    expect(find.text('Report a problem'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.text('Report a problem'), findsNothing);
  });

  test('shake detector: two strong peaks within the window, then a cooldown', () {
    final d = ShakeDetector();
    final t0 = DateTime(2026);
    expect(d.add(0, 9.8, 0, t0), isFalse, reason: 'gravity only');
    expect(d.add(30, 0, 0, t0), isFalse);
    expect(d.add(-30, 0, 0, t0.add(const Duration(milliseconds: 200))), isTrue);
    expect(d.add(30, 0, 0, t0.add(const Duration(milliseconds: 400))), isFalse, reason: 'cooldown');
    expect(d.add(30, 0, 0, t0.add(const Duration(seconds: 3))), isFalse);
    expect(d.add(30, 0, 0, t0.add(const Duration(seconds: 4))), isFalse, reason: 'outside the window');
    expect(d.add(30, 0, 0, t0.add(const Duration(milliseconds: 4200))), isTrue);
  });
}


