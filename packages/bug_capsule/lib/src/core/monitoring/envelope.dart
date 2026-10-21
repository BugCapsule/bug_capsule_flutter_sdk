import 'dart:convert';
import 'dart:io';

import 'model.dart';

/// Envelope item types (monitoring-v1 §1).
abstract final class EnvelopeItemType {
  static const event = 'event';
  static const session = 'session';
  static const transaction = 'transaction';
  static const feedback = 'feedback';
}

class EnvelopeItem {
  const EnvelopeItem(this.type, this.payload);

  final String type;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {'type': type, 'payload': payload};
}

/// The body of `POST /v1/envelope`, stored gzip-compressed in the outbox and
/// sent with `Content-Encoding: gzip`.
abstract final class EnvelopeCodec {
  static const sdkName = 'bugcapsule-flutter';
  static const maxItems = 100;

  static List<int> encode(List<EnvelopeItem> items, {required String sdkVersion, DateTime? sentAt}) {
    assert(items.length <= maxItems);
    return gzip.encode(utf8.encode(jsonEncode({
      'sentAt': isoTimestamp(sentAt ?? DateTime.now()),
      'sdk': {'name': sdkName, 'version': sdkVersion},
      'items': [for (final i in items) i.toJson()],
    })));
  }

  static Map<String, Object?> decode(List<int> bytes) =>
      (jsonDecode(utf8.decode(gzip.decode(bytes))) as Map).cast<String, Object?>();

  /// The stored envelope with `sentAt` set to [now] (it was stamped when
  /// queued, possibly days earlier).
  static List<int> restamp(List<int> bytes, DateTime now) {
    final json = decode(bytes);
    json['sentAt'] = isoTimestamp(now);
    return gzip.encode(utf8.encode(jsonEncode(json)));
  }
}

/// Body of a `200` from `/v1/envelope`: `{accepted, rejected: [{index, reason}]}`.
/// Rejected items are never retried.
class EnvelopeResponse {
  const EnvelopeResponse(this.accepted, this.rejected);

  factory EnvelopeResponse.fromJson(Map<String, Object?> j) => EnvelopeResponse(
        j['accepted'] as int? ?? 0,
        [
          for (final r in (j['rejected'] as List?) ?? const [])
            if (r is Map) '${r['index']}: ${r['reason']}',
        ],
      );

  final int accepted;
  final List<String> rejected;
}
