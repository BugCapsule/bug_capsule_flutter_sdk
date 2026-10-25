import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/core.dart';

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
  final res = await Process.run('flutter', [
    'devices',
    '--machine',
  ], runInShell: true);
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
}) async {
  final p = await Processes.start(
    exe,
    args,
    workingDirectory: workingDirectory,
    runInShell: true,
  );
  final out = StringBuffer();
  final subs = [
    p.stdout.transform(utf8.decoder).listen((s) {
      out.write(s);
      if (verbose) stdout.write(s);
    }),
    p.stderr.transform(utf8.decoder).listen((s) {
      out.write(s);
      if (verbose) stderr.write(s);
    }),
  ];
  final code = await p.exitCode;
  for (final s in subs) {
    await s.cancel();
  }
  if (code != 0) {
    if (!verbose) stderr.write(out);
    throw StateError(
      '${label ?? '$exe ${args.join(' ')}'} failed (exit $code)',
    );
  }
}

/// iOS simulator: build the debug .app once, install it, then launch it per
/// attempt with `SIMCTL_CHILD_BUGCAPSULE_REPLAY_URL` so no rebuild is needed.
class IosSimulatorLauncher implements AppLauncher {
  IosSimulatorLauncher(this.options);

  @override
  final LaunchOptions options;
  late String _bundleId;

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
    final plist = await Process.run('plutil', [
      '-extract',
      'CFBundleIdentifier',
      'raw',
      '${app.path}/Info.plist',
    ]);
    _bundleId = '${plist.stdout}'.trim();
    await _run(
      'xcrun',
      ['simctl', 'install', _udid, app.path],
      verbose: options.verbose,
      label: 'simctl install',
    );
  }

  @override
  Future<ReplayReport> attempt(
    ReplayServer server,
    List<int> capsule,
    ReplaySettings settings,
    Duration timeout,
  ) async {
    final armed = server.arm(capsule, settings);
    try {
      await Process.run('xcrun', ['simctl', 'terminate', _udid, _bundleId]);
      await _writeReplayRequest(armed.url);
      final launch = await Process.run('xcrun', [
        'simctl',
        'launch',
        _udid,
        _bundleId,
      ]);
      if (launch.exitCode != 0) {
        throw StateError('simctl launch failed: ${launch.stderr}');
      }
      return await armed.report.timeout(
        timeout,
        onTimeout: () => _timeoutReport(
          armed.settings,
          'no result within ${timeout.inSeconds}s',
        ),
      );
    } finally {
      armed.close();
      await Process.run('xcrun', ['simctl', 'terminate', _udid, _bundleId]);
    }
  }

  /// Drops `replay_request.json` into the app's data container; the SDK
  /// reads and deletes it on the next launch (debug builds only).
  Future<void> _writeReplayRequest(String url) async {
    final res = await Process.run('xcrun', [
      'simctl',
      'get_app_container',
      _udid,
      _bundleId,
      'data',
    ]);
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
    final exited = process.exitCode.then(
      (code) => _timeoutReport(
        settings,
        'flutter run exited ($code) before reporting:\n${_tail(log.toString())}',
      ),
    );
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
