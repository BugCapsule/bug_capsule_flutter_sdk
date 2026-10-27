import 'dart:convert';
import 'dart:io';

/// Stored at ~/.bugcapsule/config.json (mode 600).
class Credentials {
  const Credentials({
    required this.url,
    this.secretKey,
    this.ingestKey,
    this.token,
  });

  factory Credentials.fromJson(Map<String, Object?> j) => Credentials(
    url: j['url'] as String,
    secretKey: j['secretKey'] as String?,
    ingestKey: j['ingestKey'] as String?,
    token: j['token'] as String?,
  );

  final String url;

  /// Legacy: the project's shared secret key (bcs_), full access to the project.
  final String? secretKey;
  final String? ingestKey;

  /// A personal (bcp_) or service (bcv_) token from the dashboard's
  /// Keys & CLI access page: bound to one project, scoped, expiring and
  /// revocable on its own. Preferred over [secretKey] when both are set.
  final String? token;

  /// What project requests are authorized with.
  String? get projectCredential => token ?? secretKey;

  Map<String, Object?> toJson() => {
    'url': url,
    if (token != null) 'token': token,
    if (secretKey != null) 'secretKey': secretKey,
    'ingestKey': ingestKey,
  };

  /// Personal and service tokens; anything else is a legacy key.
  static bool isToken(String value) =>
      value.startsWith('bcp_') || value.startsWith('bcv_');

  static File get file {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return File('$home/.bugcapsule/config.json');
  }

  /// What `bugcapsule login` saved, without the environment; null when nothing is.
  static Credentials? loadFile() {
    if (!file.existsSync()) return null;
    try {
      return Credentials.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
      );
    } on Object {
      return null;
    }
  }

  /// Environment variables win over the file: BUGCAPSULE_URL, BUGCAPSULE_TOKEN,
  /// BUGCAPSULE_SECRET_KEY, BUGCAPSULE_INGEST_KEY.
  static Credentials? load() {
    final env = Platform.environment;
    Credentials? fromFile;
    if (file.existsSync()) {
      fromFile = Credentials.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
      );
    }
    final url = env['BUGCAPSULE_URL'] ?? fromFile?.url;
    if (url == null) return null;
    return Credentials(
      url: url,
      secretKey: env['BUGCAPSULE_SECRET_KEY'] ?? fromFile?.secretKey,
      ingestKey: env['BUGCAPSULE_INGEST_KEY'] ?? fromFile?.ingestKey,
      token: env['BUGCAPSULE_TOKEN'] ?? fromFile?.token,
    );
  }

  void save() {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
    if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
  }
}

class ApiException implements Exception {
  ApiException(this.status, this.code, this.detail);
  final int status;
  final String code;
  final String detail;
  @override
  String toString() {
    final base = 'HTTP $status $code${detail.isEmpty ? '' : ': $detail'}';
    if (status == 401) {
      return '$base\nThe token or key was refused: it may be wrong, expired or revoked, or you were removed from the project. '
          'Run `bugcapsule login` to sign in again in the browser. On a machine without a browser, issue a personal token '
          '(Project Settings › Keys & CLI access) and run `bugcapsule login --url <backend> --token <token>`.';
    }
    if (status == 403) {
      return '$base\nYour role or this token’s scopes don’t allow it; ask a project admin.';
    }
    return base;
  }
}

class BackendClient {
  BackendClient(this.credentials);

