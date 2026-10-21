import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule_core/bug_capsule_core.dart';

import '../launcher.dart';
import '../processes.dart';
import '../replay_server.dart';
import '../term.dart';

/// Native iOS replay launcher (Swift SDK `bugcapsule-ios`, simulator only).
///
/// `prepare` picks and boots a simulator and runs `xcodebuild
/// build-for-testing` once (the git SHA is embedded through the
/// `BUGCAPSULE_GIT_SHA` / `BUGCAPSULE_GIT_DIRTY` build settings, which the
/// app's Info.plist forwards to the SDK). Each attempt uninstalls the app
/// (fresh data container), then runs
///
/// ```
/// xcodebuild test-without-building -xctestrun <file> -destination id=<udid>
///   -only-testing:<UITestTarget>/<Class>/<method>
/// ```
///
/// with `TEST_RUNNER_BUGCAPSULE_REPLAY_URL=<armed url>` in the environment
/// (xcodebuild strips the prefix for the test runner, whose
/// `BugCapsuleReplayTestCase` passes it to the app). The report arrives over
/// HTTP; `BUGCAPSULE_RESULT::` lines in the test output are the fallback.
/// xcodebuild is killed on timeout or interruption.
///
/// `bugcapsule.json`:
///
/// ```json
/// {"runtime": "ios",
///  "ios": {"project": "BugCapsuleDemo.xcodeproj", "scheme": "BugCapsuleDemo",
///          "replayTest": "BugCapsuleDemoUITests/BugCapsuleReplayTests/testReplay",
///          "bundleId": "com.bugcapsule.demo", "configuration": "Debug",
///          "simulator": "iPhone 18 Pro", "buildSettings": {"KEY": "VALUE"}}}
/// ```
///
/// Extra build settings can also come from the `BUGCAPSULE_IOS_BUILD_SETTINGS`
/// environment variable (`KEY=VALUE KEY2=VALUE2`), e.g. a temporary fix
/// toggle for `verify` that is not committed.
class IosNativeLauncher implements AppLauncher {
  IosNativeLauncher(this.options);

  @override
  final LaunchOptions options;

  _Simulator? _sim;
  late String _xctestrun;
  late String _bundleId;
  late String _replayTest;

  String? _str(String key) => options.projectConfig.string('ios', key);
  Map<String, Object?> get _section => options.projectConfig.section('ios');

  @override
  String get target => _sim == null ? 'ios simulator' : '${_sim!.name} (${_sim!.udid}, ${_sim!.runtime})';

  String _resolve(String path) => File(path).isAbsolute ? path : '${options.projectDir}/$path';

  @override
  Future<void> prepare(ReplayServer server) async {
    final sim = _sim = await _pickSimulator(options.deviceQuery ?? _str('simulator'));
    if (sim.state != 'Booted') {
      final progress = Progress('Booting ${sim.name}');
      await runChecked('xcrun', ['simctl', 'boot', sim.udid], verbose: options.verbose, label: 'simctl boot');
      await runChecked('xcrun', ['simctl', 'bootstatus', sim.udid, '-b'],
          verbose: options.verbose, label: 'simctl bootstatus', timeout: const Duration(minutes: 5));
      progress.done();
    }
    _replayTest = _str('replayTest') ?? '${_str('uiTestTarget') ?? 'UITests'}/BugCapsuleReplayTests/testReplay';

    final prebuilt = options.artifacts['xctestrun'];
    if (prebuilt != null) {
      _xctestrun = File(prebuilt).absolute.path;
      if (!File(_xctestrun).existsSync()) throw StateError('--xctestrun $prebuilt does not exist');
      _bundleId = _str('bundleId') ??
          (throw StateError('with --xctestrun, set "ios.bundleId" in bugcapsule.json'));
    } else {
      await _build(sim);
    }
    Processes.onCleanup(() async {
      await Process.run('xcrun', ['simctl', 'terminate', sim.udid, _bundleId]);
    });
  }

