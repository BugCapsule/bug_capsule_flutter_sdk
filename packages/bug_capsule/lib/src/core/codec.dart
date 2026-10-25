import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'capsule.dart';
import 'capsule_validator.dart';
import 'event.dart';

class CapsuleFormatException implements Exception {
  CapsuleFormatException(this.message);
  final String message;
  @override
  String toString() => 'CapsuleFormatException: $message';
}

/// Reads and writes `.bugcapsule` files (gzip-compressed JSON, spec v1).
abstract final class CapsuleCodec {
  static const format = 'bugcapsule.capsule';
  static const specVersion = 1;

  /// Bounds what a hostile file or share link can make the reader allocate.
  /// Higher than the backend's upload ceiling (64 MB) so capsules stored by
  /// older backends still open.
  static const maxDecompressedBytes = 200 * 1024 * 1024;

  static Map<String, Object?> toJson(Capsule capsule) => {
    'format': format,
    'specVersion': specVersion,
    'manifest': capsule.manifest.toJson(),
    'checkpoint': capsule.checkpoint.toJson(),
    'events': [for (final e in capsule.events) e.toJson()],
  };

  static List<int> encode(Capsule capsule) =>
      gzip.encode(utf8.encode(jsonEncode(toJson(capsule))));

  static Capsule decode(
    List<int> bytes, {
    int maxDecompressedBytes = maxDecompressedBytes,
  }) {
    if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
      throw CapsuleFormatException('not a gzip file');
    }
    final raw = _gunzip(bytes, maxDecompressedBytes);
    if (_countJsonValues(raw, CapsuleLimits.maxJsonValues) >
        CapsuleLimits.maxJsonValues) {
      throw CapsuleFormatException(
        '\$ has more than ${CapsuleLimits.maxJsonValues} JSON values',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException catch (e) {
      throw CapsuleFormatException('invalid JSON: ${e.message}');
    }
    if (json is! Map) {
      throw CapsuleFormatException('top level is not an object');
    }
    return fromJson(json.cast<String, Object?>());
  }

  static List<int> _gunzip(List<int> bytes, int max) {
    final out = _CappedSink(max);
    try {
      gzip.decoder.startChunkedConversion(out)
        ..add(bytes)
        ..close();
    } on _TooLarge {
      throw CapsuleFormatException('decompressed capsule exceeds $max bytes');
    } on FormatException {
      throw CapsuleFormatException('not a valid gzip file');
    }
    return out.bytes.takeBytes();
  }

  /// Validates the whole document (see [validateCapsuleDocument]) before
  /// building the model, so malformed input fails here with a
  /// [CapsuleFormatException] naming the offending JSON path, never later
  /// with a type error in the middle of a replay.
  static Capsule fromJson(Map<String, Object?> json) {
    if (json['format'] != format) {
      throw CapsuleFormatException(
        '\$.format must be "$format" (got "${json['format']}")',
      );
    }
    final version = json['specVersion'];
    if (version is! int) {
      throw CapsuleFormatException('\$.specVersion must be an integer');
    }
    if (version > specVersion) {
      throw CapsuleFormatException(
        '\$.specVersion $version is newer than this reader '
        '(v$specVersion); update bugcapsule',
      );
    }
    final problem = validateCapsuleDocument(json);
    if (problem != null) {
      throw CapsuleFormatException('malformed capsule: $problem');
    }
    try {
      return Capsule(
        manifest: CapsuleManifest.fromJson(
          (json['manifest'] as Map).cast<String, Object?>(),
        ),
        checkpoint: Checkpoint.fromJson(
          (json['checkpoint'] as Map).cast<String, Object?>(),
        ),
        events: [
          for (final e in json['events'] as List)
            BugCapsuleEvent.fromJson((e as Map).cast<String, Object?>()),
        ],
      );
    } on CapsuleFormatException {
      rethrow;
    } catch (e) {
      // The validator should have caught this; a decode error must still
      // surface as a format error.
      throw CapsuleFormatException('malformed capsule: $e');
    }
  }
}

/// Values in UTF-8 JSON without parsing (`{`, `[` and `,` outside strings,
/// plus one); stops past [limit]. Same rule as the backend.
int _countJsonValues(List<int> buf, int limit) {
  var n = 1;
  var inString = false;
  for (var i = 0; i < buf.length; i++) {
    final c = buf[i];
    if (inString) {
      if (c == 0x5c) {
        i++;
      } else if (c == 0x22) {
        inString = false;
      }
    } else if (c == 0x22) {
      inString = true;
    } else if (c == 0x7b || c == 0x5b || c == 0x2c) {
      if (++n > limit) return n;
    }
  }
  return n;
}

class _TooLarge implements Exception {}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.max);

  final int max;
  final BytesBuilder bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > max) throw _TooLarge();
    bytes.add(chunk);
  }

  @override
  void close() {}
}
