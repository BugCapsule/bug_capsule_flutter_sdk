import 'dart:convert';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_native/bug_capsule_native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.bugcapsule/native_crash');
  const liveChannel = EventChannel('dev.bugcapsule/native_crash/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  String event(String id, {String level = 'fatal'}) =>
      jsonEncode({'eventId': id, 'level': level});

  late List<MethodCall> calls;
  late List<Object?> pending;

  setUp(() {
    calls = [];
    pending = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'start' => {'lastRunCrashed': true, 'handlerInstalled': true},
        'takePending' => pending,
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(liveChannel, null);
    NativeCrashReporter.instance = null;
  });

  const settings = NativeCrashSettings(
    release: 'com.shop@1+1',
    environment: 'production',
    inAppIncludes: ['com.shop'],
    appHangTimeout: Duration(seconds: 3),
  );

  test("registerWith makes it the hub's native crash reporter", () {
    BugCapsuleNative.registerWith();
    expect(NativeCrashReporter.instance, isA<BugCapsuleNative>());
    final first = NativeCrashReporter.instance;
    BugCapsuleNative.registerWith();
    expect(NativeCrashReporter.instance, same(first));
  });

  test(
    'start passes the settings and answers without earlier events',
    () async {
      final native = BugCapsuleNative();
      final started = await native.start(settings);
      expect(started.lastRunCrashed, isTrue);
      expect(started.handlerInstalled, isTrue);
      expect(calls.single.method, 'start');
      expect(calls.single.arguments, {
        'release': 'com.shop@1+1',
        'environment': 'production',
        'inAppIncludes': ['com.shop'],
        'appHangs': true,
        'appHangTimeoutMs': 3000,
      });
      await native.stop();
    },
  );

  test(
    'pending events are not taken before start, without a listener or after stop',
    () async {
      final native = BugCapsuleNative();
      pending = [event('a')];
      await native.collectPending(); // not started
      await native.start(settings);
      await native.collectPending(); // nobody listens
      expect(calls.where((c) => c.method == 'takePending'), isEmpty);

      final received = <NativeCrashEvent>[];
      final sub = native.events.listen(received.add);
      await native.collectPending();
      await pumpEventQueue();
      expect(received.map((e) => e.live), [false]);

      await native.stop();
      await native.collectPending();
      expect(calls.where((c) => c.method == 'takePending'), hasLength(1));
      await sub.cancel();
    },
  );

  test(
    'hangs arrive live; pending copies collected later are not repeated',
    () async {
      messenger.setMockStreamHandler(
        liveChannel,
        MockStreamHandler.inline(
          onListen: (args, sink) => sink.success(event('hang', level: 'error')),
        ),
      );
      final native = BugCapsuleNative();
      final received = <NativeCrashEvent>[];
      native.events.listen(received.add);
      await native.start(settings);
      await pumpEventQueue();
      expect(received.single.live, isTrue);

      // The native SDK keeps the hang pending too, and MetricKit adds a late crash.
      pending = [
        event('hang', level: 'error'),
        event('late'),
        event('late'),
        42,
      ];
      await native.collectPending();
      await pumpEventQueue();
      expect(received.map((e) => (jsonDecode(e.json) as Map)['eventId']), [
        'hang',
        'late',
      ]);
      expect(received.last.live, isFalse);
      await native.stop();
    },
  );

  test('updateScope sends the JSON and never throws', () async {
    final native = BugCapsuleNative();
    native.updateScope('{"tags":{}}');
    await pumpEventQueue();
    expect(calls.single.method, 'updateScope');
    expect(calls.single.arguments, '{"tags":{}}');
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'x'),
    );
    native.updateScope('{}');
    await pumpEventQueue();
  });
}
