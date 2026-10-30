import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule_patch_example/performance_harness.dart';

class FakeTransport implements PatchTransport {
  bool fail = false;
  @override
  Future<Uint8List> fetchArtifact(String digest) async {
    if (fail) throw StateError('private endpoint');
    return Uint8List(73);
  }

  @override
  Future<SignedChannel?> fetchChannel({String? etag}) async => null;
  @override
  Future<void> postReceipts(Map<String, Object?> batch) async {}
}

void main() {
  test('baseline verifies all calls and never opens runtime', () {
    final dir = Directory.systemTemp.createTempSync('bc-benchmark-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/benchmark-config.json').writeAsStringSync(
      jsonEncode({
        'runId': 'test',
        'mode': 'baseline',
        'expectedSource': 'direct_bundled',
        'expectedOutput': {'value': '7'},
        'expectedReasons': ['none'],
      }),
    );
    var calls = 0;
    final module = PatchModule<int, int>(
      id: 'test',
      inputSchema: 'int',
      outputSchema: 'int',
      encode: (x) => x,
      decode: (x) => x as int,
      fallback: (x) {
        calls++;
        return x;
      },
    );
    final measured = PerformanceHarness.run(
      exchange: dir,
      module: module,
      input: 7,
      open: () => throw StateError('baseline opened runtime'),
      output: (x) => {'value': '$x'},
    );
    expect(calls, 221);
    expect(measured.record['correctness'], 'passed');
    expect(measured.record['latencyVerdict'], 'not_configured');
    expect((measured.record['evaluation'] as Map)['samplesNs'], hasLength(200));
    expect(
      () => PerformanceHarness.run(
        exchange: dir,
        module: module,
        input: 8,
        open: () => throw StateError('baseline opened runtime'),
        output: (x) => {'value': '$x'},
      ),
      throwsStateError,
    );
    final failed =
        jsonDecode(File('${dir.path}/benchmark-result.json').readAsStringSync())
            as Map;
    expect(failed['correctness'], 'failed');
    expect(failed.containsKey('evaluation'), false);
  });
  test('nearest-rank summary preserves raw chronological samples', () {
    final samples = List.generate(200, (i) => 200 - i);
    final summary = PerformanceHarness.summary(samples);
    expect(summary['samplesNs'], samples);
    expect(summary['p50Ns'], 100);
    expect(summary['p95Ns'], 190);
    expect(summary['p99Ns'], 198);
    expect(summary['maxNs'], 200);
  });
  test(
    'transport measures actual returned bytes and preserves failure without secrets',
    () async {
      final inner = FakeTransport();
      final timed = TimedPatchTransport(inner);
      expect((await timed.fetchArtifact('digest')).length, 73);
      expect(timed.artifactFetches.single['receivedBytes'], 73);
      expect(
        timed.artifactFetches.single['elapsedNs'],
        greaterThanOrEqualTo(0),
      );
      inner.fail = true;
      await expectLater(timed.fetchArtifact('digest'), throwsStateError);
      expect(timed.artifactFetches.last['completed'], false);
      expect(timed.artifactFetches.last.containsKey('receivedBytes'), false);
      expect(
        timed.artifactFetches.toString(),
        isNot(contains('private endpoint')),
      );
    },
  );
}
