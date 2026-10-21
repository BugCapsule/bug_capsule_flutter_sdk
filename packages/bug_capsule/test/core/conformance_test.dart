import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/generate_conformance.dart';

/// The conformance fixtures (`spec/fixtures/conformance`) are generated from
/// this package; the Android, iOS and web SDKs test against them. Regenerate
/// with `dart run tool/generate_conformance.dart` after changing behaviour.
void main() {
  final fixtures = buildConformanceFixtures();
  for (final entry in fixtures.entries) {
    test('${entry.key} is up to date', () {
      final file = File('../../spec/fixtures/conformance/${entry.key}');
      expect(file.existsSync(), isTrue, reason: 'run dart run tool/generate_conformance.dart');
      expect(jsonDecode(file.readAsStringSync()), jsonDecode(jsonEncode(entry.value)),
          reason: 'stale; run dart run tool/generate_conformance.dart');
    });
  }

  test('fixtures cover every area', () {
    expect((fixtures['request-keys.json'] as Map)['cases'] as List, hasLength(greaterThan(20)));
    expect((fixtures['verdicts.json'] as Map)['cases'] as List, hasLength(greaterThan(15)));
  });
}
