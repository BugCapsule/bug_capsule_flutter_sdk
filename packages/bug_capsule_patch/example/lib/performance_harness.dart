import 'dart:convert';
import 'dart:io';
import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter/foundation.dart';

final class BenchmarkResult<O> {
  BenchmarkResult(this.output, this.patch, this.record);
  final O output;
  final BugCapsulePatch? patch;
  final Map<String, Object?> record;
}

final class PerformanceHarness {
  static final clock = Stopwatch()..start();
  static int get nowNs {
    final ticks = clock.elapsedTicks;
    return (ticks ~/ clock.frequency) * 1000000000 +
        (ticks % clock.frequency) * 1000000000 ~/ clock.frequency;
  }

  static Map<String, Object?> rss() {
    try {
      return {'residentBytes': ProcessInfo.currentRss};
    } on Object catch (e) {
      return {'error': '$e'};
    }
  }

  static Map<String, Object?> summary(List<int> values) {
    final sorted = [...values]..sort();
    int p(int percentile) =>
        sorted[(sorted.length * percentile + 99) ~/ 100 - 1];
    return {
      'samplesNs': values,
      'p50Ns': p(50),
      'p95Ns': p(95),
      'p99Ns': p(99),
      'maxNs': sorted.last,
    };
  }

  static void write(Directory exchange, Map<String, Object?> record) {
    final target = '${exchange.path}/benchmark-result.json';
    File('$target.tmp').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(record),
      flush: true,
    );
    File('$target.tmp').renameSync(target);
  }

  static BenchmarkResult<O> run<I, O>({
    required Directory exchange,
    required PatchModule<I, O> module,
    required I input,
    required BugCapsulePatch Function() open,
    required Map<String, String> Function(O) output,
  }) {
    final resultFile = File('${exchange.path}/benchmark-result.json');
    if (resultFile.existsSync()) resultFile.deleteSync();
    final request =
        (jsonDecode(
                  File(
                    '${exchange.path}/benchmark-config.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>();
    final mode = request['mode'];
    if (!['baseline', 'runtime'].contains(mode) ||
        request['runId'] is! String ||
        (request['runId']! as String).isEmpty ||
        request['expectedOutput'] is! Map ||
        request['expectedSource'] is! String) {
      throw const FormatException(
        'mode, runId, expectedOutput and expectedSource are required',
      );
    }
    final expected = (request['expectedOutput']! as Map).cast<String, String>();
    final record = <String, Object?>{
      'schemaVersion': 1,
      'runId': request['runId'],
      'mode': mode,
      'runtime': 'flutter_${Platform.operatingSystem}',
      'at': DateTime.now().toUtc().toIso8601String(),
      'buildMode': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      'osVersion': Platform.operatingSystemVersion,
      'deviceLabel': request['deviceLabel'],
      'physicalDevice': null,
      'physicalVerification':
          'operator must attach devicectl/device evidence; Dart OS name does not prove physical hardware',
      'thermalState': null,
      'thermalEvidence': 'record externally; no Dart thermal API is assumed',
      'warmupCount': 20,
      'sampleCount': 200,
      'stopwatchFrequency': clock.frequency,
      'rssBeforeOpen': rss(),
      'latencyVerdict': 'not_configured',
      'measurementScope':
          'first call is first in process, not guaranteed cold filesystem; RSS snapshots are not peak; startup clock begins in Dart main, after VM startup',
    };
    final beforeOpen = nowNs;
    final patch = mode == 'runtime' ? open() : null;
    record['runtimeOpenNs'] = mode == 'runtime' ? nowNs - beforeOpen : null;
    record['rssAfterOpen'] = rss();
    final reasons = <String, int>{};
    try {
      if (patch != null && !patch.available) {
        throw StateError('runtime unavailable: ${patch.unavailableReason}');
      }
      record['statusBefore'] = patch?.status();
      (O, int, String) evaluate() {
        final start = nowNs;
        final O value;
        final String source;
        final String? reason;
        if (patch == null) {
          value = module.fallback(input);
          source = 'direct_bundled';
          reason = null;
        } else {
          final result = patch.call(module, input);
          value = result.value;
          source = result.source.name;
          reason = result.reason;
        }
        final elapsed = nowNs - start;
        final actual = output(value);
        if (source != request['expectedSource'] ||
            actual.length != expected.length ||
            expected.entries.any((e) => actual[e.key] != e.value)) {
          throw StateError('unexpected source/output: $source $actual');
        }
        final allowed = request['expectedReasons'];
        if (allowed is List && !allowed.contains(reason ?? 'none')) {
          throw StateError('unexpected fallback reason: $reason');
        }
        reasons.update(reason ?? 'none', (n) => n + 1, ifAbsent: () => 1);
        return (value, elapsed, source);
      }

      final first = evaluate();
      record['firstCallNs'] = first.$2;
      for (var i = 0; i < 20; i++) {
        evaluate();
      }
      final samples = [for (var i = 0; i < 200; i++) evaluate().$2];
      final stats = summary(samples);
      record.addAll({
        'evaluation': stats,
        'output': expected,
        'source': first.$3,
        'reasonCounts': reasons,
        'rssAfterEvaluation': rss(),
      });
      if (patch != null) {
        final start = nowNs;
        try {
          patch.markHealthy('benchmark_output_verified');
          record['markHealthyNs'] = nowNs - start;
        } on Object catch (e) {
          record['markHealthyError'] = '$e';
        }
        record['statusAfter'] = patch.status();
      }
      record['correctness'] = 'passed';
      final budgets = request['budgetsNs'];
      if (budgets is Map) {
        final comparisons = <String, Object?>{};
        for (final key in ['p50Ns', 'p95Ns', 'p99Ns', 'maxNs']) {
          final limit = budgets[key];
          if (limit is num && limit > 0) {
            comparisons[key] = {
              'limitNs': limit,
              'measuredNs': stats[key],
              'passed': (stats[key]! as int) <= limit,
            };
          }
        }
        record['budgetComparisons'] = comparisons;
        if (comparisons.isNotEmpty) {
          record['latencyVerdict'] = 'see_user_limits';
        }
      }
      write(exchange, record);
      return BenchmarkResult(first.$1, patch, record);
    } on Object catch (e) {
      record.addAll({
        'correctness': 'failed',
        'error': '$e',
        'reasonCounts': reasons,
      });
      write(exchange, record);
      rethrow;
    }
  }
}

/// Measures the real transport, including buffering and any transport overhead.
/// Does not record endpoint URLs, tokens, payloads, or error text.
final class TimedPatchTransport implements PatchTransport {
  TimedPatchTransport(this.inner);
  final PatchTransport inner;
  final artifactFetches = <Map<String, Object?>>[];
  @override
  Future<SignedChannel?> fetchChannel({String? etag}) =>
      inner.fetchChannel(etag: etag);
  @override
  Future<void> postReceipts(Map<String, Object?> batch) =>
      inner.postReceipts(batch);
  @override
  Future<Uint8List> fetchArtifact(String digest) async {
    final start = PerformanceHarness.nowNs;
    try {
      final bytes = await inner.fetchArtifact(digest);
      artifactFetches.add({
        'elapsedNs': PerformanceHarness.nowNs - start,
        'receivedBytes': bytes.length,
        'completed': true,
      });
      return bytes;
    } on Object {
      artifactFetches.add({
        'elapsedNs': PerformanceHarness.nowNs - start,
        'completed': false,
      });
      rethrow;
    }
  }
}
