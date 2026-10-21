import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/src/core/core.dart';
import 'package:test/test.dart';

const vmTrace = '''
#0      CartBloc._onCheckout (package:shop_app/cart/cart_bloc.dart:88:7)
#1      Bloc.on.<anonymous closure> (package:bloc/src/bloc.dart:229:26)
<asynchronous suspension>
#2      main.<anonymous closure> (package:shop_app/main.dart:12)
#3      _rootRun (dart:async/zone.dart:1399:13)
#4      helper (file:///Users/dev/shop/tool/helper.dart:3:1)
''';

const aotTrace = '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 12345, tid: 6789, name io.flutter.1.ui
os: android arch: arm64 comp: yes sim: no
build_id: '0123456789abcdef0123456789abcdef'
isolate_dso_base: 7b3c5e4000, vm_dso_base: 7b3c5e4000
isolate_instructions: 7b3c6a1000, vm_instructions: 7b3c69e000
    #00 abs 0000007b3c7f5f3b virt 00000000002a1f3b _kDartIsolateSnapshotInstructions+0x1c3f3b
    #01 abs 0000007b3c7f5e83 virt 00000000002a1e83 _kDartIsolateSnapshotInstructions+0x1c3e83
<asynchronous suspension>
''';

void main() {
  group('Dart stack parsing', () {
    test('VM frames: oldest first, inApp from the app package', () {
      final stack = parseDartStack(vmTrace, rules: const InAppRules(includes: ['shop_app']));
      expect(stack.native, isFalse);
      expect([for (final f in stack.frames) f.function],
          ['helper', '_rootRun', 'main.<anonymous closure>', 'Bloc.on.<anonymous closure>', 'CartBloc._onCheckout']);
      final crash = stack.frames.last;
      expect(crash.toJson(), {
        'function': 'CartBloc._onCheckout',
        'filename': 'cart/cart_bloc.dart',
        'absPath': 'package:shop_app/cart/cart_bloc.dart',
        'lineno': 88,
        'colno': 7,
        'inApp': true,
        'package': 'shop_app',
      });
      expect(stack.frames[2].lineno, 12);
      expect(stack.frames[2].colno, isNull);
      expect(stack.frames[3].inApp, isFalse, reason: 'package:bloc');
      expect(stack.frames[1].inApp, isFalse, reason: 'dart:async');
      expect(stack.frames[1].filename, 'async/zone.dart');
      expect(stack.frames[0].inApp, isFalse, reason: 'file: URIs are not app packages');
    });

    test('inAppExcludes wins over includes; flutter and dart: are never app code', () {
      const rules = InAppRules(includes: ['shop_app', 'flutter'], excludes: ['shop_app']);
      expect(rules.isInApp('shop_app', 'package:shop_app/a.dart'), isFalse);
      expect(rules.isInApp('flutter', 'package:flutter/a.dart'), isFalse);
      expect(rules.isInApp(null, 'dart:core'), isFalse);
    });

    test('AOT non-symbolic traces become instructionAddr frames plus an elf image', () {
      final stack = parseDartStack(aotTrace);
      expect(stack.native, isTrue);
      expect([for (final f in stack.frames) f.instructionAddr], ['0x7b3c7f5e82', '0x7b3c7f5f3b']);
      expect(stack.frames.every((f) => f.function == null && f.imageAddr == '0x7b3c5e4000'), isTrue);
      expect(stack.debugImages.single, {
        'type': 'elf',
        'debugId': '67452301-ab89-efcd-0123-456789abcdef',
        'codeId': '0123456789abcdef0123456789abcdef',
        'codeFile': 'libapp.so',
        'imageAddr': '0x7b3c5e4000',
        'arch': 'arm64',
      });
    });

    test('AOT frames: the crashing frame keeps its PC, callers point into the call (return address - 1)', () {
      const trace = '''
build_id: '0123456789abcdef0123456789abcdef'
isolate_dso_base: 100000000, vm_dso_base: 0
    #00 abs 0000000100001000 virt 0000000000001000 _kDartSnapshotText+0x1000
    #01 abs 0000000100002000 virt 0000000000002000 _kDartSnapshotText+0x2000
<asynchronous suspension>
    #02 abs 0000000100003000 virt 0000000000003000 _kDartSnapshotText+0x3000
