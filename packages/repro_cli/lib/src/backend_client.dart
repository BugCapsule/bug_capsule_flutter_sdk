import 'dart:convert';
import 'dart:io';

/// Stored at ~/.repro/config.json (mode 600).
class Credentials {
  const Credentials({required this.url, this.secretKey, this.ingestKey});

  factory Credentials.fromJson(Map<String, Object?> j) => Credentials(
        url: j['url'] as String,
        secretKey: j['secretKey'] as String?,
        ingestKey: j['ingestKey'] as String?,
      );

  final String url;
  final String? secretKey;
  final String? ingestKey;

  Map<String, Object?> toJson() => {'url': url, 'secretKey': secretKey, 'ingestKey': ingestKey};

  static File get file {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return File('$home/.repro/config.json');
  }

  /// Environment variables win over the file: REPRO_URL, REPRO_SECRET_KEY,
  /// REPRO_INGEST_KEY.
  static Credentials? load() {
    final env = Platform.environment;
    Credentials? fromFile;
    if (file.existsSync()) {
      fromFile = Credentials.fromJson(
          (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>());
    }
    final url = env['REPRO_URL'] ?? fromFile?.url;
    if (url == null) return null;
    return Credentials(
      url: url,
      secretKey: env['REPRO_SECRET_KEY'] ?? fromFile?.secretKey,
      ingestKey: env['REPRO_INGEST_KEY'] ?? fromFile?.ingestKey,
    );
  }

  void save() {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
    if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
  }
}

class ApiException implements Exception {
  ApiException(this.status, this.code, this.detail);
  final int status;
  final String code;
  final String detail;
  @override
  String toString() => 'HTTP $status $code${detail.isEmpty ? '' : ': $detail'}';
}

class BackendClient {
  BackendClient(this.credentials);

  final Credentials credentials;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(credentials.url.replaceAll(RegExp(r'/+$'), ''));
    return base.replace(path: '${base.path}$path', queryParameters: query);
  }

  String _key({bool ingest = false}) {
    final key = ingest ? credentials.ingestKey : credentials.secretKey;
    if (key == null) {
      throw StateError(
          'no ${ingest ? 'ingest' : 'secret'} key; run `repro login` or set REPRO_${ingest ? 'INGEST' : 'SECRET'}_KEY');
    }
    return key;
  }

  Future<(int, List<int>, HttpHeaders)> _send(
    String method,
    Uri uri, {
    Object? json,
    List<int>? bytes,
    bool ingest = false,
    bool auth = true,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl(method, uri);
      if (auth) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${_key(ingest: ingest)}');
      if (json != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(json));
      } else if (bytes != null) {
        req.headers.contentType = ContentType.binary;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close();
      final body = <int>[];
      await for (final chunk in res) {
        body.addAll(chunk);
      }
      if (res.statusCode >= 400) {
        Map<String, Object?>? problem;
        try {
          problem = (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
        } catch (_) {}
        throw ApiException(res.statusCode, problem?['code'] as String? ?? 'error',
            problem?['detail'] as String? ?? problem?['title'] as String? ?? '');
      }
      return (res.statusCode, body, res.headers);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _json(String method, String path,
      {Object? body, Map<String, String>? query}) async {
    final (_, bytes, _) = await _send(method, _uri(path, query), json: body);
    if (bytes.isEmpty) return const {};
    return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> project() => _json('GET', '/v1/project');

  Future<Map<String, Object?>> listCapsules(Map<String, String> query) =>
      _json('GET', '/v1/capsules', query: query);

  Future<Map<String, Object?>> getCapsule(String id) => _json('GET', '/v1/capsules/$id');

  Future<List<int>> downloadCapsule(String id) async {
    final (_, bytes, _) = await _send('GET', _uri('/v1/capsules/$id/file'));
    return bytes;
  }

  Future<List<int>> downloadShared(Uri url) async {
    final (_, bytes, _) = await _send('GET', url, auth: false);
    return bytes;
  }

  Future<Map<String, Object?>> upload(List<int> bytes) async {
    final (_, body, _) = await _send('POST', _uri('/v1/capsules'), bytes: bytes, ingest: true);
    return (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> createRun(String id, Map<String, Object?> run) =>
      _json('POST', '/v1/capsules/$id/runs', body: run);

  Future<Map<String, Object?>> share(String id, int hours) =>
      _json('POST', '/v1/capsules/$id/share', body: {'expiresInHours': hours});

  Future<Map<String, Object?>> updateCapsule(String id, Map<String, Object?> patch) =>
      _json('PATCH', '/v1/capsules/$id', body: patch);

  Future<Map<String, Object?>> updateConfig(Map<String, Object?> patch) =>
      _json('PATCH', '/v1/project/config', body: patch);
}