  final Credentials credentials;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(credentials.url.replaceAll(RegExp(r'/+$'), ''));
    return base.replace(path: '${base.path}$path', queryParameters: query);
  }

  String _key({bool ingest = false}) {
    final key = ingest ? credentials.ingestKey : credentials.projectCredential;
    if (key == null) {
      throw StateError(
        ingest
            ? 'no ingest key; run `bugcapsule login --ingest-key ...` or set BUGCAPSULE_INGEST_KEY'
            : 'not signed in to a project; run `bugcapsule login` or set BUGCAPSULE_TOKEN',
      );
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
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl(method, uri);
      if (auth) {
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${_key(ingest: ingest)}',
        );
      }
      headers.forEach(req.headers.set);
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
          problem = (jsonDecode(utf8.decode(body)) as Map)
              .cast<String, Object?>();
        } catch (_) {}
        throw ApiException(
          res.statusCode,
          problem?['code'] as String? ?? 'error',
          problem?['detail'] as String? ?? problem?['title'] as String? ?? '',
        );
      }
      return (res.statusCode, body, res.headers);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final (_, bytes, _) = await _send(method, _uri(path, query), json: body);
    if (bytes.isEmpty) return const {};
    return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> project() => _json('GET', '/v1/project');

  Future<Map<String, Object?>> _unauthenticated(
    String path,
    Object body,
  ) async {
    final (_, bytes, _) = await _send(
      'POST',
      _uri(path),
      json: body,
      auth: false,
    );
    return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
  }

  /// Browser sign-in: starts a request the person approves in the dashboard.
  Future<Map<String, Object?>> startBrowserLogin(String clientName) =>
      _unauthenticated('/v1/console/cli/logins', {'clientName': clientName});

  /// Pending, denied or expired; or, once, the approved personal token.
  Future<Map<String, Object?>> pollBrowserLogin(String deviceCode) =>
      _unauthenticated('/v1/console/cli/logins/poll', {
        'deviceCode': deviceCode,
      });

  /// Revokes the personal token this client holds (`bugcapsule logout`).
  Future<void> revokeOwnToken() async {
    await _send('POST', _uri('/v1/console/cli/logout'));
  }

  Future<Map<String, Object?>> listCapsules(Map<String, String> query) =>
      _json('GET', '/v1/capsules', query: query);

  Future<Map<String, Object?>> getCapsule(String id) =>
      _json('GET', '/v1/capsules/$id');

  Future<List<int>> downloadCapsule(String id) async {
    final (_, bytes, _) = await _send('GET', _uri('/v1/capsules/$id/file'));
    return bytes;
  }

  Future<List<int>> downloadShared(Uri url) async {
    final (_, bytes, _) = await _send('GET', url, auth: false);
    return bytes;
  }

  Future<Map<String, Object?>> upload(List<int> bytes) async {
    final (_, body, _) = await _send(
      'POST',
      _uri('/v1/capsules'),
      bytes: bytes,
      ingest: true,
    );
    return (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> createRun(String id, Map<String, Object?> run) =>
      _json('POST', '/v1/capsules/$id/runs', body: run);

  /// `GET /v1/verification/plan` (verification.md §3.1).
  Future<Map<String, Object?>> verificationPlan({
    required String release,
    String? platform,
    String? scope,
    String? issue,
  }) => _json(
    'GET',
    '/v1/verification/plan',
    query: {
      'release': release,
      'platform': ?platform,
      'scope': ?scope,
      'issue': ?issue,
    },
  );

  /// `POST /v1/verification/reports` (verification.md §3.2).
  Future<Map<String, Object?>> createGateReport(Map<String, Object?> report) =>
      _json('POST', '/v1/verification/reports', body: report);

  Future<Map<String, Object?>> share(String id, int hours) =>
      _json('POST', '/v1/capsules/$id/share', body: {'expiresInHours': hours});

  Future<Map<String, Object?>> updateCapsule(
    String id,
    Map<String, Object?> patch,
  ) => _json('PATCH', '/v1/capsules/$id', body: patch);

  Future<Map<String, Object?>> updateConfig(Map<String, Object?> patch) =>
      _json('PATCH', '/v1/project/config', body: patch);

  /// `POST /v1/debug-files?kind=…` (monitoring-v1 §5.4), gzip-compressed.
  Future<Map<String, Object?>> uploadDebugFile(
    String kind,
    Map<String, String> query,
    List<int> file,
  ) async {
    final (_, body, _) = await _send(
      'POST',
      _uri('/v1/debug-files', {'kind': kind, ...query}),
      bytes: gzip.encode(file),
      headers: {HttpHeaders.contentEncodingHeader: 'gzip'},
    );
    if (body.isEmpty) return const {};
    return (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
  }
}
