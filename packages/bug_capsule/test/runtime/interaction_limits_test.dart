import 'dart:async';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A chatty dependency: a stream of large quotes.
class TickerAdapter extends NativeAdapter {
  TickerAdapter(this.source);

  final Stream<Map<String, Object?>> Function() source;

  @override
  String get name => 'ticker';
  @override
  String get adapter => 'example.ticker';
  @override
  List<String> get operations => const ['ticks'];

  Stream<Map<String, Object?>> ticks() => subscribe(
    'ticks',
    open: source,
    encode: (v) => v,
    decode: (json) => (json! as Map).cast<String, Object?>(),
  );
}

void main() {
  test('sustained traffic stays within the payload budget', () async {
    final h = InteractionHarness.capture(
      limits: const InteractionLimits(maxWindowPayloadBytes: 256 * 1024),
    );
    final blob = 'x' * 4000;
    final adapter = TickerAdapter(
      () => Stream.fromIterable([
        for (var i = 0; i < 2000; i++) {'seq': i, 'blob': blob},
      ]),
    );
    await h.setUp([adapter]);
    final sw = Stopwatch()..start();
    final seen = await adapter.ticks().length;
    sw.stop();
    expect(seen, 2000, reason: 'the app sees every event');

    final kept = [
      for (final e in h.events)
        if (e.type == 'native.event' &&
            (e.data['value'] as Map)['replayable'] == true)
          e,
    ];
    final bytes = adapter.stats.payloadBytes;
    expect(bytes, lessThanOrEqualTo(256 * 1024));
    expect(kept.length, lessThan(2000));
    expect(adapter.stats.dropped, 2000 - kept.length);
    final dep = h.dependencies().single;
    expect(dep.coverage, DependencyCoverage.partial);
    expect(
      dep.gaps.map((g) => g.code),
      contains(DependencyGaps.payloadDropped),
    );
    // Recording overhead per event, for the performance notes.
    // ignore: avoid_print
    print(
      'captured 2000 events in ${sw.elapsedMilliseconds} ms '
      '(${(sw.elapsedMicroseconds / 2000).toStringAsFixed(1)} µs/event), '
      'kept ${kept.length} payloads, $bytes bytes',
    );
  });

  test('payloads over the per-payload limit are truncated', () async {
    final h = InteractionHarness.capture(
      limits: const InteractionLimits(maxPayloadBytes: 1024),
    );
    final adapter = TickerAdapter(() => Stream.value({'blob': 'y' * 5000}));
    await h.setUp([adapter]);
    await adapter.ticks().drain<void>();
    final value =
        h.events.firstWhere((e) => e.type == 'native.event').data['value']
            as Map;
    expect(value['mode'], 'truncated');
    expect(value['replayable'], isFalse);
    expect(value, isNot(contains('value')));
    // A truncated payload cannot be served: replay reports it.
    final replay = InteractionHarness.replay(
      h.encodedEvents(),
      dependencies: h.dependencies(),
    );
    final again = TickerAdapter(() => throw StateError('live call'));
    await replay.setUp([again]);
    await again.ticks().drain<void>().timeout(
      const Duration(milliseconds: 300),
      onTimeout: () {},
    );
    expect(replay.finish().map((d) => d.type), contains('native.noPayload'));
  });

  test('credentials are redacted before an event is stored', () async {
    final h = InteractionHarness.capture();
    final adapter = TickerAdapter(
      () => Stream.value({'symbol': 'ACME', 'apiKey': 'sk_live_123'}),
    );
    await h.setUp([adapter]);
    await adapter.ticks().drain<void>();
    final value =
        h.events.firstWhere((e) => e.type == 'native.event').data['value']
            as Map;
    expect(value['mode'], 'redacted');
    expect('$value', isNot(contains('sk_live_123')));
  });

  test('a capsule without this adapter fails its calls offline', () async {
    final replay = InteractionHarness.replay(const [], dependencies: const []);
    final adapter = TickerAdapter(() => throw StateError('live call'));
    await replay.setUp([adapter]);
    await expectLater(
      adapter.ticks().drain<void>(),
      throwsA(isA<NativeAdapterException>()),
    );
    expect([for (final d in replay.finish()) d.type], ['native.unrecorded']);
  });
}
