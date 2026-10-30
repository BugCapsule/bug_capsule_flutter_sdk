import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/core.dart';

import 'crash_detection.dart';
import 'launchers/android.dart';
import 'launchers/ios.dart';
import 'launchers/web.dart';
import 'processes.dart';
import 'project_config.dart';
import 'replay_server.dart';
import 'term.dart';

/// Resolve adb as Flutter does on a standard SDK install, even without PATH setup.
String resolveAndroidAdb(
  String projectDir, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final candidates = <String?>[env['ANDROID_HOME'], env['ANDROID_SDK_ROOT']];
  final properties = File('$projectDir/android/local.properties');
  if (properties.existsSync()) {
    for (final line in properties.readAsLinesSync()) {
      if (line.startsWith('sdk.dir=')) {
        candidates.add(
          line
              .substring(8)
              .trim()
              .replaceAll(r'\:', ':')
              .replaceAll(r'\\', r'\'),
        );
      }
    }
  }
  if (env['HOME'] != null) {
    candidates.addAll([
      '${env['HOME']}/Library/Android/sdk',
      '${env['HOME']}/Android/Sdk',
    ]);
  }
  final name = Platform.isWindows ? 'adb.exe' : 'adb';
  for (final sdk in candidates) {
    if (sdk != null && File('$sdk/platform-tools/$name').existsSync()) {
      return '$sdk/platform-tools/$name';
    }
  }
  return name;
}

class Device {
  const Device(this.id, this.name, this.platform, this.emulator);

  final String id;
  final String name;

  /// `ios`, `android-arm64`, `darwin`, ...
  final String platform;
  final bool emulator;

  bool get isIosSimulator => platform == 'ios' && emulator;
  bool get isAndroid => platform.startsWith('android');

  @override
  String toString() => '$name ($id)';
}

Future<List<Device>> listDevices() async {
  final res = await runCaptured('flutter', ['devices', '--machine'], runInShell: true);
  final out = '${res.stdout}';
  final start = out.indexOf('[');
  if (res.exitCode != 0 || start < 0) {
    throw StateError('`flutter devices` failed: ${res.stderr}');
  }
  return [
    for (final d in jsonDecode(out.substring(start)) as List)
      if ((d as Map)['isSupported'] != false)
        Device(
          '${d['id']}',
          '${d['name']}',
          '${d['targetPlatform']}'.replaceAll('_', '-'),
          d['emulator'] == true,
        ),
  ];
}

/// Picks [query] (id or name substring), else the first simulator/emulator.
Future<Device> pickDevice(String? query) async {
  final devices = (await listDevices())
      .where((d) => d.platform == 'ios' || d.isAndroid)
      .toList();
  if (devices.isEmpty) {
    throw StateError(
      'no iOS simulator or Android emulator running; boot one first',
    );
  }
  if (query != null) {
    final q = query.toLowerCase();
    return devices.firstWhere(
      (d) => d.id.toLowerCase() == q || d.name.toLowerCase().contains(q),
      orElse: () => throw StateError(
        'no device matches "$query". Running: ${devices.join(', ')}',
      ),
    );
  }
  return devices.firstWhere((d) => d.emulator, orElse: () => devices.first);
}

class LaunchOptions {
  const LaunchOptions({
    required this.projectDir,
    this.target = 'lib/main.dart',
    this.device,
    this.dartDefines = const {},
    this.flavor,
    this.verbose = false,
    this.runtime = 'flutter',
    this.config,
    this.deviceQuery,
    this.buildSha,
    this.dirty = false,
    this.artifacts = const {},
  });

  final String projectDir;
  final String target;

  /// The Flutter device (flutter runtime only; native launchers pick their
  /// device in [AppLauncher.prepare] from [deviceQuery]).
  final Device? device;
  final Map<String, String> dartDefines;
  final String? flavor;
  final bool verbose;

  /// `flutter`, `android`, `ios` or `web`.
  final String runtime;
  final ProjectConfig? config;

  /// `--device`: id or name substring.
  final String? deviceQuery;

  /// Commit the build is made from (embedded so the app can report it).
  final String? buildSha;
  final bool dirty;

  /// Prebuilt artifacts given on the command line, by name: `apk`,
  /// `test-apk`, `xctestrun`, `app-url`. When present the launcher skips its
  /// build and uses them as they are.
  final Map<String, String> artifacts;

  ProjectConfig get projectConfig => config ?? ProjectConfig.load(projectDir);

  List<String> get defineArgs => [
    for (final e in dartDefines.entries) '--dart-define=${e.key}=${e.value}',
    if (flavor != null) ...['--flavor', flavor!],
  ];
}

/// The build under test (verification.md §1): `<appId>@<version>+<build>`,
/// the form SDKs send in events, so a run says which release stopped (or
/// kept) reproducing.
class AppRelease {
  const AppRelease({required this.version, this.appId, this.build});

  final String? appId;
  final String version;
  final String? build;

  @override
  String toString() {
    final v = build == null || build!.isEmpty ? version : '$version+$build';
    final r = appId == null ? v : '$appId@$v';
    return r.length > 200 ? r.substring(0, 200) : r;
  }

  static final _pubspecVersion = RegExp(
    r'''^version:\s*['"]?([^\s'"#]+)''',
    multiLine: true,
  );

  /// The Flutter app's pubspec `version` (`1.5.0+60`), with [appId].
  static AppRelease? fromPubspec(String projectDir, {String? appId}) {
    final file = File('$projectDir/pubspec.yaml');
    if (!file.existsSync()) return null;
    final m = _pubspecVersion.firstMatch(file.readAsStringSync());
    if (m == null) return null;
    final parts = m[1]!.split('+');
    return AppRelease(
      appId: appId,
      version: parts.first,
      build: parts.length > 1 ? parts.sublist(1).join('+') : null,
    );
  }

  static final _gradleAppId = RegExp(
    r'''applicationId\s*=?\s*["']([^"']+)["']''',
  );
  static final _bundleId = RegExp(
    r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([^";\s]+)"?;',
  );

  /// The Flutter app's Android application id or iOS bundle id, from its
  /// `android/` or `ios/` project; null when not found.
  static String? flutterAppId(String projectDir, {required bool android}) {
    try {
      if (android) {
        for (final name in ['build.gradle.kts', 'build.gradle']) {
          final f = File('$projectDir/android/app/$name');
          if (!f.existsSync()) continue;
          final m = _gradleAppId.firstMatch(f.readAsStringSync());
          if (m != null) return m[1];
        }
        return null;
      }
      final f = File('$projectDir/ios/Runner.xcodeproj/project.pbxproj');
      if (!f.existsSync()) return null;
      return _bundleId
          .allMatches(f.readAsStringSync())
          .map((m) => m[1]!)
          .where((id) => !id.endsWith('Tests') && !id.contains(r'$'))
          .firstOrNull;
    } catch (_) {
      return null;
    }
  }

  /// `CFBundleShortVersionString`, `CFBundleVersion` and the bundle id of
  /// a built `.app`.
  static Future<AppRelease?> fromIosApp(String appPath) async {
    Future<String?> read(String key) async {
      final res = await runCaptured('plutil', [
        '-extract',
        key,
        'raw',
        '$appPath/Info.plist',
      ]);
      final v = '${res.stdout}'.trim();
      return res.exitCode == 0 && v.isNotEmpty ? v : null;
    }

    final version = await read('CFBundleShortVersionString');
    if (version == null) return null;
    return AppRelease(
      appId: await read('CFBundleIdentifier'),
      version: version,
      build: await read('CFBundleVersion'),
    );
  }
}

/// Starts the app in replay mode once per attempt.
///
/// Every attempt arms the [ReplayServer] ([ReplayServer.arm]), hands the
/// armed URL to the app, waits for the report within the timeout, and closes
/// the attempt so that a late report is rejected.
abstract class AppLauncher {
  static AppLauncher forOptions(LaunchOptions options) =>
      switch (options.runtime) {
        'android' => AndroidLauncher(options),
        'ios' => IosNativeLauncher(options),
        'web' => WebLauncher(options),
        _ =>
          options.device!.isIosSimulator
              ? IosSimulatorLauncher(options)
              : FlutterRunLauncher(options),
      };

  LaunchOptions get options;

  /// Human-readable target (device, simulator, browser) once prepared.
  String get target => options.device?.toString() ?? options.runtime;

  /// The build under test, once prepared; null when it cannot be read.
  AppRelease? get release;

  /// Builds and installs once.
  Future<void> prepare(ReplayServer server);

  Future<ReplayReport> attempt(
    ReplayServer server,
    List<int> capsule,
    ReplaySettings settings,
    Duration timeout,
  );

  Future<void> dispose();
}

/// An attempt that produced no report.
ReplayReport errorReport(ReplaySettings settings, String message) =>
    ReplayReport(
      outcome: ReplayOutcome.error,
      attempt: settings.attempt,
      durationMs: 0,
      strategy: settings.strategy,
      message: message,
      attemptId: settings.attemptId,
      runtime: settings.runtime,
    );

ReplayReport _timeoutReport(ReplaySettings settings, String message) =>
    errorReport(settings, message);

Future<void> _run(
  String exe,
  List<String> args, {
  String? workingDirectory,
  required bool verbose,
  String? label,
  Duration timeout = const Duration(minutes: 20),
}) async {
  await runChecked(exe, args, workingDirectory: workingDirectory,
    verbose: verbose, label: label, timeout: timeout, runInShell: true);
}

/// iOS simulator: build the debug .app once, install it, then launch it per
/// attempt with `SIMCTL_CHILD_BUGCAPSULE_REPLAY_URL` so no rebuild is needed.
class IosSimulatorLauncher implements AppLauncher {
  IosSimulatorLauncher(this.options);

  @override
  final LaunchOptions options;
  late String _bundleId;

  @override
  AppRelease? release;

  String get _udid => options.device!.id;

  @override
  String get target => options.device.toString();

  @override
  Future<void> prepare(ReplayServer server) async {
    final progress = Progress('Building ${options.target} for the simulator');
    try {
      await _run(
        'flutter',
        [
          'build',
          'ios',
          '--simulator',
          '--debug',
          '-t',
          options.target,
          ...options.defineArgs,
        ],
        workingDirectory: options.projectDir,
        verbose: options.verbose,
        label: 'flutter build ios --simulator',
        timeout: options.projectConfig.buildTimeout,
      );
      progress.done();
    } catch (_) {
      progress.fail();
      rethrow;
    }
    final productsDir = Directory(
      '${options.projectDir}/build/ios/iphonesimulator',
    );
    final app = productsDir.listSync().whereType<Directory>().firstWhere(
      (d) => d.path.endsWith('.app'),
      orElse: () => throw StateError('no .app found in ${productsDir.path}'),
    );
    final plist = await runCaptured('plutil', [
      '-extract',
      'CFBundleIdentifier',
      'raw',
      '${app.path}/Info.plist',
    ]);
    _bundleId = '${plist.stdout}'.trim();
    release = AppRelease.fromPubspec(options.projectDir, appId: _bundleId);
    await _run(
      'xcrun',
      ['simctl', 'install', _udid, app.path],
      verbose: options.verbose,
      label: 'simctl install',
      timeout: const Duration(seconds: 30),
    );
  }

  @override
  Future<ReplayReport> attempt(
    ReplayServer server,
    List<int> capsule,
    ReplaySettings settings,
    Duration timeout,
  ) async {
    final clock = Stopwatch()..start();
    Duration remaining() => remainingAttemptTime(clock, timeout);
    final armed = server.arm(capsule, settings);
    var finished = false;
    try {
      await runCaptured('xcrun', ['simctl', 'terminate', _udid, _bundleId], timeout: remaining());
      await _writeReplayRequest(armed.url, remaining());
      final started = DateTime.now();
      final launch = await runCaptured('xcrun', [
        'simctl',
        'launch',
        _udid,
        _bundleId,
      ], timeout: remaining());
      if (launch.exitCode != 0) {
        throw StateError('simctl launch failed: ${launch.stderr}');
      }
      // `<bundle id>: <pid>`; simulator apps are host processes.
      final pid = int.tryParse(
        RegExp(r':\s*(\d+)\s*$').firstMatch('${launch.stdout}'.trim())?[1] ??
            '',
      );
      final died = pid == null
          ? Completer<ReplayReport>().future
          : _whenDead(
              pid,
              () => finished,
            ).then((_) => _deathReport(armed, started));
      return await Future.any([armed.report, died]).timeout(
        remaining(),
        onTimeout: () => _timeoutReport(
          armed.settings,
          'no result within ${timeout.inSeconds}s',
        ),
      );
    } finally {
      finished = true;
      armed.close();
      await terminateSimulatorApp(_udid, _bundleId);
    }
  }

  /// Completes when process [pid] is gone (polled), or never once [stop].
  static Future<void> _whenDead(int pid, bool Function() stop) async {
    while (!stop()) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (stop()) break;
      final alive = await runCaptured('kill', ['-0', '$pid']);
      if (alive.exitCode != 0) return;
    }
    await Completer<void>().future;
  }

  /// The app died before reporting: the crash report says how (it lands a
  /// moment after the death).
  Future<ReplayReport> _deathReport(ArmedAttempt armed, DateTime since) async {
    // A report sent just before the exit wins.
    await Future<void>.delayed(const Duration(seconds: 1));
    ObservedCrash? crash;
    for (var i = 0; i < 10 && crash == null; i++) {
      crash = CrashDetection.findIosCrashReport(_bundleId, since: since);
      if (crash == null) await Future<void>.delayed(const Duration(seconds: 1));
    }
    return errorReport(
      armed.settings,
      'the app exited before reporting',
    ).copyWith(crash: crash ?? const ObservedCrash(source: 'process_exit'));
  }

  /// Drops `replay_request.json` into the app's data container; the SDK
  /// reads and deletes it on the next launch (debug builds only).
  Future<void> _writeReplayRequest(String url, Duration timeout) async {
    final res = await runCaptured('xcrun', [
      'simctl',
      'get_app_container',
      _udid,
      _bundleId,
      'data',
    ], timeout: timeout);
    if (res.exitCode != 0) {
      throw StateError('cannot locate app container: ${res.stderr}');
    }
    final dir = Directory(
      '${'${res.stdout}'.trim()}/Library/Application Support/bugcapsule',
    )..createSync(recursive: true);
    File('${dir.path}/replay_request.json').writeAsStringSync(
      jsonEncode({'url': url, 'createdAt': DateTime.now().toIso8601String()}),
    );
  }

  @override
  Future<void> dispose() async {}
}

/// Any device: `flutter run` per attempt with the replay URL as a
/// dart-define. Slower (an incremental build per attempt) but universal.
class FlutterRunLauncher implements AppLauncher {
  FlutterRunLauncher(this.options);

  @override
  final LaunchOptions options;

  @override
  AppRelease? get release => AppRelease.fromPubspec(
    options.projectDir,
    appId: AppRelease.flutterAppId(
      options.projectDir,
      android: options.device?.isAndroid ?? true,
    ),
  );

  @override
  String get target => options.device.toString();

  @override
  Future<void> prepare(ReplayServer server) async {
    final device = options.device!;
    if (device.isAndroid) {
      // Lets the emulator reach the host's loopback replay server.
      final adb = resolveAndroidAdb(options.projectDir);
      await _run(
        adb,
        [
          '-s',
          device.id,
          'reverse',
          'tcp:${server.port}',
          'tcp:${server.port}',
        ],
        verbose: options.verbose,
        label: 'adb reverse',
      );
      Processes.onCleanup(() async {
        await Process.run(adb, [
          '-s',
          device.id,
          'reverse',
          '--remove',
          'tcp:${server.port}',
        ]);
      });
    }
  }

  @override
  Future<ReplayReport> attempt(
    ReplayServer server,
    List<int> capsule,
    ReplaySettings settings,
    Duration timeout,
  ) async {
    final armed = server.arm(capsule, settings);
    final result = armed.report;
    final process = await Processes.start(
      'flutter',
      [
        'run',
        '-d',
        options.device!.id,
        '--debug',
        '-t',
        options.target,
        '--dart-define=${ReplayProtocol.envUrl}=${armed.url}',
        ...options.defineArgs,
      ],
      workingDirectory: options.projectDir,
      runInShell: true,
    );
    final log = StringBuffer();
    void onLine(String line) {
      log.writeln(line);
      if (options.verbose) stdout.writeln(line);
      server.offerLine(armed, line);
    }

    final subs = [
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onLine),
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onLine),
    ];
    final exited = process.exitCode.then((code) async {
      // A report sent just before the exit wins.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final report = _timeoutReport(
        settings,
        'flutter run exited ($code) before reporting:\n${_tail(log.toString())}',
      );
      final crash = CrashDetection.fromFlutterRun(log.toString());
      return crash == null ? report : report.copyWith(crash: crash);
    });
    try {
      // Build time counts against the timeout here.
      return await Future.any([result, exited]).timeout(
        timeout + const Duration(minutes: 3),
        onTimeout: () => _timeoutReport(settings, 'no result in time'),
      );
    } finally {
      armed.close();
      process.stdin.writeln('q');
      await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  static String _tail(String s) {
    final lines = s.trimRight().split('\n');
    return lines.skip(lines.length > 30 ? lines.length - 30 : 0).join('\n');
  }

  @override
  Future<void> dispose() async {}
}
