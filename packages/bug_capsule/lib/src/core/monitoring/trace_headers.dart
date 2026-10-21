import 'dart:math';

final Random _secure = Random.secure();

String _hex(int bytes) {
  while (true) {
    final b = List<int>.generate(bytes, (_) => _secure.nextInt(256));
    // All-zero ids are invalid (W3C trace context, monitoring-v1 §1).
    if (b.every((x) => x == 0)) continue;
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// 32 lowercase hex characters.
String newTraceId() => _hex(16);

/// 16 lowercase hex characters.
String newSpanId() => _hex(8);

/// A parsed `traceparent` header: `00-<traceId>-<parentSpanId>-<flags>`.
class TraceParent {
  const TraceParent(this.traceId, this.parentSpanId, this.sampled);

  final String traceId;
  final String parentSpanId;
  final bool sampled;

  static final _pattern = RegExp(r'^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$');

  /// Null when [header] is malformed or carries all-zero ids.
  static TraceParent? parse(String? header) {
    final m = _pattern.firstMatch(header?.trim().toLowerCase() ?? '');
    if (m == null || m[1] == 'ff') return null;
    if (RegExp(r'^0+$').hasMatch(m[2]!) || RegExp(r'^0+$').hasMatch(m[3]!)) return null;
    return TraceParent(m[2]!, m[3]!, (int.parse(m[4]!, radix: 16) & 1) == 1);
  }

  static String format(String traceId, String spanId, bool sampled) =>
      '00-$traceId-$spanId-${sampled ? '01' : '00'}';
}

/// `bugcapsule-*` entries of the W3C `baggage` header (monitoring-v1 §8).
abstract final class Baggage {
  static const prefix = 'bugcapsule-';

  static String format({
    required String traceId,
    String? release,
    String? environment,
    double? sampleRate,
    required bool sampled,
  }) {
    final entries = {
      'trace_id': traceId,
      'release': ?release,
      'environment': ?environment,
      if (sampleRate != null) 'sample_rate': _rate(sampleRate),
      'sampled': '$sampled',
    };
    return [for (final e in entries.entries) '$prefix${e.key}=${Uri.encodeComponent(e.value)}'].join(',');
  }

  static String _rate(double r) {
    final s = r.toString();
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  /// [existing] with its `bugcapsule-*` entries replaced by [ours]; other
  /// vendors' entries are kept in order.
  static String merge(String? existing, String ours) {
    final kept = [
      for (final entry in (existing ?? '').split(','))
        if (entry.trim().isNotEmpty && !entry.trim().startsWith(prefix)) entry.trim(),
    ];
    return [...kept, ours].join(',');
  }

  /// The `bugcapsule-*` entries of a header, keys without the prefix.
  static Map<String, String> parse(String? header) => {
        for (final entry in (header ?? '').split(','))
          if (entry.trim().startsWith(prefix) && entry.contains('='))
            entry.trim().substring(prefix.length, entry.trim().indexOf('=')):
                Uri.decodeComponent(entry.trim().substring(entry.trim().indexOf('=') + 1).split(';').first),
      };
}

/// `tracePropagationTargets`: plain strings match as substrings of the URL,
/// `/pattern/` strings as regular expressions.
class PropagationTargets {
  PropagationTargets(List<String> targets)
      : _substrings = [for (final t in targets) if (!_isRegex(t)) t],
        _patterns = [for (final t in targets) if (_isRegex(t)) RegExp(t.substring(1, t.length - 1))];

  final List<String> _substrings;
  final List<RegExp> _patterns;

  static bool _isRegex(String t) => t.length >= 2 && t.startsWith('/') && t.endsWith('/');

  bool matches(String url) => _substrings.any(url.contains) || _patterns.any((p) => p.hasMatch(url));
}

/// Span statuses of monitoring-v1 §8.
abstract final class SpanStatus {
  static const ok = 'ok';
  static const cancelled = 'cancelled';
  static const unknown = 'unknown';
  static const invalidArgument = 'invalid_argument';
  static const deadlineExceeded = 'deadline_exceeded';
  static const notFound = 'not_found';
  static const alreadyExists = 'already_exists';
  static const permissionDenied = 'permission_denied';
  static const resourceExhausted = 'resource_exhausted';
  static const failedPrecondition = 'failed_precondition';
  static const aborted = 'aborted';
  static const outOfRange = 'out_of_range';
  static const unimplemented = 'unimplemented';
  static const internalError = 'internal_error';
  static const unavailable = 'unavailable';
  static const dataLoss = 'data_loss';
  static const unauthenticated = 'unauthenticated';

  /// HTTP status → span status, as OpenTelemetry maps it.
  static String fromHttp(int status) => switch (status) {
        >= 200 && < 400 => ok,
        400 => invalidArgument,
        401 => unauthenticated,
        403 => permissionDenied,
        404 => notFound,
        409 => alreadyExists,
        412 => failedPrecondition,
        413 => outOfRange,
        429 => resourceExhausted,
        499 => cancelled,
        501 => unimplemented,
        503 => unavailable,
        504 => deadlineExceeded,
        >= 400 && < 500 => invalidArgument,
        >= 500 && < 600 => internalError,
        _ => unknown,
      };
}

final _idSegment = RegExp(
    r'^(?:\d+|[0-9a-fA-F]{8,}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$');

/// A path with id-like segments (numbers, hex runs of 8+, UUIDs) replaced by
/// `:id`, and no query or fragment, for transaction and span names.
String parameterizePath(String path) {
  final noQuery = path.split(RegExp('[?#]')).first;
  return noQuery.split('/').map((s) => _idSegment.hasMatch(s) ? ':id' : s).join('/');
}