  /// Extra `KEY=VALUE` build settings from bugcapsule.json and the environment.
  List<String> get _extraSettings {
    final out = <String>[];
    final fromConfig = _section['buildSettings'];
    if (fromConfig != null) {
      if (fromConfig is! Map) throw StateError('bugcapsule.json: "ios.buildSettings" must be an object');
      fromConfig.forEach((k, v) => out.add('$k=$v'));
    }
    final fromEnv = Platform.environment['BUGCAPSULE_IOS_BUILD_SETTINGS'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      out.addAll(fromEnv.trim().split(RegExp(r'\s+')).where((s) => s.contains('=')));
    }
    return out;
  }

  Future<void> _build(_Simulator sim) async {
    final scheme = _str('scheme') ?? (throw StateError('bugcapsule.json: set "ios.scheme"'));
    final project = _str('project');
    final workspace = _str('workspace');
    final configuration = _str('configuration') ?? 'Debug';
    final derived = _resolve(_str('derivedDataPath') ??
        '${Directory.systemTemp.path}/bugcapsule-ios-${options.projectDir.hashCode.toUnsigned(32).toRadixString(16)}');
    final extra = _extraSettings;
    final progress = Progress('Building $scheme for testing (${sim.name})'
        '${extra.isEmpty ? '' : dim(' ${extra.join(' ')}')}');
    try {
      await runChecked(
        'xcrun',
        [
          'xcodebuild',
          'build-for-testing',
          if (workspace != null) ...['-workspace', workspace] else if (project != null) ...['-project', project],
          '-scheme',
          scheme,
          '-configuration',
          configuration,
          '-destination',
          'id=${sim.udid}',
          '-derivedDataPath',
          derived,
          'BUGCAPSULE_GIT_SHA=${options.buildSha ?? ''}',
          'BUGCAPSULE_GIT_DIRTY=${options.buildSha == null ? '' : options.dirty}',
          ...extra,
        ],
        workingDirectory: options.projectDir,
        verbose: options.verbose,
        label: 'xcodebuild build-for-testing',
        timeout: options.projectConfig.buildTimeout,
      );
      progress.done();
    } catch (_) {
      progress.fail();
      rethrow;
    }
    final products = Directory('$derived/Build/Products');
    final runs = products.listSync().whereType<File>().where((f) => f.path.endsWith('.xctestrun')).toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (runs.isEmpty) throw StateError('no .xctestrun in ${products.path}');
    _xctestrun = runs.first.path;
    _bundleId = _str('bundleId') ?? await _bundleIdFromProducts(Directory('${products.path}/$configuration-iphonesimulator'));
  }

  static Future<String> _bundleIdFromProducts(Directory dir) async {
    final apps = dir.existsSync()
        ? dir.listSync().whereType<Directory>().where((d) => d.path.endsWith('.app') && !d.path.endsWith('-Runner.app'))
        : const <Directory>[];
    if (apps.isEmpty) throw StateError('no app in ${dir.path}; set "ios.bundleId" in bugcapsule.json');
    final res = await Process.run('plutil', ['-extract', 'CFBundleIdentifier', 'raw', '${apps.first.path}/Info.plist']);
    final id = '${res.stdout}'.trim();
    if (res.exitCode != 0 || id.isEmpty) throw StateError('cannot read the bundle id of ${apps.first.path}');
    return id;
  }