''';
      final frames = parseDartStack(trace).frames;
      // Oldest call first: #02, #01, then the crashing #00 last.
      expect([for (final f in frames) f.instructionAddr], ['0x100002fff', '0x100001fff', '0x100001000']);
    });

    test('AOT traces without isolate_dso_base derive it from abs - virt; iOS uses App.framework', () {
      final trace = aotTrace
          .replaceAll(RegExp(r'isolate_dso_base.*\n'), '')
          .replaceAll('os: android', 'os: ios');
      final stack = parseDartStack(trace);
      expect(stack.debugImages.single['imageAddr'], '0x7b3c554000');
      expect(stack.debugImages.single['codeFile'], 'App.framework/App');
    });

    test('Chrome and package:stack_trace terse formats', () {
      final v8 = parseDartStack('Error: boom\n    at Object.checkout (http://localhost:8080/main.dart.js:120:15)\n'
          '    at http://localhost:8080/main.dart.js:5:1');
      expect(v8.frames.last.function, 'Object.checkout');
      expect(v8.frames.last.lineno, 120);
      expect(v8.frames.last.colno, 15);
      expect(v8.frames.first.function, '<anonymous>');
      final terse = parseDartStack('packages/shop_app/cart.dart 12:5   checkout',
          rules: const InAppRules(includes: ['shop_app']));
      expect(terse.frames.single.package, 'shop_app');
      expect(terse.frames.single.inApp, isTrue);
    });

    test('build id to debug id: first 16 bytes, first three fields byte-swapped, zero padded', () {
      expect(debugIdFromBuildId('0123456789abcdef0123456789abcdef01234567'), '67452301-ab89-efcd-0123-456789abcdef');
      expect(debugIdFromBuildId('01020304'), '04030201-0000-0000-0000-000000000000');
      expect(debugIdFromBuildIdBytes([for (var i = 0; i < 20; i++) i]), '03020100-0504-0706-0809-0a0b0c0d0e0f');
    });
  });

  group('trace headers', () {
    test('ids are lowercase hex, never all zero', () {
      expect(newTraceId(), matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(newSpanId(), matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('traceparent round trip and rejection of malformed headers', () {
      const tp = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';
      final parsed = TraceParent.parse(tp)!;
      expect(parsed.traceId, '4bf92f3577b34da6a3ce929d0e0e4736');
      expect(parsed.parentSpanId, '00f067aa0ba902b7');
      expect(parsed.sampled, isTrue);
      expect(TraceParent.format(parsed.traceId, parsed.parentSpanId, false), tp.replaceAll(RegExp(r'01$'), '00'));
      expect(TraceParent.parse('00-${'0' * 32}-00f067aa0ba902b7-01'), isNull);
      expect(TraceParent.parse('garbage'), isNull);
      expect(TraceParent.parse(null), isNull);
    });

    test('baggage: encoded bugcapsule entries, other vendors kept, ours replaced', () {
      final ours = Baggage.format(
          traceId: 'abc', release: 'com.shop@1.0+2', environment: 'production', sampleRate: 1.0, sampled: true);
      expect(ours,
          'bugcapsule-trace_id=abc,bugcapsule-release=com.shop%401.0%2B2,bugcapsule-environment=production,'
          'bugcapsule-sample_rate=1,bugcapsule-sampled=true');
      final merged = Baggage.merge('vendor=1, bugcapsule-trace_id=old,other=x', ours);
      expect(merged, startsWith('vendor=1,other=x,bugcapsule-trace_id=abc'));
      expect(Baggage.parse(merged)['release'], 'com.shop@1.0+2');
      expect(Baggage.parse(merged)['trace_id'], 'abc');
    });

    test('propagation targets: substrings and /regex/', () {
      final t = PropagationTargets(['api.shop.com', r'/^https:\/\/[a-z]+\.internal\//']);
      expect(t.matches('https://api.shop.com/cart'), isTrue);
      expect(t.matches('https://billing.internal/pay'), isTrue);
      expect(t.matches('https://cdn.other.com/x'), isFalse);
      expect(PropagationTargets(const []).matches('https://api.shop.com'), isFalse);
    });

    test('HTTP status maps to span status like OpenTelemetry', () {
      expect(SpanStatus.fromHttp(200), 'ok');
      expect(SpanStatus.fromHttp(304), 'ok');
      expect(SpanStatus.fromHttp(401), 'unauthenticated');
      expect(SpanStatus.fromHttp(404), 'not_found');
      expect(SpanStatus.fromHttp(418), 'invalid_argument');
      expect(SpanStatus.fromHttp(429), 'resource_exhausted');
      expect(SpanStatus.fromHttp(503), 'unavailable');
      expect(SpanStatus.fromHttp(502), 'internal_error');
    });

    test('names never carry ids', () {
      expect(parameterizePath('/product/42?ref=mail#top'), '/product/:id');
      expect(parameterizePath('/order/8f0e2a1c-1234-4abc-8def-0123456789ab/items'), '/order/:id/items');
      expect(parameterizePath('/user/deadbeefcafe/settings'), '/user/:id/settings');
      expect(parameterizePath('/product/:id'), '/product/:id');
    });
  });

  group('event payload', () {
    test('contract shape and bounds', () {
      final event = ErrorEvent(
        eventId: '8f0e2a1c-1234-4abc-8def-0123456789ab',
        timestamp: DateTime.utc(2026, 10, 21, 14, 3, 10, 982),
        release: 'com.shop@1.4.0+52',
        environment: 'production',
        exceptions: [
          ExceptionValue(
            type: 'StateError',
            value: 'x' * 9000,
            mechanism: Mechanism.flutterError,
            frames: [for (var i = 0; i < 300; i++) EventFrame(function: 'f$i')],
          ),
        ],
        tags: {'screen': 'checkout', 'bad key!': 'dropped', 'long': 'v' * 300},
        breadcrumbs: [for (var i = 0; i < 120; i++) Breadcrumb(message: '$i')],
      );
      final json = event.toJson();
      expect(json['timestamp'], '2026-10-21T14:03:10.982Z');
      expect(json['runtime'], 'flutter');
      expect(json['level'], 'error');
      final ex = ((json['exception']! as Map)['values'] as List).single as Map;
      expect((ex['value'] as String).length, 8192);
      expect(ex['mechanism'], {'type': 'flutter_error', 'handled': false});
      final frames = (ex['stacktrace'] as Map)['frames'] as List;
      expect(frames.length, 250);
      expect((frames.last as Map)['function'], 'f299', reason: 'frames closest to the crash are kept');
      expect(json['tags'], {'screen': 'checkout', 'long': 'v' * 200});
      final crumbs = json['breadcrumbs']! as List;
      expect(crumbs.length, 100);
      expect((crumbs.last as Map)['message'], '119');
      expect(event.unhandled, isTrue);
    });
  });

  group('envelope', () {
    test('gzip JSON with sdk and sentAt; restamp updates sentAt only', () {
      final bytes = EnvelopeCodec.encode(
        [const EnvelopeItem('event', {'eventId': 'e1'})],
        sdkVersion: '0.4.0',
        sentAt: DateTime.utc(2026, 1, 1),
      );
      expect(bytes.take(2), [0x1f, 0x8b]);
      final json = EnvelopeCodec.decode(bytes);
      expect(json['sentAt'], '2026-01-01T00:00:00.000Z');
      expect(json['sdk'], {'name': 'bugcapsule-flutter', 'version': '0.4.0'});
      expect(json['items'], [
        {'type': 'event', 'payload': {'eventId': 'e1'}},
      ]);
      final again = EnvelopeCodec.decode(EnvelopeCodec.restamp(bytes, DateTime.utc(2026, 1, 2)));
      expect(again['sentAt'], '2026-01-02T00:00:00.000Z');
      expect(again['items'], json['items']);
      expect(jsonDecode(utf8.decode(gzip.decode(bytes))), isA<Map<String, Object?>>());
    });

    test('response: rejected items are listed', () {
      final r = EnvelopeResponse.fromJson({
        'accepted': 1,
        'rejected': [
          {'index': 1, 'reason': r'$.items[1].payload.sid must be a UUID'},
        ],
      });
      expect(r.accepted, 1);
      expect(r.rejected.single, contains('sid must be a UUID'));
    });
  });

  group('manifest.monitoring', () {
    Map<String, Object?> doc(Map<String, Object?> monitoring) {
      final fixture = jsonDecode(File('../../spec/fixtures/capsule-v1/valid/minimal.json').readAsStringSync()) as Map;
      final full = fixture['document'] as Map;
      return {
        ...full.cast<String, Object?>(),
        'manifest': {...(full['manifest'] as Map).cast<String, Object?>(), 'monitoring': monitoring},
      };
    }

    test('round-trips and validates', () {
      final json = doc({'eventId': 'e1', 'traceId': '4bf92f3577b34da6a3ce929d0e0e4736', 'release': 'r', 'environment': 'qa'});
      expect(validateCapsuleDocument(json), isNull);
      final capsule = CapsuleCodec.fromJson(json);
      expect(capsule.manifest.monitoring!.eventId, 'e1');
      expect(capsule.manifest.toJson()['monitoring'], (json['manifest']! as Map)['monitoring']);
    });

    test('a monitoring object without eventId is invalid', () {
      expect(validateCapsuleDocument(doc({'release': 'r'})), contains('monitoring'));
    });
  });
}
