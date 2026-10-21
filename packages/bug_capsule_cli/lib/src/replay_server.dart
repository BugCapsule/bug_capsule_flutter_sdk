import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bug_capsule_core/bug_capsule_core.dart';

/// One armed attempt: the app gets [url] as `BUGCAPSULE_REPLAY_URL` and the
/// server answers only requests under it until [close].
class ArmedAttempt {
  ArmedAttempt._(this.token, this.attemptId, this.url, this.capsule, this.settings);

  final String token;
  final String attemptId;

  /// Base URL for the app: `http://127.0.0.1:<port>/a/<token>`.
  final String url;
  final List<int> capsule;

  /// The settings served to the app (with [attemptId]).
  final ReplaySettings settings;
  final Completer<ReplayReport> _report = Completer();
  bool _closed = false;

  /// Completes with the first accepted report.
  Future<ReplayReport> get report => _report.future;
  bool get isClosed => _closed;

  /// Ends the attempt: later requests and reports for it are rejected (410).
  void close() => _closed = true;

  /// Accepts [r] when the attempt is open and [r] belongs to it. Returns the
  /// HTTP status the app gets.
  int _offer(ReplayReport r) {
    if (_closed || _report.isCompleted) return HttpStatus.gone;
    if (r.attemptId != null && r.attemptId != attemptId) return HttpStatus.conflict;
    _report.complete(r);
    _closed = true;
    return HttpStatus.noContent;
  }
}

/// Serves the capsule and settings to the app under replay and collects its
/// [ReplayReport] (replay protocol v1.1, `spec/runtimes-v1.md`).
///
/// * Every attempt gets a fresh random token in its base URL and a fresh
///   `attemptId`; only the armed attempt is answered (404 otherwise), and a
///   report after the attempt closed is rejected with 410, so a late report
///   from a killed attempt never counts for the next one.
/// * Binds loopback unless [start] is called with `lan: true`.
/// * Refuses requests with an `Origin` header (403): browsers never talk to
///   this server; the web runner relays from Node.
class ReplayServer {
  ReplayServer._(this._server, this.host);

  static Future<ReplayServer> start({bool lan = false}) async {
    final server = await HttpServer.bind(lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, 0);
    final s = ReplayServer._(server, lan ? await _lanAddress() : '127.0.0.1');
    server.listen(s._handle, onError: (Object _) {});
    return s;
  }

  /// First non-loopback IPv4 address (physical devices on the same network).
  static Future<String> _lanAddress() async {
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (!a.isLoopback) return a.address;
      }
    }
    return '127.0.0.1';
  }

  final HttpServer _server;

  /// Host the app should use to reach this server.
  final String host;
  ArmedAttempt? _current;
  final Random _random = Random.secure();

  int get port => _server.port;

  /// The attempt currently armed, if any.
  ArmedAttempt? get current => _current;

  /// Arms the server for one attempt (closing any previous one).
  ArmedAttempt arm(List<int> capsule, ReplaySettings settings) {
    _current?.close();
    final token = _randomToken();
    final attemptId = uuidV4();
    final armed = ArmedAttempt._(
      token,
      attemptId,
      'http://$host:$port/a/$token',
      capsule,
      ReplaySettings(
        strategy: settings.strategy,
        settleTimeoutMs: settings.settleTimeoutMs,
        attempt: settings.attempt,
        kind: settings.kind,
        strictNetwork: settings.strictNetwork,
        idleCompression: settings.idleCompression,
        attemptId: attemptId,
        runtime: settings.runtime,
      ),
    );
    return _current = armed;
  }

  String _randomToken() =>
      base64Url.encode(List<int>.generate(32, (_) => _random.nextInt(256))).replaceAll('=', '');

  /// Fallback channel: a `BUGCAPSULE_RESULT::{json}` line from the output of
  /// the process launched for [attempt] (stdout, instrumentation status, test
  /// log). Ignored once the attempt is closed.
  bool offerLine(ArmedAttempt attempt, String line) {
    final i = line.indexOf(ReplayProtocol.stdoutPrefix);
    if (i < 0) return false;
    try {
      final json = jsonDecode(line.substring(i + ReplayProtocol.stdoutPrefix.length).trim());
      return attempt._offer(ReplayReport.fromJson((json as Map).cast<String, Object?>())) ==
          HttpStatus.noContent;
    } catch (_) {
      return false;
    }
  }

  /// Compatibility with callers that do not track the attempt.
  void offerStdoutLine(String line) {
    final attempt = _current;
    if (attempt != null) offerLine(attempt, line);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.headers.value('origin') != null) {
        res.statusCode = HttpStatus.forbidden;
        return;
      }
      final segments = req.uri.pathSegments;
      final attempt = _current;
      if (segments.length != 3 || segments[0] != 'a' || attempt == null || !_sameToken(segments[1], attempt.token)) {
        res.statusCode = HttpStatus.notFound;
        return;
      }
      if (attempt.isClosed) {
        res.statusCode = HttpStatus.gone;
        return;
      }
      switch ((req.method, '/${segments[2]}')) {
        case ('GET', ReplayProtocol.capsulePath):
          res
            ..headers.contentType = ContentType.binary
            ..headers.set('cache-control', 'no-store')
            ..add(attempt.capsule);
        case ('GET', ReplayProtocol.settingsPath):
          res
            ..headers.contentType = ContentType.json
            ..headers.set('cache-control', 'no-store')
            ..write(jsonEncode(attempt.settings.toJson()));
        case ('POST', ReplayProtocol.resultPath):
          final body = await utf8.decodeStream(req).timeout(const Duration(seconds: 30));
          if (body.length > 16 * 1024 * 1024) {
            res.statusCode = HttpStatus.requestEntityTooLarge;
            return;
          }
          res.statusCode = attempt._offer(ReplayReport.fromJson((jsonDecode(body) as Map).cast<String, Object?>()));
        default:
          res.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      res.statusCode = HttpStatus.badRequest;
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  static bool _sameToken(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> close() async {
    _current?.close();
    await _server.close(force: true);
  }
}
