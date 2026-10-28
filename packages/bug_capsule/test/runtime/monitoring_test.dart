import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/monitoring/hub.dart' show MonitoringHub;
import 'package:bug_capsule/src/version.dart';

/// Backend fake for capsules, remote config and envelopes (monitoring-v1).
class FakeBackend implements BugCapsuleTransport, EnvelopeTransport {
  bool monitoringEnabled = true;
  double errorSampleRate = 1;
  double? tracesSampleRate;
  List<String>? propagationTargets;
  final List<List<int>> capsules = [];
  final List<Map<String, Object?>> envelopes = [];

  @override
  Future<ConfigFetchResult> fetchConfig() async => ConfigFetched(
    RemoteCaptureConfig(
      enabled: true,
      sampleRate: 1,
      maxCapsuleBytes: 5 * 1024 * 1024,
      captureNetworkBodies: true,
      redactKeys: const [],
      configTtlSeconds: 300,
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      monitoringEnabled: monitoringEnabled,
      errorSampleRate: errorSampleRate,
      tracesSampleRate: tracesSampleRate,
      tracePropagationTargets: propagationTargets,
    ),
  );

  @override
  Future<UploadResult> upload(List<int> bytes) async {
    capsules.add(bytes);
    return const UploadResult(UploadStatus.uploaded);
  }

  @override
  Future<UploadResult> sendEnvelope(List<int> gzippedBody) async {
    envelopes.add(EnvelopeCodec.decode(gzippedBody));
    return const UploadResult(UploadStatus.uploaded);
  }

  @override
  void close() {}

  List<Map<String, Object?>> items(String type) => [
    for (final e in envelopes)
      for (final i in (e['items']! as List).cast<Map<String, Object?>>())
        if (i['type'] == type) (i['payload']! as Map).cast<String, Object?>(),
  ];
}

/// Answers every request and remembers the headers it was sent.
class EchoServer implements HttpClientAdapter {
  final List<Map<String, Object?>> headers = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    headers.add(Map.of(options.headers));
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Stands in for `bug_capsule_native`.
class FakeNativeReporter implements NativeCrashReporter {
  FakeNativeReporter({this.lastRunCrashed = false, this.previous = const []});

  final bool lastRunCrashed;
  List<String> previous;
  final List<String> scopes = [];
  final StreamController<NativeCrashEvent> live =
      StreamController<NativeCrashEvent>.broadcast();
  NativeCrashSettings? settings;
  int stops = 0;

  @override
  Future<NativeCrashStart> start(NativeCrashSettings settings) async {
    this.settings = settings;
    return NativeCrashStart(
      lastRunCrashed: lastRunCrashed,
      handlerInstalled: true,
    );
  }

  @override
  Future<void> collectPending() async {
    if (!live.hasListener) return;
    final taken = previous;
    previous = const [];
    for (final json in taken) {
      live.add(NativeCrashEvent(json, live: false));
    }
  }

  @override
  Future<void> stop() async => stops++;

  @override
  void updateScope(String scopeJson) => scopes.add(scopeJson);

