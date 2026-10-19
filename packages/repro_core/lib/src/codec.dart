import 'dart:convert';
import 'dart:io' show gzip;

import 'capsule.dart';
import 'event.dart';

class CapsuleFormatException implements Exception {
  CapsuleFormatException(this.message);
  final String message;
  @override
  String toString() => 'CapsuleFormatException: $message';
}

/// Reads and writes `.repro` files (gzip-compressed JSON, spec v1).
abstract final class CapsuleCodec {
  static const format = 'repro.capsule';
  static const specVersion = 1;

  static Map<String, Object?> toJson(Capsule capsule) => {
        'format': format,
        'specVersion': specVersion,
        'manifest': capsule.manifest.toJson(),
        'checkpoint': capsule.checkpoint.toJson(),
        'events': [for (final e in capsule.events) e.toJson()],
      };

  static List<int> encode(Capsule capsule) =>
      gzip.encode(utf8.encode(jsonEncode(toJson(capsule))));

  static Capsule decode(List<int> bytes) {
    final List<int> raw;
    try {
      raw = gzip.decode(bytes);
    } on FormatException {
      throw CapsuleFormatException('not a gzip file');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException catch (e) {
      throw CapsuleFormatException('invalid JSON: ${e.message}');
    }
    if (json is! Map) throw CapsuleFormatException('top level is not an object');
    return fromJson(json.cast<String, Object?>());
  }

  static Capsule fromJson(Map<String, Object?> json) {
    if (json['format'] != format) {
      throw CapsuleFormatException('format is "${json['format']}", expected "$format"');
    }
    final version = json['specVersion'];
    if (version is! int) throw CapsuleFormatException('specVersion missing');
    if (version > specVersion) {
      throw CapsuleFormatException(
          'capsule spec v$version is newer than this reader (v$specVersion); update repro');
    }
    try {
      return Capsule(
        manifest: CapsuleManifest.fromJson((json['manifest'] as Map).cast<String, Object?>()),
        checkpoint: Checkpoint.fromJson((json['checkpoint'] as Map).cast<String, Object?>()),
        events: [
          for (final e in json['events'] as List)
            ReproEvent.fromJson((e as Map).cast<String, Object?>()),
        ],
      );
    } on TypeError catch (e) {
      throw CapsuleFormatException('malformed capsule: $e');
    }
  }
}
