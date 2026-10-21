import 'dart:convert';
import 'dart:io';

import 'package:repro_core/repro_core.dart';
import 'package:test/test.dart';

/// Shared capsule fixtures (`spec/fixtures/capsule-v1`). The backend runs
/// the same files through its validator, so the two stay in agreement:
/// whatever the backend stores, this SDK and the CLI can decode.
void main() {
  final root = Directory('../../spec/fixtures/capsule-v1');

  List<(String, Map<String, Object?>)> load(String kind) {
    final files =
        Directory(
            '${root.path}/$kind',
          ).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final f in files)
        (
          f.uri.pathSegments.last,
          (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>(),
        ),
    ];
  }

  test('fixtures are present', () {
    expect(load('valid'), hasLength(greaterThanOrEqualTo(4)));
    expect(load('invalid'), hasLength(greaterThanOrEqualTo(25)));
  });

  group('valid', () {
    for (final (name, fixture) in load('valid')) {
      test(name, () {
        final doc = (fixture['document'] as Map).cast<String, Object?>();
        expect(validateCapsuleDocument(doc), isNull);
        final gz = gzip.encode(utf8.encode(jsonEncode(doc)));
        final capsule = CapsuleCodec.decode(gz);
        expect(capsule.manifest.capsuleId, (doc['manifest'] as Map)['capsuleId']);
        expect(capsule.events, hasLength((doc['events'] as List).length));
        // Everything a replay touches must be readable without type errors.
        final fixtures = FixtureStore(capsule.events);
        for (final e in capsule.eventsOfType(EventTypes.http)) {
          final f = HttpFixture(e);
          expect(
            () => [f.key, f.occurrence, f.status, f.durationMs, f.responseHeaders, f.error],
            returnsNormally,
          );
        }
        expect(fixtures.keyCount, greaterThanOrEqualTo(0));
        expect(capsule.manifest.labels.values.every((v) => v.isNotEmpty || v.isEmpty), isTrue);
        // Encoding what was decoded produces a valid document again.
        expect(validateCapsuleDocument(CapsuleCodec.toJson(capsule)), isNull);
      });
    }
  });

  group('invalid', () {
    for (final (name, fixture) in load('invalid')) {
      test(name, () {
        final doc = (fixture['document'] as Map).cast<String, Object?>();
        final path = fixture['errorPath'] as String;
        final gz = gzip.encode(utf8.encode(jsonEncode(doc)));
        expect(
          () => CapsuleCodec.decode(gz),
          throwsA(
            isA<CapsuleFormatException>().having((e) => e.message, 'message', contains(path)),
          ),
        );
      });
    }
  });

  test('documents with millions of tiny values are rejected before parsing', () {
    final raw = utf8.encode('[${'{},' * 4100000}{}]');
    expect(
      () => CapsuleCodec.decode(gzip.encode(raw)),
      throwsA(isA<CapsuleFormatException>().having((e) => e.message, 'message', contains('JSON values'))),
    );
  });

  test('decoding is bounded against gzip bombs', () {
    final bomb = gzip.encode(List<int>.filled(4 * 1024 * 1024, 32));
    expect(
      () => CapsuleCodec.decode(bomb, maxDecompressedBytes: 1024 * 1024),
      throwsA(
        isA<CapsuleFormatException>().having((e) => e.message, 'message', contains('exceeds')),
      ),
    );
  });
}
