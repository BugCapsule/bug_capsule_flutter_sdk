import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'capsule.dart';
import 'event.dart';
import 'flight_recorder.dart';
import 'redaction.dart';

/// Building blocks shared by HTTP client integrations (Dio, package:http):
/// body decoding and encoding for `http` events, and the streaming helpers
/// that keep a bounded prefix of a body without buffering it.
abstract final class HttpBodies {
  static bool isMultipart(String? contentType) =>
      (contentType ?? '').toLowerCase().startsWith('multipart/');

  static bool isText(String type) =>
      type.contains('json') ||
      type.startsWith('text/') ||
      type.contains('xml') ||
      type.contains('x-www-form-urlencoded') ||
      type.isEmpty;

  /// Decodes a complete body for keying and storage: redacted JSON, form
  /// fields, scrubbed text, or small binary as base64. Returns the body and
  /// its encoding (see the `http` event in the capsule spec).
  static (Object?, String) decode(
    List<int> bytes,
    String? contentType,
    Redactor redactor, {
    required int maxBinaryBytes,
  }) {
    if (bytes.isEmpty) return (null, 'json');
    final type = (contentType ?? '').toLowerCase();
    (Object?, String) binary() =>
        bytes.length > maxBinaryBytes ? (null, 'truncated') : (base64Encode(bytes), 'base64');
    if (isText(type)) {
      final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        return binary();
      }
      if (type.contains('json') || type.isEmpty) {
        try {
          return (redactor.redactJson(jsonDecode(text)), 'json');
        } on FormatException {
          return (redactor.scrubText(text), 'text');
        }
      }
      if (type.contains('x-www-form-urlencoded')) {
        try {
          return (redactor.redactJson(Uri.splitQueryString(text)), 'form');
        } on Object {
          return (redactor.scrubText(text), 'text'); // malformed escapes
        }
      }
      return (redactor.scrubText(text), 'text');
    }
    return binary();
  }

  /// The bytes replay serves for a recorded body.
  static List<int> encode(Object? body, String encoding) => switch (encoding) {
        'json' => body == null ? const [] : utf8.encode(jsonEncode(body)),
        'text' => utf8.encode(body as String? ?? ''),
        'form' => utf8.encode(Uri(queryParameters: (body as Map).cast<String, String>()).query),
        'base64' => base64Decode(body as String),
        _ => const [],
      };

  /// Response headers replay can serve as recorded: length and transfer
  /// encodings described the original bytes, not the re-encoded body.
  static Map<String, String> replayHeaders(Map<String, String> recorded) => {
        for (final e in recorded.entries)
          if (e.key != 'content-length' && e.key != 'content-encoding' && e.key != 'transfer-encoding')
            e.key: e.value,
      };

  static final _occurrences = Expando<Map<String, int>>('bugcapsule.httpOccurrences');

  /// The 0-based count of earlier requests with [key] in [session]. Shared
  /// by every HTTP integration of the session, so requests sent through
  /// different clients are numbered in one order, as replay serves them.
  static int nextOccurrence(Object session, String key) =>
      (_occurrences[session] ??= {}).update(key, (n) => n + 1, ifAbsent: () => 0);

  /// Reports recorded responses without a body: the capsule is then partial.
  static void describeEligibility(EligibilityBuilder eligibility, RecordedWindow window) {
    final missing = window.events.where((e) =>
        e.type == EventTypes.http &&
        e.data['error'] == null &&
        (e.data['bodyEncoding'] == 'omitted' || e.data['bodyEncoding'] == 'truncated'));
    if (missing.isNotEmpty) {
      eligibility.missing('network.bodies',
          '${missing.length} recorded responses have no body (capture disabled, excluded or too large)');
    }
  }
}

