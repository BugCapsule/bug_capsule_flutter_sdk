import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule_core/bug_capsule_core.dart';

import '../launcher.dart';
import '../processes.dart';
import '../replay_server.dart';
import '../term.dart';

/// Web replay: builds and serves the app (or uses `--app-url`), then runs the
/// Playwright runner from `@bugcapsule/web-replay` once per attempt. Each
/// attempt gets a fresh browser context (attempt isolation); the runner
/// talks to the replay server from Node, never from the page.
///
/// `bugcapsule.json`:
/// ```json
/// {"runtime": "web", "web": {
///   "url": "http://127.0.0.1:4317/",
///   "installCommand": "npm ci", "installDir": ".",
///   "buildCommand": "npm run build",
///   "serveCommand": "npm run preview",
///   "readyTimeoutSeconds": 60,
///   "allowOrigins": ["https://fonts.example.com"],
///   "runner": "node_modules/.bin/bugcapsule-web-runner",
///   "headed": false,
///   "env": {"VITE_API_URL": "http://127.0.0.1:4318"}
/// }}
/// ```
/// The build gets `BUGCAPSULE_GIT_SHA` / `BUGCAPSULE_GIT_DIRTY` in its
/// environment; expose them to the app (e.g. Vite `define`) so the capsule
/// and the replay report carry the commit.
class WebLauncher implements AppLauncher {
  WebLauncher(this.options);

  @override
  final LaunchOptions options;

  late String _appUrl;
  late List<String> _runner;
  Process? _server;
  bool _startedServer = false;
  String _browser = 'chromium';

  Map<String, Object?> get _web => options.projectConfig.section('web');
  String? _s(String key) => options.projectConfig.string('web', key);

  @override
  String get target => '$_browser (Playwright) → $_appUrl';

