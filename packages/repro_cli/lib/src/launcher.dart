import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:repro_core/repro_core.dart';

import 'replay_server.dart';
import 'term.dart';

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
  final res = await Process.run('flutter', ['devices', '--machine'], runInShell: true);
  final out = '${res.stdout}';
  final start = out.indexOf('[');
  if (res.exitCode != 0 || start < 0) {
    throw StateError('`flutter devices` failed: ${res.stderr}');
  }
  return [
    for (final d in jsonDecode(out.substring(start)) as List)
      if ((d as Map)['isSupported'] != false)
        Device('${d['id']}', '${d['name']}', '${d['targetPlatform']}'.replaceAll('_', '-'),
            d['emulator'] == true),
  ];
}

/// Picks [query] (id or name substring), else the first simulator/emulator.
Future<Device> pickDevice(String? query) async {
  final devices = (await listDevices())
      .where((d) => d.platform == 'ios' || d.isAndroid)
      .toList();
  if (devices.isEmpty) {
    throw StateError('no iOS simulator or Android emulator running; boot one first');
  }
  if (query != null) {
    final q = query.toLowerCase();
    return devices.firstWhere(
      (d) => d.id.toLowerCase() == q || d.name.toLowerCase().contains(q),
      orElse: () => throw StateError(
          'no device matches "$query". Running: ${devices.join(', ')}'),
    );
  }
  return devices.firstWhere((d) => d.emulator, orElse: () => devices.first);
}

class LaunchOptions {
  const LaunchOptions({
    required this.projectDir,
    required this.target,
    required this.device,
    required this.dartDefines,
    this.flavor,
    this.verbose = false,
  });

  final String projectDir;
  final String target;
  final Device device;
  final Map<String, String> dartDefines;
  final String? flavor;
  final bool verbose;

  List<String> get defineArgs => [
        for (final e in dartDefines.entries) '--dart-define=${e.key}=${e.value}',
        if (flavor != null) ...['--flavor', flavor!],
      ];
}

/// Starts the app in replay mode once per attempt.
abstract class AppLauncher {
  static AppLauncher forOptions(LaunchOptions options) => options.device.isIosSimulator
      ? IosSimulatorLauncher(options)
      : FlutterRunLauncher(options);

  LaunchOptions get options;

  /// Builds and installs once.
  Future<void> prepare(ReplayServer server);

  Future<ReplayReport> attempt(
      ReplayServer server, List<int> capsule, ReplaySettings settings, Duration timeout);

  Future<void> dispose();
}

ReplayReport _timeoutReport(ReplaySettings settings, String message) => ReplayReport(
      outcome: ReplayOutcome.error,
      attempt: settings.attempt,
      durationMs: 0,
      strategy: settings.strategy,
      message: message,
    );

Future<void> _run(String exe, List<String> args,
    {String? workingDirectory, required bool verbose, String? label}) async {
  final p = await Process.start(exe, args, workingDirectory: workingDirectory, runInShell: true);
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
    throw StateError('${label ?? '$exe ${args.join(' ')}'} failed (exit $code)');
  }
}

/// iOS simulator: build the debug .app once, install it, then launch it per
/// attempt with `SIMCTL_CHILD_REPRO_REPLAY_URL` so no rebuild is needed.
class IosSimulatorLauncher implements AppLauncher {
  IosSimulatorLauncher(this.options);

  @override
  final LaunchOptions options;
  late String _bundleId;

  String get _udid => options.device.id;

  @override
  Future<void> prepare(ReplayServer server) async {
    final progress = Progress('Building ${options.target} for the simulator');
    try {
      await _run(
        'flutter',
        ['build', 'ios', '--simulator', '--debug', '-t', options.target, ...options.defineArgs],
        workingDirectory: options.projectDir,
        verbose: options.verbose,
        label: 'flutter build ios --simulator',
      );
      progress.done();
    } catch (_) {
      progress.fail();
      rethrow;
    }
    final productsDir = Directory('${options.projectDir}/build/ios/iphonesimulator');
    final app = productsDir
        .listSync()
        .whereType<Directory>()
        .firstWhere((d) => d.path.endsWith('.app'),
            orElse: () => throw StateError('no .app found in ${productsDir.path}'));
    final plist = await Process.run(
        'plutil', ['-extract', 'CFBundleIdentifier', 'raw', '${app.path}/Info.plist']);
    _bundleId = '${plist.stdout}'.trim();
    await _run('xcrun', ['simctl', 'install', _udid, app.path],
        verbose: options.verbose, label: 'simctl install');
  }

  @override
  Future<ReplayReport> attempt(
      ReplayServer server, List<int> capsule, ReplaySettings settings, Duration timeout) async {
    final result = server.arm(capsule, settings);
    await Process.run('xcrun', ['simctl', 'terminate', _udid, _bundleId]);
    final launch = await Process.run(
      'xcrun',
      ['simctl', 'launch', _udid, _bundleId],
      environment: {
        'SIMCTL_CHILD_${ReplayProtocol.envUrl}': 'http://127.0.0.1:${server.port}',
      },
    );
    if (launch.exitCode != 0) {
      throw StateError('simctl launch failed: ${launch.stderr}');
    }
    try {
      return await result.timeout(timeout,
          onTimeout: () => _timeoutReport(settings, 'no result within ${timeout.inSeconds}s'));
    } finally {
      await Process.run('xcrun', ['simctl', 'terminate', _udid, _bundleId]);
    }
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
  Future<void> prepare(ReplayServer server) async {
    if (options.device.isAndroid) {
      // Lets the emulator reach the host's loopback replay server.
      await _run('adb', ['-s', options.device.id, 'reverse', 'tcp:${server.port}', 'tcp:${server.port}'],
          verbose: options.verbose, label: 'adb reverse');
    }
  }

  @override
  Future<ReplayReport> attempt(
      ReplayServer server, List<int> capsule, ReplaySettings settings, Duration timeout) async {
    final result = server.arm(capsule, settings);
    final process = await Process.start(
      'flutter',
      [
        'run',
        '-d',
        options.device.id,
        '--debug',
        '-t',
        options.target,
        '--dart-define=${ReplayProtocol.envUrl}=http://127.0.0.1:${server.port}',
        ...options.defineArgs,
      ],
      workingDirectory: options.projectDir,
      runInShell: true,
    );
    final log = StringBuffer();
    void onLine(String line) {
      log.writeln(line);
      if (options.verbose) stdout.writeln(line);
      server.offerStdoutLine(line);
    }

    final subs = [
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine),
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine),
    ];
    final exited = process.exitCode.then((code) => _timeoutReport(
        settings, 'flutter run exited ($code) before reporting:\n${_tail(log.toString())}'));
    try {
      // Build time counts against the timeout here.
      return await Future.any([result, exited])
          .timeout(timeout + const Duration(minutes: 3),
              onTimeout: () => _timeoutReport(settings, 'no result in time'));
    } finally {
      process.stdin.writeln('q');
      await process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
        process.kill();
        return -1;
      });
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
