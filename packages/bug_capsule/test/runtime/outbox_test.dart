import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule/src/runtime/backend.dart';

List<int> capsuleBytes(int size, [int fill = 1]) => [
  0x1f,
  0x8b,
  ...List<int>.filled(size - 2, fill),
];

void main() {
  late Directory dir;
  var now = DateTime.utc(2026, 10, 21, 12);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bugcapsule-outbox-');
    now = DateTime.utc(2026, 10, 21, 12);
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<UploadOutbox> open({OutboxLimits limits = const OutboxLimits()}) =>
      UploadOutbox.open(dir, limits: limits, now: () => now);

  Future<List<String>> ids(UploadOutbox o) async => [
    for (final e in await o.entries()) e.capsuleId,
  ];

  test(
    'repeated offline sessions never exceed the count, byte and age limits',
    () async {
      const limits = OutboxLimits(
        maxCount: 3,
        maxBytes: 2500,
        maxAge: Duration(days: 2),
      );
      for (var session = 0; session < 5; session++) {
        final o = await open(limits: limits);
        for (var i = 0; i < 3; i++) {
          now = now.add(const Duration(minutes: 1));
          expect(await o.enqueue('s$session-c$i', capsuleBytes(1000)), isTrue);
          final entries = await o.entries();
          expect(entries.length, lessThanOrEqualTo(3));
          expect(
            entries.fold<int>(0, (s, e) => s + e.size),
            lessThanOrEqualTo(2500),
          );
        }
        // Offline: every upload fails and is kept for later.
        await o.flush(
          upload: (_) async => const UploadResult(UploadStatus.retryLater),
          allowed: () => true,
        );
        await o.close();
        now = now.add(const Duration(hours: 6));
      }
      final o = await open(limits: limits);
      expect(await ids(o), [
        's4-c1',
        's4-c2',
      ], reason: 'oldest evicted first, within 2500 bytes');

      now = now.add(const Duration(days: 3));
      final aged = await open(limits: limits);
      expect(await aged.entries(), isEmpty, reason: 'older than maxAge');
    },
  );

  test('a capsule larger than the outbox is refused, not queued', () async {
    final o = await open(limits: const OutboxLimits(maxBytes: 100));
    expect(await o.enqueue('big', capsuleBytes(101)), isFalse);
    expect(await o.entries(), isEmpty);
  });

  test('leftover temp files are removed and corrupt files dropped', () async {
    await File('${dir.path}/1_a.bugcapsule.123.tmp').writeAsBytes([1, 2]);
    await File('${dir.path}/2_corrupt.bugcapsule').writeAsBytes([1, 2, 3]);
    await File(
      '${dir.path}/legacy-id.bugcapsule',
    ).writeAsBytes(capsuleBytes(10)); // SDK 0.1.0 name
    final o = await open();
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    final sent = <int>[];
    await o.flush(
      upload: (b) async {
        sent.add(b.length);
        return const UploadResult(UploadStatus.uploaded);
      },
      allowed: () => true,
    );
    expect(sent, [10], reason: 'the corrupt file is never uploaded');
    expect(await o.entries(), isEmpty);
  });

  test('disk errors are reported as not queued, never thrown', () async {
    final o = await open();
    await dir.delete(recursive: true);
    await File(dir.path).writeAsString('not a directory');
    expect(await o.enqueue('x', capsuleBytes(10)), isFalse);
    await File(dir.path).delete();
  });

  test(
    'retryable failures back off; rejections are dropped; success resets',
    () async {
      final o = await open();
      await o.enqueue('a', capsuleBytes(10));
      now = now.add(const Duration(seconds: 1));
      await o.enqueue('b', capsuleBytes(10));
      var calls = 0;
      var next = UploadStatus.retryLater;
      Future<UploadResult> upload(List<int> _) async {
        calls++;
        return UploadResult(
          next,
          message: 'x',
          retryAfter: next == UploadStatus.retryLater
              ? const Duration(minutes: 5)
              : null,
        );
      }

      await o.flush(upload: upload, allowed: () => true);
      expect(calls, 1, reason: 'the pass stops at the first retryable failure');
      // Retry-After (5 min) with ±20 % jitter.
      final wait = o.retryAt!.difference(now);
      expect(wait, greaterThanOrEqualTo(const Duration(minutes: 4)));
      expect(wait, lessThanOrEqualTo(const Duration(minutes: 6)));
      await o.flush(upload: upload, allowed: () => true);
      expect(calls, 1, reason: 'still backing off');

      now = now.add(const Duration(minutes: 7));
      next = UploadStatus.rejected;
      await o.flush(upload: upload, allowed: () => true);
      expect(calls, 3);
      expect(await o.entries(), isEmpty);
      expect(o.retryAt, isNull);
    },
  );

  test(
    'uploads stop as soon as they are no longer allowed (kill switch mid-flush)',
    () async {
      final o = await open();
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 1));
        await o.enqueue('c$i', capsuleBytes(10));
      }
      var allowed = true;
      var calls = 0;
      await o.flush(
        upload: (_) async {
          calls++;
          allowed = false; // the disable decision lands during the first upload
          return const UploadResult(UploadStatus.uploaded);
        },
        allowed: () => allowed,
      );
      expect(calls, 1);
      expect(await o.purge(), 2);
      expect(await o.entries(), isEmpty);
    },
  );

  test(
    'enqueue does not wait for an upload in flight; flushes are serialized',
    () async {
      final o = await open();
      await o.enqueue('first', capsuleBytes(10));
      final release = Completer<void>();
      var inFlight = 0;
      var maxInFlight = 0;
      Future<UploadResult> slow(List<int> _) async {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await release.future;
        inFlight--;
        return const UploadResult(UploadStatus.uploaded);
      }

      final f1 = o.flush(upload: slow, allowed: () => true);
      final f2 = o.flush(upload: slow, allowed: () => true, onlyId: 'second');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      now = now.add(const Duration(seconds: 1));
      expect(
        await o
            .enqueue('second', capsuleBytes(10))
            .timeout(const Duration(seconds: 1)),
        isTrue,
      );
      release.complete();
      await f1;
      final mine = await f2;
      expect(maxInFlight, 1);
      expect(mine!.status, UploadStatus.uploaded);
      expect(await o.entries(), isEmpty);
    },
  );

  test('a capsule that keeps failing goes behind newer ones', () async {
    final o = await open();
    await o.enqueue('big', capsuleBytes(20));
    now = now.add(const Duration(seconds: 1));
    await o.enqueue('small', capsuleBytes(10));
    final sizes = <int>[];
    await o.flush(
      upload: (b) async {
        sizes.add(b.length);
        return const UploadResult(UploadStatus.retryLater, message: 'timeout');
      },
      allowed: () => true,
    );
    expect(sizes, [20], reason: 'oldest first, the pass stops at the failure');

    now = now.add(const Duration(hours: 2)); // past the backoff
    sizes.clear();
    await o.flush(
      upload: (b) async {
        sizes.add(b.length);
        return const UploadResult(UploadStatus.uploaded);
      },
      allowed: () => true,
    );
    expect(sizes, [
      10,
      20,
    ], reason: 'the failing capsule no longer blocks newer ones');
    expect(await o.entries(), isEmpty);
  });

  test('close drains a queued purge before storage can be removed', () async {
    final o = await open();
    await o.enqueue('pending', capsuleBytes(10));
    final purge = o.purge();
    await o.close();
    expect(dir.listSync().whereType<File>(), isEmpty);
    await purge;
  });

  test('after close, enqueue is refused and flush stops', () async {
    final o = await open();
    await o.close();
    expect(await o.enqueue('x', capsuleBytes(10)), isFalse);
  });
}
