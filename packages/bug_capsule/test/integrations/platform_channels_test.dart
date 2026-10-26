import 'dart:async';
import 'dart:typed_data';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _codec = StandardMethodCodec();

/// The native side of a few plugins.
class FakePlatform implements BinaryMessenger {
  FakePlatform({this.forbidden = false});

  /// Replay must never reach the native side.
  final bool forbidden;
  final Map<String, MessageHandler> handlers = {};
  int calls = 0;

  @override
  Future<ByteData?> send(String channel, ByteData? message) async {
    if (forbidden) throw StateError('native $channel called during replay');
    calls++;
    if (channel == 'msg') {
      final m = const StandardMessageCodec().decodeMessage(message);
      return const StandardMessageCodec().encodeMessage('pong:$m');
    }
    final call = _codec.decodeMethodCall(message);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    switch ('$channel/${call.method}') {
      case 'battery/getLevel':
        return _codec.encodeSuccessEnvelope(80.0);
      case 'battery/fail':
        return _codec.encodeErrorEnvelope(
          code: 'UNAVAILABLE',
          message: 'Battery info unavailable',
          details: {'retry': true},
        );
      case 'battery/nothing':
        return _codec.encodeSuccessEnvelope(null);
      case 'battery/typed':
        return _codec.encodeSuccessEnvelope({
          1: Uint8List.fromList([0, 1, 255]),
          'big': 9007199254740993,
          'f': Float64List.fromList([1.5, double.infinity]),
        });
      case 'nfc/start':
        return null;
      case 'charging/listen':
        unawaited(_emitCharging());
        return _codec.encodeSuccessEnvelope(null);
      case 'charging/cancel':
        return _codec.encodeSuccessEnvelope(null);
    }
    throw StateError('unexpected ${call.method} on $channel');
  }

  Future<void> _emitCharging() async {
    Future<void> emit(ByteData? data) async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await handlers['charging']?.call(data);
    }

    await emit(_codec.encodeSuccessEnvelope('charging'));
    await emit(_codec.encodeErrorEnvelope(code: 'SENSOR', message: 'lost'));
    await emit(_codec.encodeSuccessEnvelope('full'));
    await emit(null);
  }

  /// A platform-to-Dart call (push notification callback).
  Future<Object?> push(String channel, MethodCall call) async {
    final reply = await handlers[channel]!(_codec.encodeMethodCall(call));
    return reply == null ? null : _codec.decodeEnvelope(reply);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    if (handler == null) {
      handlers.remove(channel);
    } else {
      handlers[channel] = handler;
    }
  }

  @override
  // ignore: deprecated_member_use
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) async {}
}

BugCapsulePlatformChannels channels() => BugCapsulePlatformChannels(
  interceptDefaultMessenger: false,
  captureBinary: true,
  channels: [
    const PlatformChannel.method('battery'),
    const PlatformChannel.method('nfc'),
    const PlatformChannel.method('push'),
    const PlatformChannel.event('charging'),
    const PlatformChannel.message('msg'),
  ],
);

