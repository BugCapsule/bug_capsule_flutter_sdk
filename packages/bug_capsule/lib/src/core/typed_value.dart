import 'dart:convert';
import 'dart:typed_data';

import 'redaction.dart';

/// Lossless JSON for the values platform channels and native SDKs exchange
/// (capsule-v2 §3.1): integers vs doubles, byte and numeric arrays, and maps
/// with non-string keys survive a round trip, so replay hands the app the
/// same value it saw when capturing.
abstract final class TypedValue {
  static const tag = r'$t';
  static const _maxSafeInt = 9007199254740991;

  /// Encodes [value] as typed-value JSON. Values this encoder cannot
  /// represent become an `unsupported` tag; [isReplayable] reports them.
  static Object? encode(Object? value) {
    if (value == null || value is bool || value is String) return value;
    if (value is int) {
      return value.abs() <= _maxSafeInt ? value : {tag: 'int', 'v': '$value'};
    }
    if (value is double) {
      final plain =
          value.isFinite &&
          value != value.truncateToDouble() &&
          !(value == 0 && value.isNegative);
      return plain ? value : {tag: 'double', 'v': '$value'};
    }
    if (value is Uint8List) return {tag: 'bytes', 'b64': base64Encode(value)};
    if (value is ByteBuffer) {
      return {tag: 'bytes', 'b64': base64Encode(value.asUint8List())};
    }
    if (value is ByteData) {
      return {
        tag: 'bytes',
        'b64': base64Encode(
          value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes),
        ),
      };
    }
    if (value is Int32List) return {tag: 'i32', 'v': List<int>.of(value)};
    if (value is Int64List) {
      return {
        tag: 'i64',
        'v': [for (final v in value) '$v'],
      };
    }
    if (value is Float32List) {
      return {
        tag: 'f32',
        'v': [for (final v in value) _floatItem(v)],
      };
    }
    if (value is Float64List) {
      return {
        tag: 'f64',
        'v': [for (final v in value) _floatItem(v)],
      };
    }
    if (value is List) return [for (final v in value) encode(v)];
    if (value is Map) {
      final plain = value.keys.every((k) => k is String && k != tag);
      if (plain) {
        return {
          for (final e in value.entries) e.key as String: encode(e.value),
        };
      }
      return {
        tag: 'map',
        'e': [
          for (final e in value.entries) [encode(e.key), encode(e.value)],
        ],
      };
    }
    return {tag: 'unsupported', 'type': '${value.runtimeType}'};
  }

  static Object _floatItem(double v) =>
      v.isFinite && !(v == 0 && v.isNegative) ? v : '$v';

  /// Decodes typed-value JSON back into Dart values (the inverse of
  /// [encode]). An `unsupported` tag decodes to null.
  static Object? decode(Object? json) {
    if (json is List) return [for (final v in json) decode(v)];
    if (json is! Map) return json;
    final t = json[tag];
    if (t == null) {
      return <String, Object?>{
        for (final e in json.entries) '${e.key}': decode(e.value),
      };
    }
    final v = json['v'];
    switch (t) {
      case 'int':
        return int.parse(v as String);
      case 'double':
        return double.parse(v as String);
      case 'bytes':
        return base64Decode(json['b64'] as String);
      case 'i32':
        return Int32List.fromList([for (final x in v as List) x as int]);
      case 'i64':
        return Int64List.fromList([for (final x in v as List) int.parse('$x')]);
      case 'f32':
        return Float32List.fromList([for (final x in v as List) _float(x)]);
      case 'f64':
        return Float64List.fromList([for (final x in v as List) _float(x)]);
      case 'map':
        return <Object?, Object?>{
          for (final e in json['e'] as List)
            decode((e as List)[0]): decode(e[1]),
        };
      default:
        return null;
    }
  }

  static double _float(Object? x) =>
      x is num ? x.toDouble() : double.parse(x as String);

  /// Whether [json] holds no `unsupported` tag.
  static bool isReplayable(Object? json) {
    if (json is List) return json.every(isReplayable);
    if (json is! Map) return true;
    final t = json[tag];
    if (t == 'unsupported') return false;
    if (t == 'map') {
      return (json['e'] as List).every(
        (e) => isReplayable((e as List)[0]) && isReplayable(e[1]),
      );
    }
    if (t != null) return true;
    return json.values.every(isReplayable);
  }

  /// Redacts typed-value JSON like [Redactor.redactJson] does plain JSON:
  /// values under sensitive keys (string keys of plain or tagged maps) are
  /// replaced, strings are scrubbed. Byte and numeric arrays are left alone
  /// (binary content is the app's to describe). Returns the value and
  /// whether anything changed.
  static (Object?, bool) redact(Object? json, Redactor redactor) {
    if (json is String) {
      final out = redactor.redactJson(json);
      return (out, out != json);
    }
    if (json is List) {
      var changed = false;
      final out = <Object?>[];
      for (final v in json) {
        final (r, c) = redact(v, redactor);
        out.add(r);
        changed |= c;
      }
      return (out, changed);
    }
    if (json is! Map) return (json, false);
    final t = json[tag];
    if (t == null) {
      var changed = false;
      final out = <String, Object?>{};
      for (final e in json.entries) {
        final key = '${e.key}';
        if (e.value != null && redactor.isSensitiveKey(key)) {
          out[key] = Redactor.placeholder;
          changed = true;
        } else {
          final (r, c) = redact(e.value, redactor);
          out[key] = r;
          changed |= c;
        }
      }
      return (out, changed);
    }
    if (t == 'map') {
      var changed = false;
      final entries = <Object?>[];
      for (final e in json['e'] as List) {
        final pair = e as List;
        final key = pair[0];
        if (key is String && pair[1] != null && redactor.isSensitiveKey(key)) {
          entries.add([key, Redactor.placeholder]);
          changed = true;
        } else {
          final (k, kc) = redact(key, redactor);
          final (v, vc) = redact(pair[1], redactor);
          entries.add([k, v]);
          changed |= kc || vc;
        }
      }
      return ({tag: 'map', 'e': entries}, changed);
    }
    return (json, false);
  }

  /// Whether [json] contains binary data (`bytes` or numeric arrays).
  static bool hasBinary(Object? json) {
    if (json is List) return json.any(hasBinary);
    if (json is! Map) return false;
    final t = json[tag];
    if (t == 'bytes' || t == 'i32' || t == 'i64' || t == 'f32' || t == 'f64') {
      return true;
    }
    if (t == 'map') {
      return (json['e'] as List).any(
        (e) => hasBinary((e as List)[0]) || hasBinary(e[1]),
      );
    }
    return json.values.any(hasBinary);
  }
}