  @override
  Stream<NativeCrashEvent> get events => live.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeBackend backend;
  final originalDebugPrint = debugPrint;
  final originalOnError = FlutterError.onError;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bugcapsule-monitoring-');
    backend = FakeBackend();
    debugPrint = (String? message, {int? wrapWidth}) {};
    FlutterError.onError = (_) {};
  });

  tearDown(() async {
    NativeCrashReporter.instance = null;
    await BugCapsule.resetForTest();
    BugCapsule.debugOverrides = null;
    debugPrint = originalDebugPrint;
    FlutterError.onError = originalOnError;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> start({
    CaptureMode mode = CaptureMode.qa,
    MonitoringOptions monitoring = const MonitoringOptions(),
    List<BugCapsuleIntegration> integrations = const [],
    bool autoCapture = false,
    double productionSampleRate = 1,
  }) async {
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(
      storageDirectory: dir,
      transport: backend,
    );
    await BugCapsule.init(
      config: BugCapsuleConfig(
        appId: 'com.shop.app',
        appVersion: '1.0.0',
        appBuild: '1',
        mode: mode,
        gitSha: 'abc123',
        autoCaptureOnFailure: autoCapture,
        productionSampleRate: productionSampleRate,
        backend: const BugCapsuleBackendConfig(
          url: 'https://bugcapsule.test',
          ingestKey: 'bci_test',
        ),
        monitoring: monitoring,
      ),
      integrations: integrations,
      appRunner: () {},
    );
    // Startup config fetch.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<void> flush() async {
    expect(await BugCapsule.flush(), isTrue);
  }

  String raw() => jsonEncode(backend.envelopes);

  test(
    'build fallback is installed, reports once, and restores on reset',
    () async {
      final previous = ErrorWidget.builder;
      await start();
      expect(ErrorWidget.builder, isNot(same(previous)));
      final details = FlutterErrorDetails(
        exception: StateError('private-build-detail'),
        stack: StackTrace.current,
        library: 'widgets library',
      );
      FlutterError.reportError(details);
      final fallback = ErrorWidget.builder(details);
      expect(fallback, isNot(isA<ErrorWidget>()));
      await flush();
      final events = backend.items('event');
      expect(events, hasLength(1));
      expect(jsonEncode(events.single), contains('private-build-detail'));
      await BugCapsule.resetForTest();
      expect(ErrorWidget.builder, same(previous));
    },
  );

  test('reset preserves a subsequently installed app fallback', () async {
    final previous = ErrorWidget.builder;
    await start();
    Widget custom(FlutterErrorDetails _) => const SizedBox();
    ErrorWidget.builder = custom;
    await BugCapsule.resetForTest();
    expect(ErrorWidget.builder, same(custom));
    ErrorWidget.builder = previous;
  });

  group('error events', () {
    test(
      'captureException sends a contract-shaped event with a session update',
      () async {
        await start();
        BugCapsule.setUser(const MonitoringUser(id: 'u_1', segment: 'pro'));
        BugCapsule.setTag('screen', 'cart');
        final id = BugCapsule.captureException(
          StateError('cart is empty'),
          extra: {'items': 0},
        );
        expect(id, isNotNull);
        expect(BugCapsule.lastEventId(), id);
        await flush();

        expect(backend.envelopes.first['sdk'], {
          'name': 'bugcapsule-flutter',
          'version': bugCapsuleVersion,
        });
        final event = backend.items('event').single;
        expect(event['eventId'], id);
        expect(event['runtime'], 'flutter');
        expect(event['release'], 'com.shop.app@1.0.0+1');
        expect(event['environment'], 'qa');
        expect(event['level'], 'error');
        expect(event['tags'], {'screen': 'cart'});
        expect(event['user'], {'id': 'u_1', 'segment': 'pro'});
        expect(event['extra'], {'items': 0});
        final ex =
            ((event['exception']! as Map)['values'] as List).single as Map;
        expect(ex['type'], 'StateError');
        expect(ex['value'], 'Bad state: cart is empty');
        expect(ex['mechanism'], {'type': 'manual', 'handled': true});
        final frames = (ex['stacktrace'] as Map)['frames'] as List;
        expect(frames, isNotEmpty);
        final contexts = event['contexts']! as Map;
        expect((contexts['app'] as Map)['appVersion'], '1.0.0');
        expect(contexts['os'], isNotNull);

        final sessions = backend.items('session');
        expect(sessions.first['init'], isTrue);
        expect(sessions.first['status'], 'ok');
        expect(
          sessions.first['did'],
          File('${dir.path}/install_id').readAsStringSync(),
          reason: 'no user yet',
        );
        expect(sessions.last['did'], 'u_1');
        expect(sessions.last['sid'], sessions.first['sid']);
        expect(sessions.last['errors'], 1);
        expect(sessions.last['seq'], 2);
      },
    );

    test(
      'every string is redacted before it is queued; ids are kept',
      () async {
        await start();
        BugCapsule.setTag('token', 'synthTagToken001');
        BugCapsule.setExtra('password', 'hunter2-synthetic');
        BugCapsule.log('retrying with token=synthLogToken006');
        BugCapsule.addBreadcrumb(
          Breadcrumb(message: 'Authorization: Bearer synthCrumbBearer0123456'),
        );
        final id = BugCapsule.captureException(
          Exception('failed: Bearer synthBearer0123456789'),
        )!;
        await flush();
        for (final secret in [
          'synthTagToken001',
          'hunter2-synthetic',
          'synthLogToken006',
          'synthCrumbBearer0123456',
          'synthBearer0123456789',
        ]) {
          expect(raw(), isNot(contains(secret)));
        }
        final event = backend.items('event').single;
        expect(event['eventId'], id);
        final crumbs = (event['breadcrumbs']! as List)
            .cast<Map<String, Object?>>();
        expect(
          crumbs.any(
            (c) =>
                c['category'] == 'log' &&
                '${c['message']}'.contains('[REDACTED]'),
          ),
          isTrue,
        );
      },
    );

    test(
      'an uncaught Flutter error is fatal, crashes the session and links the capsule both ways',
      () async {
        await start(autoCapture: true);
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: StateError('total is negative'),
            stack: StackTrace.current,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        await flush();

        final event = backend.items('event').single;
        expect(event['level'], 'fatal');
        final ex =
            ((event['exception']! as Map)['values'] as List).single as Map;
        expect((ex['mechanism'] as Map)['type'], 'flutter_error');
        expect((ex['mechanism'] as Map)['handled'], isFalse);
        expect(event['capsuleId'], isNotNull);

        final capsule = CapsuleCodec.decode(backend.capsules.single);
        expect(capsule.manifest.capsuleId, event['capsuleId']);
        expect(capsule.manifest.monitoring!.eventId, event['eventId']);
        expect(capsule.manifest.monitoring!.release, 'com.shop.app@1.0.0+1');
        expect(capsule.manifest.monitoring!.environment, 'qa');
        expect(backend.items('session').last['status'], 'crashed');
      },
    );

    test(
      'a zone error through runZonedGuarded is sent once as uncaught',
      () async {
        await start();
        final seen = Completer<Object>();
        BugCapsule.runZonedGuarded(
          () => unawaited(Future<void>(() => throw StateError('zone boom'))),
          onError: (e, _) => seen.complete(e),
        );
        await seen.future;
        await flush();
        final event = backend.items('event').single;
        final ex =
            ((event['exception']! as Map)['values'] as List).single as Map;
        expect(ex['mechanism'], {'type': 'uncaught', 'handled': false});
        expect(event['level'], 'fatal');
      },
    );

    test(
      'errorSampleRate drops non-fatal events; fatal ones are always sent',
      () async {
        await start(monitoring: const MonitoringOptions(errorSampleRate: 0));
        expect(BugCapsule.captureException(StateError('sampled out')), isNull);
        expect(
          BugCapsule.captureException(
            StateError('fatal'),
            level: EventLevel.fatal,
          ),
          isNotNull,
        );
        await flush();
        expect([for (final e in backend.items('event')) e['level']], ['fatal']);
      },
    );

    test(
      'one error repeating (e.g. every frame) is sent at most 10 times a minute',
      () async {
        await start();
        for (var i = 0; i < 15; i++) {
          BugCapsule.captureException(
            StateError('layout overflow'),
            stackTrace: StackTrace.empty,
          );
        }
        BugCapsule.captureException(
          StateError('another error'),
          stackTrace: StackTrace.empty,
        );
        await flush();
        final values = [
          for (final e in backend.items('event'))
            (((e['exception']! as Map)['values'] as List).single
                as Map)['value'],
        ];
        expect(
          values.where((v) => v == 'Bad state: layout overflow'),
          hasLength(10),
        );
        expect(values, contains('Bad state: another error'));
      },
    );

    test('beforeSend can edit or drop events', () async {
      await start(
        monitoring: MonitoringOptions(
          beforeSend: (event, hint) {
            if (hint.error is ArgumentError) return null;
            return event..tags['edited'] = 'yes';
          },
        ),
      );
      BugCapsule.captureException(ArgumentError('dropped'));
      BugCapsule.captureException(StateError('kept'));
      await flush();
      final events = backend.items('event');
      expect(events.length, 1);
      expect((events.single['tags']! as Map)['edited'], 'yes');
    });

    test('captureMessage, withScope and fingerprints', () async {
      await start();
      BugCapsule.withScope((scope) {
        scope.setTag('flow', 'checkout');
        scope.setFingerprint(['checkout-timeout']);
        BugCapsule.captureMessage('checkout slow', level: EventLevel.warning);
      });
      BugCapsule.captureMessage('outside');
      await flush();
      final events = backend.items('event');
      expect(events[0]['message'], {'formatted': 'checkout slow'});
      expect(events[0]['level'], 'warning');
      expect(events[0]['tags'], {'flow': 'checkout'});
      expect(events[0]['fingerprint'], ['checkout-timeout']);
      expect(events[0]['threads'], isNotNull, reason: 'attachStacktrace');
      expect(events[1]['tags'], isEmpty);
      expect(events[1]['fingerprint'], isNull);
    });

    test(
      'remote monitoringEnabled: false sends nothing; capsules are unaffected',
      () async {
        backend.monitoringEnabled = false;
        await start();
        BugCapsule.captureException(StateError('x'));
        await BugCapsule.flush();
        expect(backend.envelopes, isEmpty);
        expect(await BugCapsule.capture(), isNotNull);
        expect(backend.capsules, hasLength(1));
      },
    );

    test('MonitoringOptions.disabled turns monitoring off', () async {
      await start(monitoring: MonitoringOptions.disabled);
      expect(BugCapsule.captureException(StateError('x')), isNull);
      expect(await BugCapsule.flush(), isTrue);
      expect(backend.envelopes, isEmpty);
    });
  });

  group('sessions', () {
    void lifecycle(AppLifecycleState state) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'flutter/lifecycle',
            const StringCodec().encodeMessage(state.toString()),
            (_) {},
          );
    }

    test(
      'a new session starts after the background timeout; the old one exits',
      () async {
        await start(
          monitoring: const MonitoringOptions(
            sessionBackgroundTimeout: Duration.zero,
          ),
        );
        lifecycle(AppLifecycleState.paused);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        lifecycle(AppLifecycleState.resumed);
        await flush();
        final sessions = backend.items('session');
        expect([for (final s in sessions) s['status']], ['ok', 'exited', 'ok']);
        expect(sessions[1]['sid'], sessions[0]['sid']);
        expect(sessions[2]['sid'], isNot(sessions[0]['sid']));
        expect(sessions[2]['init'], isTrue);
      },
    );

    test(
      'a session left open in the foreground is reported abnormal on the next launch',
      () async {
        File('${dir.path}/session.json').writeAsStringSync(
          jsonEncode({
            'sid': '11111111-1111-4111-8111-111111111111',
            'did': 'install',
            'seq': 1,
            'started': '2026-10-21T13:58:00.000Z',
            'errors': 0,
            'status': 'ok',
            'foreground': true,
            'lastUpdate': '2026-10-21T14:00:00.000Z',
          }),
        );
        await start();
        await flush();
        final previous = backend
            .items('session')
            .firstWhere(
              (s) => s['sid'] == '11111111-1111-4111-8111-111111111111',
            );
        expect(previous['status'], 'abnormal');
        expect(previous['seq'], 2);
        expect(previous['init'], isFalse);
        expect(previous['timestamp'], '2026-10-21T14:00:00.000Z');
      },
    );
  });

  group('native crashes', () {
    String nativeCrash({
      String release = 'com.shop.app@0.9.0+8',
      String timestamp = '2026-10-21T14:00:05.000Z',
      Map<String, Object?> contexts = const {},
    }) => jsonEncode({
      'eventId': '22222222-2222-4222-8222-222222222222',
      'timestamp': timestamp,
      'level': 'fatal',
      'runtime': 'android',
      'release': release,
      'environment': 'qa',
      'exception': {
        'values': [
          {
            'type': 'SIGSEGV',
            'value': 'Segmentation violation (code 1) at 0x0',
            'mechanism': {'type': 'signal', 'handled': false},
            'stacktrace': {
              'frames': [
                {
                  'instructionAddr': '0x7a00002000',
                  'imageAddr': '0x7a00000000',
                  'package': '/data/app/x/lib/arm64/libflutter.so',
                  'inApp': true,
                },
                {
                  'instructionAddr': '0x7b00001000',
                  'imageAddr': '0x7b00000000',
                  'package': '/data/app/x/lib/arm64/libcamera_plugin.so',
                  'function': 'take_picture',
                  'inApp': true,
                },
              ],
            },
          },
        ],
      },
      'user': {'id': 'u_crashed'},
      'tags': {'screen': 'camera'},
      'contexts': {
        'app': {'appVersion': '0.9.0'},
        ...contexts,
      },
      'breadcrumbs': [
        {
          'timestamp': '2026-10-21T14:00:04.000Z',
          'type': 'navigation',
          'message': '/camera',
          'level': 'info',
        },
      ],
      'threads': [
        {'id': 1, 'name': 'main', 'crashed': true, 'current': true},
      ],
      'debugImages': [
        {
          'type': 'elf',
          'codeFile': 'libcamera_plugin.so',
          'debugId': 'abc',
          'imageAddr': '0x7b00000000',
        },
      ],
    });

    test(
      'a native crash of the last run crashes its session and is sent through beforeSend',
      () async {
        File('${dir.path}/session.json').writeAsStringSync(
          jsonEncode({
            'sid': '11111111-1111-4111-8111-111111111111',
            'did': 'install',
            'seq': 1,
            'release': 'com.shop.app@0.9.0+8',
            'environment': 'qa',
            'started': '2026-10-21T13:58:00.000Z',
            'errors': 0,
            'status': 'ok',
            'foreground': true,
            'lastUpdate': '2026-10-21T14:00:00.000Z',
          }),
        );
        final native = NativeCrashReporter.instance = FakeNativeReporter(
          lastRunCrashed: true,
          previous: [nativeCrash()],
        );
        await start(
          monitoring: MonitoringOptions(
            beforeSend: (event, hint) {
              event.tags['seen'] = hint.mechanism?.type ?? '-';
              return event;
            },
          ),
        );
        await flush();
        expect(native.settings!.release, 'com.shop.app@1.0.0+1');
        expect(native.settings!.inAppIncludes, ['com.shop.app']);

        final previous = backend
            .items('session')
            .firstWhere(
              (s) => s['sid'] == '11111111-1111-4111-8111-111111111111',
            );
        expect(previous['status'], 'crashed');
        expect(previous['errors'], 1);
        expect(previous['release'], 'com.shop.app@0.9.0+8');
        expect(previous['timestamp'], '2026-10-21T14:00:00.000Z');

        final event = backend.items('event').single;
        expect(event['eventId'], '22222222-2222-4222-8222-222222222222');
        expect(event['runtime'], 'flutter');
        expect(event['level'], 'fatal');
        expect(event['release'], 'com.shop.app@0.9.0+8');
        expect(event['user'], {'id': 'u_crashed'});
        expect(event['tags'], {'screen': 'camera', 'seen': 'signal'});
        final contexts = event['contexts']! as Map;
        expect((contexts['app'] as Map)['appVersion'], '0.9.0');
        expect(
          contexts['os'],
          isNotNull,
          reason: 'device contexts of this launch',
        );
        final frames =
            ((((event['exception']! as Map)['values'] as List).single
                        as Map)['stacktrace']
                    as Map)['frames']
                as List;
        expect((frames[0] as Map)['inApp'], isFalse, reason: 'the engine');
        expect((frames[1] as Map)['inApp'], isTrue, reason: 'a plugin');
        expect((frames[1] as Map)['imageAddr'], '0x7b00000000');
        expect((event['threads'] as List).single, containsPair('name', 'main'));
        expect(
          (event['debugImages'] as List).single,
          containsPair('debugId', 'abc'),
        );
      },
    );

    test(
      'a hang while running counts in the session and can be sampled',
      () async {
        final native = NativeCrashReporter.instance = FakeNativeReporter();
        await start();
        native.live.add(
          NativeCrashEvent(
            jsonEncode({
              'eventId': '33333333-3333-4333-8333-333333333333',
              'timestamp': '2026-10-21T14:00:05.000Z',
              'level': 'error',
              'exception': {
                'values': [
                  {
                    'type': 'ApplicationNotResponding',
                    'mechanism': {'type': 'anr', 'handled': false},
                  },
                ],
              },
            }),
            live: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await flush();
        final event = backend.items('event').single;
        expect(event['level'], 'error');
        expect(
          BugCapsule.lastEventId(),
          '33333333-3333-4333-8333-333333333333',
        );
        expect(backend.items('session').map((s) => s['errors']), contains(1));
      },
    );

    test('the scope reaches the native handler redacted', () async {
      final native = NativeCrashReporter.instance = FakeNativeReporter();
      await start();
      BugCapsule.setUser(const MonitoringUser(id: 'u_7'));
      BugCapsule.setTag('screen', 'checkout');
      BugCapsule.addBreadcrumb(
        Breadcrumb(message: 'pay', data: {'password': 'hunter2'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final scope = (jsonDecode(native.scopes.last) as Map)
          .cast<String, Object?>();
      expect(scope['user'], {'id': 'u_7'});
      expect(scope['tags'], containsPair('screen', 'checkout'));
      expect(((scope['contexts'] as Map)['app'] as Map)['appVersion'], '1.0.0');
      expect(jsonEncode(scope['breadcrumbs']), contains('pay'));
      expect(native.scopes.last, isNot(contains('hunter2')));
    });

    test(
      "an earlier run's event never gets this launch's app context",
      () async {
        final event = (jsonDecode(nativeCrash()) as Map)..remove('contexts');
        NativeCrashReporter.instance = FakeNativeReporter(
          previous: [jsonEncode(event)],
        );
        await start();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await flush();
        final contexts = backend.items('event').single['contexts']! as Map;
        expect(contexts.containsKey('app'), isFalse);
        expect(contexts['os'], isNotNull);
      },
    );

    test(
      'malformed native events are dropped, the hub keeps running',
      () async {
        NativeCrashReporter.instance = FakeNativeReporter(
          previous: [
            'not json',
            jsonEncode({
              'eventId': 'x',
              'threads': [
                {'stacktrace': 'oops'},
              ],
              'exception': {
                'values': [
                  {
                    'type': 'E',
                    'stacktrace': {
                      'frames': [
                        {'package': 7, 'lineno': '12'},
                      ],
                    },
                  },
                ],
              },
            }),
          ],
        );
        await start();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await flush();
        final event = backend.items('event').single;
        expect(event['eventId'], 'x');
        BugCapsule.captureException(StateError('still works'));
        await flush();
        expect(backend.items('event'), hasLength(2));
      },
    );

    /// Runs a recording session that leaves its crash journal behind, as a
    /// process that dies does.
    Future<void> crashedSession() async {
      await start();
      BugCapsule.log('opened checkout');
      BugCapsule.log('tapped pay');
      await BugCapsule.resetForTest();
      expect(
        Directory('${dir.path}/journal/$pid/events').listSync(),
        isNotEmpty,
      );
    }

    Future<Map<String, Object?>> linkedEvent() async {
      for (var i = 0; i < 100; i++) {
        await BugCapsule.flush();
        final events = backend.items('event');
        if (events.isNotEmpty) return events.single;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('no event was sent');
    }

    test(
      'a native crash of the last run gives a crash capsule from its journal, linked to the event',
      () async {
        await crashedSession();
        NativeCrashReporter.instance = FakeNativeReporter(
          lastRunCrashed: true,
          previous: [
            nativeCrash(
              release: 'com.shop.app@1.0.0+1',
              timestamp: DateTime.now().toUtc().toIso8601String(),
            ),
          ],
        );
        await start();
        final event = await linkedEvent();
        await BugCapsule.flushUploads();

        final capsule = CapsuleCodec.decode(backend.capsules.single);
        final m = capsule.manifest;
        expect(event['capsuleId'], m.capsuleId);
        expect(m.failure!.kind, FailureKind.crash);
        expect(m.failure!.signature, 'crash:SIGSEGV');
        expect(m.failure!.crash!.inAppFrame, 'take_picture');
        expect(m.monitoring!.eventId, event['eventId']);
        expect(m.monitoring!.release, 'com.shop.app@1.0.0+1');
        expect(m.labels['source'], 'crash_journal');
        expect(m.labels['crash.mechanism'], 'signal');
        expect(
          m.eligibility.missing.map((g) => g.dependency),
          contains('crash.native'),
        );
        expect(
          [
            for (final e in capsule.eventsOfType(EventTypes.log))
              e.data['message'],
          ],
          ['opened checkout', 'tapped pay'],
        );
        expect(
          CapsuleCodec.toJson(capsule)['specVersion'],
          2,
          reason: 'crash capsules are format v2',
        );
        // The claimed journal is gone; this process keeps its own.
        final journals = Directory('${dir.path}/journal').listSync().map(
          (d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last,
        );
        expect(journals, ['$pid']);
      },
    );

    test(
      'the journal named in the crashed scope is used, and the marker is never sent',
      () async {
        await crashedSession();
        final native = NativeCrashReporter.instance = FakeNativeReporter(
          previous: [
            nativeCrash(
              timestamp: DateTime.now().toUtc().toIso8601String(),
              contexts: {
                MonitoringHub.journalContext: {'id': '$pid'},
              },
            ),
          ],
        );
        await start();
        final event = await linkedEvent();
        expect(event['capsuleId'], isNotNull);
        expect(
          (event['contexts']! as Map).keys,
          isNot(contains(MonitoringHub.journalContext)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          native.scopes.last,
          contains('"${MonitoringHub.journalContext}":{"id":"$pid"}'),
          reason: 'this process names its journal for its own crashes',
        );
      },
    );

    test(
      'without a journal (or a crashed last run) the event comes alone; stale journals go',
      () async {
        await crashedSession();
        NativeCrashReporter.instance = FakeNativeReporter(
          previous: [
            nativeCrash(timestamp: DateTime.now().toUtc().toIso8601String()),
          ],
        );
        await start();
        final event = await linkedEvent();
        expect(event.containsKey('capsuleId'), isFalse);
        expect(backend.capsules, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final journals = Directory('${dir.path}/journal').listSync().map(
          (d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last,
        );
        expect(journals, ['$pid'], reason: 'no event claimed the old journal');
      },
    );

    test('crash capsules do not count against maxCapsulesPerSession', () async {
      await crashedSession();
      NativeCrashReporter.instance = FakeNativeReporter(
        lastRunCrashed: true,
        previous: [
          nativeCrash(timestamp: DateTime.now().toUtc().toIso8601String()),
        ],
      );
      await start(autoCapture: true);
      await linkedEvent();
      BugCapsule.fail('checkout_stuck', 'spinner never stopped');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await BugCapsule.flushUploads();
      expect(backend.capsules, hasLength(2));
    });

    test('closing BugCapsule stops the native reporter', () async {
      final native = NativeCrashReporter.instance = FakeNativeReporter();
      await start();
      expect(native.stops, 0);
      await BugCapsule.resetForTest();
      expect(native.stops, 1);
    });

    test(
      'enableNativeCrashHandling: false leaves the native SDK alone',
      () async {
        final native = NativeCrashReporter.instance = FakeNativeReporter(
          lastRunCrashed: true,
          previous: [nativeCrash()],
        );
        await start(
          monitoring: const MonitoringOptions(enableNativeCrashHandling: false),
        );
        await flush();
        expect(native.settings, isNull);
        expect(backend.items('event'), isEmpty);
      },
    );
  });

  group('sessions after an update', () {
    test('a recovered session keeps the release it ran with', () async {
      File('${dir.path}/session.json').writeAsStringSync(
        jsonEncode({
          'sid': '44444444-4444-4444-8444-444444444444',
          'did': 'install',
          'seq': 1,
          'release': 'com.shop.app@0.9.0+8',
          'environment': 'production',
          'started': '2026-10-21T13:58:00.000Z',
          'errors': 0,
          'status': 'ok',
          'foreground': true,
          'lastUpdate': '2026-10-21T14:00:00.000Z',
        }),
      );
      await start();
      await flush();
      final previous = backend
          .items('session')
          .firstWhere(
            (s) => s['sid'] == '44444444-4444-4444-8444-444444444444',
          );
      expect(previous['status'], 'abnormal');
      expect(previous['release'], 'com.shop.app@0.9.0+8');
      expect(previous['environment'], 'production');
      final current = backend.items('session').last;
      expect(current['release'], 'com.shop.app@1.0.0+1');
    });
  });

  group('tracing', () {
    test(
      'startSpan sends a transaction with its children; errors inside carry the trace',
      () async {
        await start(monitoring: const MonitoringOptions(tracesSampleRate: 1));
        await BugCapsule.startSpan('checkout', 'task', (span) async {
          span.startChild('db.sql.query', description: 'SELECT cart').finish();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          BugCapsule.captureException(StateError('inside'));
        });
        await flush();
        final tx = backend.items('transaction').single;
        expect(tx['name'], 'checkout');
        expect(tx['op'], 'task');
        expect(tx['status'], 'ok');
        expect(tx['traceId'], matches(RegExp(r'^[0-9a-f]{32}$')));
        final span = (tx['spans']! as List).single as Map;
        expect(span['op'], 'db.sql.query');
        expect(span['parentSpanId'], tx['spanId']);
        final trace =
            (backend.items('event').single['contexts']! as Map)['trace'] as Map;
        expect(trace['traceId'], tx['traceId']);
        expect(trace['spanId'], tx['spanId']);
      },
    );

    test('unsampled traces propagate the 00 flag and are not sent', () async {
      await start(monitoring: const MonitoringOptions(tracesSampleRate: 0));
      final tx = BugCapsule.startTransaction(
        'screen',
        'ui.load',
        bindToScope: true,
      );
      expect(BugCapsule.getTraceparent(), endsWith('-00'));
      tx.finish();
      await flush();
      expect(backend.items('transaction'), isEmpty);
    });

    test(
      'the backend tracesSampleRate replaces the app rate; continueTrace joins a trace',
      () async {
        backend.tracesSampleRate = 1;
        await start(monitoring: const MonitoringOptions(tracesSampleRate: 0));
        BugCapsule.continueTrace(
          '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
          'bugcapsule-sample_rate=0.5',
        );
        BugCapsule.startTransaction('incoming', 'task').finish();
        BugCapsule.startTransaction('fresh', 'task').finish();
        await flush();
        final txs = backend.items('transaction');
        expect(txs[0]['traceId'], '4bf92f3577b34da6a3ce929d0e0e4736');
        expect(txs[0]['parentSpanId'], '00f067aa0ba902b7');
        expect(txs[1]['traceId'], isNot('4bf92f3577b34da6a3ce929d0e0e4736'));
      },
    );

    test(
      'Dio: http.client spans and trace headers for targets only, never in the capsule',
      () async {
        final bugCapsuleDio = BugCapsuleDio();
        await start(
          integrations: [bugCapsuleDio],
          monitoring: const MonitoringOptions(
            tracesSampleRate: 1,
            tracePropagationTargets: ['api.test'],
          ),
        );
        final server = EchoServer();
        final dio = Dio()..httpClientAdapter = server;
        bugCapsuleDio.attach(dio);

        late Response<Object?> response;
        await BugCapsule.startSpan('cart', 'ui.load', (_) async {
          response = await dio.get(
            'https://api.test/cart',
            options: Options(headers: {'baggage': 'vendor=1'}),
          );
          await dio.get('https://cdn.other.test/logo.png');
        });
        final capture = await BugCapsule.capture(note: 'check');
        await flush();

        final tx = backend.items('transaction').single;
        final spans = (tx['spans']! as List).cast<Map<String, Object?>>();
        expect(spans.length, 2);
        expect(spans[0]['op'], 'http.client');
        expect(spans[0]['description'], 'GET https://api.test/cart');
        expect((spans[0]['data']! as Map)['http.response.status_code'], 200);
        expect(
          server.headers[0]['traceparent'],
          '00-${tx['traceId']}-${spans[0]['spanId']}-01',
        );
        expect(
          server.headers[0]['baggage'],
          startsWith('vendor=1,bugcapsule-trace_id=${tx['traceId']},'),
        );
        expect(server.headers[1].containsKey('traceparent'), isFalse);
        expect(
          response.requestOptions.headers.containsKey('traceparent'),
          isFalse,
          reason: 'app headers restored',
        );

        final capsule = CapsuleCodec.decode(await capture!.file.readAsBytes());
        final recorded =
            capsule.eventsOfType(EventTypes.http).first.data['requestHeaders']!
                as Map;
        expect(recorded.containsKey('traceparent'), isFalse);
        expect(recorded['baggage'], 'vendor=1');
      },
    );

    test(
      'package:http in a session that does not record: headers, span and breadcrumb',
      () async {
        final bugCapsuleHttp = BugCapsuleHttp();
        await start(
          mode: CaptureMode.production,
          productionSampleRate: 0,
          integrations: [bugCapsuleHttp],
          monitoring: const MonitoringOptions(
            tracesSampleRate: 1,
            tracePropagationTargets: [r'/^https:\/\/api\./'],
          ),
        );
        expect(BugCapsule.isRecording, isFalse);
        final seen = <Map<String, String>>[];
        final client = bugCapsuleHttp.client(
          MockClient((req) async {
            seen.add(req.headers);
            return http.Response('nope', 503);
          }),
        );
        final tx = BugCapsule.startTransaction(
          'home',
          'navigation',
          bindToScope: true,
        );
        await client.get(
          Uri.parse('https://api.shop.test/items?token=synthQueryToken002'),
        );
        BugCapsule.captureException(StateError('after request'));
        tx.finish();
        await flush();

        expect(seen.single['traceparent'], startsWith('00-${tx.traceId}-'));
        final span =
            ((backend.items('transaction').single['spans']! as List).single
                as Map);
        expect(span['status'], 'unavailable');
        final crumbs = (backend.items('event').single['breadcrumbs']! as List)
            .cast<Map<String, Object?>>();
        final crumb = crumbs.singleWhere((c) => c['type'] == 'http');
        expect((crumb['data']! as Map)['status_code'], 503);
        expect(crumb['level'], 'error');
        expect(raw(), isNot(contains('synthQueryToken002')));
      },
    );
  });

  group('feedback', () {
    test('captureFeedback links the event and, in QA, a capsule', () async {
      await start();
      final eventId = BugCapsule.captureException(
        StateError('checkout broke'),
      )!;
      final feedbackId = await BugCapsule.captureFeedback(
        message: 'Checkout button did nothing',
        name: 'Ana',
        email: 'ana@example.com',
        eventId: eventId,
      );
      expect(feedbackId, isNotNull);
      await flush();
      final feedback = backend.items('feedback').single;
      expect(feedback['feedbackId'], feedbackId);
      expect(feedback['eventId'], eventId);
      expect(feedback['message'], 'Checkout button did nothing');
      expect(feedback['name'], 'Ana');
      expect(feedback['email'], 'ana@example.com');
      expect(feedback['runtime'], 'flutter');
      final capsule = CapsuleCodec.decode(backend.capsules.single);
      expect(feedback['capsuleId'], capsule.manifest.capsuleId);
      expect(capsule.manifest.monitoring!.eventId, eventId);
      expect(capsule.manifest.labels['note'], 'Checkout button did nothing');
    });

    test('an empty message is not sent', () async {
      await start();
      expect(await BugCapsule.captureFeedback(message: '   '), isNull);
    });
  });
}