  @override
  Future<ReplayReport> attempt(
      ReplayServer server, List<int> capsule, ReplaySettings settings, Duration timeout) async {
    final sim = _sim!;
    final armed = server.arm(capsule, settings);
    Process? xcodebuild;
    final subs = <StreamSubscription<String>>[];
    final log = StringBuffer();
    try {
      // Attempt isolation: a fresh data container (test-without-building
      // reinstalls the app from the build products).
      await Process.run('xcrun', ['simctl', 'terminate', sim.udid, _bundleId]);
      await Process.run('xcrun', ['simctl', 'uninstall', sim.udid, _bundleId]);

      xcodebuild = await Processes.start(
        'xcrun',
        [
          'xcodebuild',
          'test-without-building',
          '-xctestrun',
          _xctestrun,
          '-destination',
          'id=${sim.udid}',
          '-only-testing:$_replayTest',
          '-parallel-testing-enabled',
          'NO',
          '-collect-test-diagnostics',
          'never',
        ],
        workingDirectory: options.projectDir,
        environment: {'TEST_RUNNER_${ReplayProtocol.envUrl}': armed.url},
      );
      void onLine(String line) {
        log.writeln(line);
        if (options.verbose) stdout.writeln(dim(line));
        server.offerLine(armed, line);
      }

      subs
        ..add(xcodebuild.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine))
        ..add(xcodebuild.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine));
      final exited = xcodebuild.exitCode.then((code) async {
        // Give a report posted just before the exit time to arrive.
        await Future<void>.delayed(const Duration(seconds: 3));
        return errorReport(armed.settings,
            'xcodebuild exited ($code) before the app reported:\n${tail(log.toString(), 25)}');
      });
      // Install + launch of the test runner count against the budget too.
      final startup = Duration(seconds: _intSetting('startupSeconds') ?? 120);
      return await Future.any([armed.report, exited]).timeout(timeout + startup,
          onTimeout: () => errorReport(armed.settings,
              'no result within ${(timeout + startup).inSeconds}s (xcodebuild killed)\n${tail(log.toString(), 15)}'));
    } finally {
      armed.close();
      final p = xcodebuild;
      if (p != null) {
        // Stops the test run; a late report is rejected by the closed attempt.
        await Processes.kill(p, grace: const Duration(seconds: 5));
      }
      for (final s in subs) {
        await s.cancel();
      }
      await Process.run('xcrun', ['simctl', 'terminate', sim.udid, _bundleId]);
    }
  }

  int? _intSetting(String key) {
    final v = _section[key];
    return v is int ? v : v is String ? int.tryParse(v) : null;
  }

  @override
  Future<void> dispose() async {}

  static Future<_Simulator> _pickSimulator(String? query) async {
    final res = await Process.run('xcrun', ['simctl', 'list', 'devices', 'available', '--json']);
    if (res.exitCode != 0) throw StateError('`xcrun simctl list` failed (is Xcode installed?): ${res.stderr}');
    final devices = <_Simulator>[];
    final byRuntime = (jsonDecode('${res.stdout}') as Map)['devices'] as Map;
    byRuntime.forEach((runtime, list) {
      final name = '$runtime'.split('.').last.replaceFirst(RegExp(r'^iOS-'), 'iOS ').replaceAll('-', '.');
      if (!'$runtime'.contains('iOS')) return;
      for (final d in list as List) {
        final m = (d as Map).cast<String, Object?>();
        devices.add(_Simulator('${m['udid']}', '${m['name']}', '${m['state']}', name));
      }
    });
    if (devices.isEmpty) throw StateError('no iOS simulator available; create one in Xcode');
    final booted = devices.where((d) => d.state == 'Booted').toList();
    if (query != null) {
      final q = query.toLowerCase();
      final matches = devices.where((d) => d.udid.toLowerCase() == q || d.name.toLowerCase().contains(q)).toList()
        ..sort((a, b) => (b.state == 'Booted' ? 1 : 0) - (a.state == 'Booted' ? 1 : 0));
      if (matches.isEmpty) {
        throw StateError('no iOS simulator matches "$query" (physical devices are not supported by the '
            'iOS launcher; see the BugCapsule iOS README). Booted: ${booted.map((d) => d.name).join(', ')}');
      }
      return matches.first;
    }
    if (booted.isNotEmpty) return booted.firstWhere((d) => d.name.contains('iPhone'), orElse: () => booted.first);
    throw StateError('no booted iOS simulator; boot one or pass --device <name|udid>');
  }
}

class _Simulator {
  const _Simulator(this.udid, this.name, this.state, this.runtime);
  final String udid;
  final String name;
  final String state;
  final String runtime;
}