/// What the app observes.
Future<List<Object?>> scenario(
  BugCapsulePlatformChannels integration,
  FakePlatform platform, {
  required bool replaying,
}) async {
  final m = integration.messenger(platform);
  final seen = <Object?>[];
  Future<void> attempt(Future<Object?> Function() fn) async {
    try {
      seen.add(await fn());
    } on PlatformException catch (e) {
      seen.add('PlatformException(${e.code}, ${e.message}, ${e.details})');
    } on MissingPluginException {
      seen.add('MissingPluginException');
    }
  }

  final battery = MethodChannel('battery', _codec, m);
  final levels = await Future.wait([
    battery.invokeMethod<double>('getLevel'),
    battery.invokeMethod<double>('getLevel'),
  ]);
  seen
    ..add(levels)
    ..add(levels.first.runtimeType.toString());
  await attempt(() => battery.invokeMethod<void>('fail'));
  await attempt(() => battery.invokeMethod<Object?>('nothing'));
  await attempt(() => battery.invokeMethod<Object?>('typed'));
  await attempt(
    () => MethodChannel('nfc', _codec, m).invokeMethod<void>('start', {
      1: Uint8List.fromList([7]),
    }),
  );

  // EventChannel sends listen/cancel through the default messenger (which
  // BugCapsule's binding wraps in an app); route it to the decorator here.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler(
        'charging',
        (message) => m.send('charging', message),
      );
  final events = <Object?>[];
  final done = Completer<void>();
  EventChannel('charging', _codec, m).receiveBroadcastStream().listen(
    events.add,
    onError: (Object e) => events.add('error:${(e as PlatformException).code}'),
    onDone: done.complete,
  );
  await done.future.timeout(const Duration(seconds: 2));
  seen.add(events);

  final pushes = <Object?>[];
  MethodChannel('push', _codec, m).setMethodCallHandler((call) async {
    pushes.add(call.arguments);
    return 'ack';
  });
  if (!replaying) {
    seen.add(
      await platform.push(
        'push',
        const MethodCall('onMessage', {'title': 'Hi'}),
      ),
    );
  } else {
    // The recorded callback arrives on its own; the app's answer is checked.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    seen.add('ack');
  }
  seen.add(pushes);

  seen.add(
    await BasicMessageChannel<Object?>(
      'msg',
      const StandardMessageCodec(),
      binaryMessenger: m,
    ).send('ping'),
  );
  return seen;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(InteractionHarness, List<Object?>)> capture() async {
    final h = InteractionHarness.capture();
    final integration = channels();
    await h.setUp([integration]);
    final seen = await scenario(integration, FakePlatform(), replaying: false);
    return (h, seen);
  }

  test('records calls, results, errors, streams and callbacks', () async {
    final (h, seen) = await capture();
    expect(seen[0], [80.0, 80.0]);
    expect(seen[1], 'double');
    expect(seen[2], contains('UNAVAILABLE'));
    expect(seen[3], isNull);
    expect(seen[5], 'MissingPluginException');
    expect(seen[6], ['charging', 'error:SENSOR', 'full']);
    expect(seen[7], 'ack');
    expect(seen.last, 'pong:ping');

    final calls = h.events.where((e) => e.type == 'platform.call').toList();
    final getLevels = calls.where((e) => e.data['method'] == 'getLevel');
    expect([for (final c in getLevels) c.data['occurrence']], [0, 1]);
    expect(getLevels.first.data['key'], getLevels.last.data['key']);
    expect(
      h.events.firstWhere((e) => e.type == 'platform.result').data['value'],
      containsPair('value', {r'$t': 'double', 'v': '80.0'}),
    );
    expect(
      h.events
          .where((e) => e.type == 'platform.error')
          .map((e) => e.data['kind']),
      ['platform', 'missing'],
    );
    expect(
      calls.singleWhere((e) => e.data['dir'] == 'platform').data['method'],
      'onMessage',
    );
    expect(
      h.events.map((e) => e.type),
      containsAll(['platform.listen', 'platform.event', 'platform.done']),
    );
    final [dep] = h.dependencies();
    expect(dep.kind, 'platform.channel');
    expect(dep.coverage, DependencyCoverage.complete);
  });

  test('replay answers from the capsule and never calls the plugin', () async {
    final (h, seen) = await capture();
    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final integration = channels();
    await replay.setUp([integration]);
    final native = FakePlatform(forbidden: true);
    final replayed = await scenario(integration, native, replaying: true);
    expect(replayed, seen);
    expect(native.calls, 0);
    expect(replay.finish(), isEmpty);
  });

  test('typed values survive the capsule', () async {
    final (h, seen) = await capture();
    final typed = seen[4]! as Map;
    expect(typed[1], isA<Uint8List>());
    expect(typed['big'], 9007199254740993);
    expect(typed['f'], isA<Float64List>());
    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final integration = channels();
    await replay.setUp([integration]);
    final replayed = await scenario(
      integration,
      FakePlatform(forbidden: true),
      replaying: true,
    );
    final again = replayed[4]! as Map;
    expect(again[1], [0, 1, 255]);
    expect(again['big'], 9007199254740993);
    expect((again['f'] as Float64List)[1], double.infinity);
  });

  test('unrecorded calls fail with bugcapsule.unrecorded', () async {
    final (h, _) = await capture();
    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final integration = channels();
    await replay.setUp([integration]);
    final battery = MethodChannel(
      'battery',
      _codec,
      integration.messenger(FakePlatform(forbidden: true)),
    );
    await expectLater(
      battery.invokeMethod<void>('reboot'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'bugcapsule.unrecorded',
        ),
      ),
    );
    await expectLater(
      MethodChannel(
        'nfc',
        _codec,
        integration.messenger(FakePlatform(forbidden: true)),
      ).invokeMethod<void>('start', {2: 'other'}),
      throwsA(isA<PlatformException>()),
    );
    final types = [for (final d in replay.finish()) d.type];
    expect(types.take(2), ['platform.unrecorded', 'platform.mismatch']);
    expect(types, contains('platform.unused'));
  });

  test('channels that are not listed pass through untouched', () async {
    final h = InteractionHarness.capture();
    final integration = channels();
    await h.setUp([integration]);
    final platform = FakePlatform();
    final other = MethodChannel(
      'charging',
      _codec,
      integration.messenger(platform),
    );
    await other.invokeMethod<void>('cancel');
    expect(
      BugCapsulePlatformChannels(
        interceptDefaultMessenger: false,
        channels: [const PlatformChannel.method('x')],
      ).operations,
      isNotEmpty,
    );
    final unlisted = MethodChannel(
      'unlisted',
      _codec,
      integration.messenger(platform),
    );
    await expectLater(unlisted.invokeMethod<void>('x'), throwsStateError);
    expect(h.events.where((e) => e.data['channel'] == 'unlisted'), isEmpty);
  });

  test('a late binding is reported, not hidden', () async {
    final h = InteractionHarness.capture();
    final integration = BugCapsulePlatformChannels(
      channels: [const PlatformChannel.method('battery')],
    );
    await h.setUp([integration]);
    expect(integration.coversDefaultMessenger, isFalse);
    expect(
      integration.stats.gaps.map((g) => g.code),
      contains(DependencyGaps.channelLate),
    );
  });

  test('a capsule without channel traffic never calls the plugin', () async {
    final replay = InteractionHarness.replay(const [], dependencies: const []);
    final integration = channels();
    await replay.setUp([integration]);
    final native = FakePlatform(forbidden: true);
    await expectLater(
      MethodChannel(
        'battery',
        _codec,
        integration.messenger(native),
      ).invokeMethod<double>('getLevel'),
      throwsA(isA<PlatformException>()),
    );
    expect(native.calls, 0);
    expect([for (final d in replay.finish()) d.type], ['platform.unrecorded']);
  });

  test('a failed EventChannel listen replays as failed', () async {
    final h = InteractionHarness.capture();
    final integration = BugCapsulePlatformChannels(
      interceptDefaultMessenger: false,
      channels: [const PlatformChannel.event('sensor')],
    );
    await h.setUp([integration]);
    Future<Object?> listen(BinaryMessenger platform) async {
      final m = integration.messenger(platform);
      final reply = await m.send(
        'sensor',
        _codec.encodeMethodCall(const MethodCall('listen')),
      );
      try {
        return _codec.decodeEnvelope(reply!);
      } on PlatformException catch (e) {
        return e.code;
      }
    }

    final denied = _Denying();
    expect(await listen(denied), 'PERMISSION_DENIED');
    expect(integration.openInteractions(), hasLength(1));
    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final again = BugCapsulePlatformChannels(
      interceptDefaultMessenger: false,
      channels: [const PlatformChannel.event('sensor')],
    );
    await replay.setUp([again]);
    final m = again.messenger(FakePlatform(forbidden: true));
    final reply = await m.send(
      'sensor',
      _codec.encodeMethodCall(const MethodCall('listen')),
    );
    expect(
      () => _codec.decodeEnvelope(reply!),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'PERMISSION_DENIED',
        ),
      ),
    );
  });
}

class _Denying extends FakePlatform {
  @override
  Future<ByteData?> send(String channel, ByteData? message) async =>
      _codec.encodeErrorEnvelope(code: 'PERMISSION_DENIED', message: 'no');
}