/// Passes a byte stream through unchanged while keeping its first [limit]
/// bytes. Pause, resume and cancel reach the source; errors reach the
/// listener. [complete] turns true when the source is done.
class BodyTap<T extends List<int>> {
  BodyTap(Stream<T> source, this.limit, {this.onDone, this.onError, this.onCancel, this.onOverflow}) {
    late final StreamSubscription<T> sub;
    _controller = StreamController<T>(
      sync: true,
      onListen: () {
        sub = source.listen(
          (chunk) {
            _seen += chunk.length;
            if (_retained != null) {
              if (_retained!.length + chunk.length <= limit) {
                _retained!.add(chunk);
              } else {
                _retained = null;
                _guard(onOverflow);
              }
            }
            _controller.add(chunk);
          },
          onError: (Object e, StackTrace st) {
            _guard(() => onError?.call(e));
            _controller.addError(e, st);
          },
          onDone: () {
            complete = true;
            _guard(onDone);
            unawaited(_controller.close());
          },
        );
      },
      onPause: () => sub.pause(),
      onResume: () => sub.resume(),
      onCancel: () {
        if (!complete) _guard(onCancel);
        return sub.cancel();
      },
    );
  }

  /// Recording bugs must never stop the app's bytes from flowing.
  static void _guard(void Function()? callback) {
    try {
      callback?.call();
    } catch (_) {}
  }

  final int limit;
  final void Function()? onDone;
  final void Function(Object error)? onError;
  final void Function()? onCancel;
  final void Function()? onOverflow;
  late final StreamController<T> _controller;
  BytesBuilder? _retained = BytesBuilder(copy: true);
  int _seen = 0;
  bool complete = false;

  Stream<T> get stream => _controller.stream;

  /// Bytes that went through so far.
  int get length => _seen;

  /// The retained prefix; the whole body when it fit in [limit].
  Uint8List get bytes => _retained?.toBytes() ?? Uint8List(0);

  bool overflowed(int max) => _retained == null || _seen > max;

  /// Stops retaining (the recording no longer needs the bytes).
  void release() => _retained = null;
}

/// The first `limit + 1` bytes of a request body, read before the request is
/// sent so its key does not depend on whether (or how far) the transport
/// reads the body. [stream] replays them followed by the rest, with pause,
/// resume, cancel and errors forwarded.
class PrefetchedBody<T extends List<int>> {
  PrefetchedBody._();

  static Future<PrefetchedBody<T>> read<T extends List<int>>(Stream<T> source, int limit) {
    final p = PrefetchedBody<T>._();
    final ready = Completer<PrefetchedBody<T>>();
    void settle() {
      if (!ready.isCompleted) ready.complete(p);
    }

    p._sub = source.listen(
      (chunk) {
        p._chunks.add(chunk);
        p.length += chunk.length;
        if (p.length > limit) {
          p._sub.pause();
          settle();
        }
      },
      onError: (Object e, StackTrace st) {
        p._error = (e, st);
        p._done = true;
        settle();
      },
      onDone: () {
        p._done = true;
        settle();
      },
      cancelOnError: true,
    );
    return ready.future;
  }

  late StreamSubscription<T> _sub;
  final List<T> _chunks = [];
  (Object, StackTrace)? _error;
  bool _done = false;
  int length = 0;

  /// The whole body arrived (no error) while prefetching.
  bool get complete => _done && _error == null;

  Uint8List get bytes {
    final b = BytesBuilder(copy: false);
    for (final c in _chunks) {
      b.add(c);
    }
    return b.takeBytes();
  }

  Stream<T> stream() {
    late final StreamController<T> out;
    out = StreamController<T>(
      onListen: () {
        for (final c in _chunks) {
          out.add(c);
        }
        if (_done) {
          final error = _error;
          if (error != null) out.addError(error.$1, error.$2);
          unawaited(out.close());
          return;
        }
        _sub
          ..onData(out.add)
          ..onError(out.addError)
          ..onDone(() => unawaited(out.close()))
          ..resume();
      },
      onPause: () => _sub.pause(),
      onResume: () => _sub.resume(),
      onCancel: () => _done ? null : _sub.cancel(),
    );
    return out.stream;
  }
}
