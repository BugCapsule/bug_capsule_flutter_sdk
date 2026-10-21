enum FailureKind { exception, assertion, manual }

/// A machine-checkable failure: the assertion replay and verify compare
/// against.
class FailureRecord {
  const FailureRecord({
    required this.kind,
    required this.signature,
    required this.type,
    required this.message,
    required this.t,
    this.stack,
    this.assertionId,
  });

  /// [scrub] removes credentials from the message and stack before anything
  /// is derived from them; capture and replay must pass the same function so
  /// that their signatures agree.
  factory FailureRecord.exception(Object error, StackTrace? stack, int t,
      {String Function(String text)? scrub}) {
    final type = error.runtimeType.toString();
    String clean(String s) => scrub == null ? s : scrub(s);
    final message = clean(_safeToString(error));
    return FailureRecord(
      kind: FailureKind.exception,
      signature: FailureSignature.compute(FailureKind.exception, type, message),
      type: type,
      message: _truncate(message, 2000),
      stack: stack == null ? null : clean(_truncate(stack.toString(), 8000)),
      t: t,
    );
  }

  /// A failure raised by the app through a registered assertion
  /// (`BugCapsule.fail('checkout_stuck', ...)`). The id, not the message, is the
  /// identity of the failure.
  factory FailureRecord.assertion(String assertionId, String message, int t,
          {String Function(String text)? scrub}) =>
      FailureRecord(
        kind: FailureKind.assertion,
        signature: FailureSignature.compute(FailureKind.assertion, assertionId, ''),
        type: assertionId,
        message: _truncate(scrub == null ? message : scrub(message), 2000),
        assertionId: assertionId,
        t: t,
      );

  /// `toString` of app objects can throw; a failure must still be recorded.
  static String _safeToString(Object error) {
    try {
      return error.toString();
    } catch (_) {
      return 'Instance of ${error.runtimeType}';
    }
  }

  factory FailureRecord.fromJson(Map<String, Object?> json) => FailureRecord(
        kind: FailureKind.values.byName(json['kind'] as String),
        signature: json['signature'] as String,
        type: json['type'] as String,
        message: json['message'] as String? ?? '',
        stack: json['stack'] as String?,
        assertionId: json['assertionId'] as String?,
        t: json['t'] as int? ?? 0,
      );

  final FailureKind kind;
  final String signature;
  final String type;
  final String message;
  final String? stack;
  final String? assertionId;
  final int t;

  FailureRecord shift(int offsetMs) => FailureRecord(
        kind: kind,
        signature: signature,
        type: type,
        message: message,
        stack: stack,
        assertionId: assertionId,
        t: t - offsetMs,
      );

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'signature': signature,
        'type': type,
        'message': message,
        'stack': stack,
        'assertionId': assertionId,
        't': t,
      };

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}

abstract final class FailureSignature {
  static final _hex = RegExp(r'\b(0x)?[0-9a-fA-F]{8,}\b');
  static final _digits = RegExp(r'\d+');
  static final _space = RegExp(r'\s+');

  /// `<kind>:<type>:<normalized message>` — see capsule spec v1.
  static String compute(FailureKind kind, String type, String message) {
    final firstLine = message.split('\n').first;
    var normalized = firstLine
        .replaceAll(_hex, '#')
        .replaceAll(_digits, '#')
        .replaceAll(_space, ' ')
        .trim();
    if (normalized.length > 200) normalized = normalized.substring(0, 200);
    return '${kind.name}:$type:$normalized';
  }
}