  Map<String, String> get _env => {
        ...Platform.environment,
        for (final e in ((_web['env'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}',
        if (options.buildSha != null) 'BUGCAPSULE_GIT_SHA': options.buildSha!,
        if (options.buildSha != null) 'BUGCAPSULE_GIT_DIRTY': '${options.dirty}',
      };

  @override
  Future<void> prepare(ReplayServer server) async {
    final browser = _s('browser') ?? 'chromium';
    if (browser != 'chromium') {
      throw StateError('web.browser "$browser" is not supported yet; only chromium is implemented and tested');
    }
    _browser = browser;
    final given = options.artifacts['app-url'];
    if (given != null) {
      _runner = _resolveRunner();
      _appUrl = given;
      if (!await _responds(_appUrl)) throw StateError('--app-url $_appUrl does not respond');
      return;
    }
    _appUrl = _s('url') ?? 'http://127.0.0.1:4317/';
    final dir = options.projectDir;
    final install = _s('installCommand');
    if (install != null) {
      final installDir = Directory('$dir/${_s('installDir') ?? '.'}').absolute.path;
      if (!Directory('$installDir/node_modules').existsSync()) {
        final p = Progress('Installing dependencies ($install)');
        try {
          await runShell(install, workingDirectory: installDir, environment: _env, verbose: options.verbose, timeout: options.projectConfig.buildTimeout);
          p.done();
        } catch (_) {
          p.fail();
          rethrow;
        }
      }
    }
    // After the install: a pinned worktree has no node_modules before it.
    _runner = _resolveRunner();
    final build = _s('buildCommand');
    if (build != null) {
      final p = Progress('Building the web app ($build)');
      try {
        await runShell(build, workingDirectory: dir, environment: _env, verbose: options.verbose, timeout: options.projectConfig.buildTimeout);
        p.done();
      } catch (_) {
        p.fail();
        rethrow;
      }
    }
    final serve = _s('serveCommand');
    if (serve == null) {
      if (!await _responds(_appUrl)) throw StateError('web.url $_appUrl does not respond and no web.serveCommand is set');
      return;
    }
    if (await _responds(_appUrl)) {
      throw StateError('something already serves $_appUrl; stop it (it may be an old build) or pass --app-url to replay against it');
    }
    final p = Progress('Serving $_appUrl ($serve)');
    // `exec` so the signal on dispose reaches the server process itself.
    _server = await Processes.start('/bin/sh', ['-c', 'exec $serve'], workingDirectory: dir, environment: _env);
    _startedServer = true;
    final log = StringBuffer();
    _server!.stdout.transform(utf8.decoder).listen((s) {
      log.write(s);
      if (options.verbose) stdout.write(s);
    });
    _server!.stderr.transform(utf8.decoder).listen((s) {
      log.write(s);
      if (options.verbose) stderr.write(s);
    });
    final ready = Duration(seconds: (_web['readyTimeoutSeconds'] as int?) ?? 60);
    final deadline = DateTime.now().add(ready);
    var exited = false;
    unawaited(_server!.exitCode.then((_) => exited = true));
    while (!await _responds(_appUrl)) {
      if (exited) {
        p.fail();
        throw StateError('serve command exited before $_appUrl responded:\n${tail(log.toString())}');
      }
      if (DateTime.now().isAfter(deadline)) {
        p.fail();
        throw StateError('$_appUrl did not respond within ${ready.inSeconds}s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    p.done();
  }

  /// `web.runner` (a command), else the `@bugcapsule/web-replay` bin found
  /// in `node_modules` above the project.
  List<String> _resolveRunner() {
    final configured = _s('runner');
    if (configured != null) return ['/bin/sh', '-c', '$configured "\$@"', 'bugcapsule-web-runner'];
    var dir = Directory(options.projectDir).absolute;
    for (var i = 0; i < 8; i++) {
      final bin = File('${dir.path}/node_modules/@bugcapsule/web-replay/bin/bugcapsule-web-runner.js');
      if (bin.existsSync()) return ['node', bin.path];
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    throw StateError('@bugcapsule/web-replay is not installed in ${options.projectDir} '
        '(npm install -D @bugcapsule/web-replay) and no web.runner is configured');
  }

  static Future<bool> _responds(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final res = await (await client.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 5));
      await res.drain<void>();
      return res.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<ReplayReport> attempt(
      ReplayServer server, List<int> capsule, ReplaySettings settings, Duration timeout) async {
    final armed = server.arm(capsule, settings);
    Process? runner;
    try {
      final allow = [for (final o in (_web['allowOrigins'] as List?) ?? const []) '$o'];
      runner = await Processes.start(_runner.first, [
        ..._runner.skip(1),
        '--replay-url',
        armed.url,
        '--app-url',
        _appUrl,
        '--timeout',
        '${timeout.inSeconds}',
        for (final o in allow) ...['--allow-origin', o],
        if (_web['headed'] == true) '--headed',
      ], workingDirectory: options.projectDir, environment: _env);
      final log = StringBuffer();
      void onLine(String line) {
        log.writeln(line);
        if (!server.offerLine(armed, line) && options.verbose) stdout.writeln(dim(line));
      }

      final subs = [
        runner.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine),
        runner.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine),
      ];
      final exited = runner.exitCode.then((code) async {
        // Give a report that was posted just before exit a moment to land.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return errorReport(armed.settings, 'web runner exited ($code) before reporting:\n${tail(log.toString())}');
      });
      try {
        return await Future.any([armed.report, exited]).timeout(timeout + const Duration(seconds: 20),
            onTimeout: () => errorReport(armed.settings, 'no result within ${timeout.inSeconds}s'));
      } finally {
        for (final s in subs) {
          unawaited(s.cancel());
        }
      }
    } finally {
      armed.close();
      if (runner != null) await Processes.kill(runner);
    }
  }

  @override
  Future<void> dispose() async {
    final s = _server;
    _server = null;
    if (s != null) await Processes.kill(s);
    // A package-manager wrapper may leave the real server running: free the
    // port we started serving on (it was free before prepare).
    if (_startedServer && await _responds(_appUrl)) {
      final port = Uri.parse(_appUrl).port;
      final pids = await Process.run('lsof', ['-ti', 'tcp:$port', '-sTCP:LISTEN']);
      for (final pid in '${pids.stdout}'.split(RegExp(r'\s+')).where((p) => p.isNotEmpty)) {
        Process.killPid(int.parse(pid));
      }
    }
  }
}
