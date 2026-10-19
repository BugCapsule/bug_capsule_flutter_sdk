import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:repro_core/repro_core.dart';

/// Serves the capsule and settings to the app under replay and collects its
/// [ReplayReport]. One server is reused across attempts and capsules.
class ReplayServer {
  ReplayServer._(this._server);

  static Future<ReplayServer> start({bool lan = false}) async {
    final server = await HttpServer.bind(
        lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, 0);
    final s = ReplayServer._(server);
    server.listen(s._handle);
    return s;
  }

  final HttpServer _server;
  List<int> _capsule = const [];
  ReplaySettings _settings = const ReplaySettings();
  Completer<ReplayReport>? _pending;

  int get port => _server.port;

  /// Arms the server for one attempt and returns the report future.
  Future<ReplayReport> arm(List<int> capsule, ReplaySettings settings) {
    _capsule = capsule;
    _settings = settings;
    final completer = _pending = Completer<ReplayReport>();
    return completer.future;
  }

  /// Fallback channel: a `REPRO_RESULT::{json}` line from the app's stdout.
  void offerStdoutLine(String line) {
    final i = line.indexOf(ReplayProtocol.stdoutPrefix);
    if (i < 0) return;
    try {
      final json = jsonDecode(line.substring(i + ReplayProtocol.stdoutPrefix.length));
      _complete(ReplayReport.fromJson((json as Map).cast<String, Object?>()));
    } catch (_) {}
  }

  void _complete(ReplayReport report) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(report);
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      switch ((req.method, req.uri.path)) {
        case ('GET', ReplayProtocol.capsulePath):
          req.response
            ..headers.contentType = ContentType.binary
            ..add(_capsule);
        case ('GET', ReplayProtocol.settingsPath):
          req.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(_settings.toJson()));
        case ('POST', ReplayProtocol.resultPath):
          final body = await utf8.decodeStream(req);
          _complete(ReplayReport.fromJson((jsonDecode(body) as Map).cast<String, Object?>()));
          req.response.statusCode = HttpStatus.noContent;
        default:
          req.response.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      req.response.statusCode = HttpStatus.badRequest;
    } finally {
      await req.response.close();
    }
  }

  Future<void> close() => _server.close(force: true);
}
