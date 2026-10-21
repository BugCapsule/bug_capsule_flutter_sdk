import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule_core/bug_capsule_core.dart';

import '../launcher.dart';
import '../processes.dart';
import '../replay_server.dart';
import '../term.dart';

/// Native Android replay (runtimes-v1 §10): the app and its androidTest APK
/// (which carries `BugCapsuleReplayRunner` from `bugcapsule-android-replay`)
/// are built once with Gradle and installed; every attempt clears the app's
/// data (`pm clear`) and runs one instrumentation:
///
/// ```
/// adb shell am instrument -r -w -e bugcapsuleReplayUrl <armed url> \
///     -e class dev.bugcapsule.android.replay.BugCapsuleReplayTest <testApplicationId>/<runner>
/// ```
///
/// The device reaches the loopback replay server through `adb reverse`.
/// Results arrive over HTTP and, as a fallback, as the instrumentation status
/// `bugcapsule_result=BUGCAPSULE_RESULT::{json}` parsed from `am instrument -r`.
///
/// `bugcapsule.json`:
/// ```json
/// {"runtime": "android",
///  "android": {"gradleDir": ".", "module": "app", "variant": "debug",
///              "applicationId": "com.example.shop"}}
/// ```
/// Keys (all optional except `applicationId`): `gradleDir` (Gradle root,
/// relative to the project), `module` (Gradle path, default `app`),
/// `moduleDir` (module directory relative to the project, for APK lookup),
/// `variant` (default `debug`), `applicationId`, `testApplicationId` (default
/// `<applicationId>.test`), `runner`, `testClass`, `avd` (booted headless
/// when no device is running), `gradleArgs` (list, e.g.
/// `["-PbugcapsuleDemoFix=race"]`), `emulatorArgs` (list), `sdkDir`,
/// `bootTimeoutSeconds` (default 300). The environment variable
/// `BUGCAPSULE_ANDROID_GRADLE_ARGS` appends Gradle arguments for one run.
class AndroidLauncher implements AppLauncher {
  AndroidLauncher(this.options);

  @override
  final LaunchOptions options;

  static const defaultRunner = 'dev.bugcapsule.android.replay.BugCapsuleReplayRunner';
  static const defaultTestClass = 'dev.bugcapsule.android.replay.BugCapsuleReplayTest';
  static const gradleArgsEnv = 'BUGCAPSULE_ANDROID_GRADLE_ARGS';

  late final String _sdk = _sdkDir();
  late final String _adb = _tool('platform-tools/adb', 'adb');
  late String _serial;
  String _target = 'android';
  Process? _emulator;
  bool _bootedByUs = false;
  Future<void> Function()? _removeReverse;

  late final String _appId = _string('applicationId') ??
      (throw StateError('bugcapsule.json: "android.applicationId" is required for the android runtime'));
  late final String _testAppId = _string('testApplicationId') ?? '$_appId.test';
  late final String _runner = _string('runner') ?? defaultRunner;
  late final String _testClass = _string('testClass') ?? defaultTestClass;

  @override
  String get target => _target;

  String? _string(String key) => options.projectConfig.string('android', key);

  List<String> _list(String key) {
    final v = options.projectConfig.section('android')[key];
    if (v == null) return const [];
    if (v is! List || v.any((e) => e is! String)) {
      throw StateError('bugcapsule.json: "android.$key" must be a list of strings');
    }
    return v.cast<String>();
  }

  String _resolve(String path) =>
      path.startsWith('/') ? path : Directory('${options.projectDir}/$path').absolute.path;

  String get _gradleDir => Directory(_resolve(_string('gradleDir') ?? '.')).absolute.path;

  // ------------------------------------------------------------------ SDK

  String _sdkDir() {
    final env = Platform.environment;
    final candidates = <String?>[
      _string('sdkDir') == null ? null : _resolve(_string('sdkDir')!),
      env['ANDROID_HOME'],
      env['ANDROID_SDK_ROOT'],
      _localPropertiesSdk(),
      if (env['HOME'] != null) '${env['HOME']}/Library/Android/sdk',
      if (env['HOME'] != null) '${env['HOME']}/Android/Sdk',
    ];
    for (final c in candidates) {
      if (c != null && c.isNotEmpty && Directory(c).existsSync()) return c;
    }
    return '';
  }

  String? _localPropertiesSdk() {
    try {
      final file = File('${Directory(_resolve(_string('gradleDir') ?? '.')).path}/local.properties');
      if (!file.existsSync()) return null;
      for (final line in file.readAsLinesSync()) {
        if (line.startsWith('sdk.dir=')) return line.substring('sdk.dir='.length).replaceAll(r'\:', ':').trim();
      }
    } catch (_) {}
    return null;
  }

  /// `<sdk>/<relative>` when it exists, else [fallback] from PATH.
  String _tool(String relative, String fallback) {
    if (_sdk.isNotEmpty && File('$_sdk/$relative').existsSync()) return '$_sdk/$relative';
    return fallback;
  }

  Future<ProcessResult> _adbRun(List<String> args, {String? serial}) =>
      Process.run(_adb, [if (serial != null) ...['-s', serial], ...args]);

  Future<String> _shell(String serial, List<String> args) async =>
      '${(await _adbRun(['shell', ...args], serial: serial)).stdout}'.trim();

  // --------------------------------------------------------------- device

  Future<List<String>> _onlineDevices() async {
    final res = await _adbRun(['devices']);
    if (res.exitCode != 0) throw StateError('`adb devices` failed: ${res.stderr}');
    return [
      for (final line in const LineSplitter().convert('${res.stdout}').skip(1))
        if (line.trim().endsWith('\tdevice')) line.split('\t').first.trim(),
    ];
  }

  Future<String?> _avdName(String serial) async {
    if (!serial.startsWith('emulator-')) return null;
    final res = await _adbRun(['emu', 'avd', 'name'], serial: serial);
    final first = const LineSplitter().convert('${res.stdout}').firstOrNull?.trim();
    return first == null || first.isEmpty || first == 'OK' ? null : first;
  }

  Future<String> _describe(String serial) async {
    final avd = await _avdName(serial);
    final model = await _shell(serial, ['getprop', 'ro.product.model']);
    final api = await _shell(serial, ['getprop', 'ro.build.version.sdk']);
    return '${avd ?? model} (API $api, $serial)';
  }

  Future<List<String>> _listAvds() async {
    final res = await Process.run(_tool('emulator/emulator', 'emulator'), ['-list-avds']);
    return [
      for (final l in const LineSplitter().convert('${res.stdout}'))
        if (l.trim().isNotEmpty && !l.startsWith('INFO')) l.trim(),
    ];
  }

  Future<void> _pickDevice() async {
    final query = options.deviceQuery?.toLowerCase();
    final online = await _onlineDevices();
    if (online.isNotEmpty) {
      if (query == null) {
        _serial = online.firstWhere((s) => s.startsWith('emulator-'), orElse: () => online.first);
        return;
      }
      for (final s in online) {
        final avd = (await _avdName(s))?.toLowerCase();
        final model = (await _shell(s, ['getprop', 'ro.product.model'])).toLowerCase();
        if (s.toLowerCase() == query || (avd != null && avd.contains(query)) || model.contains(query)) {
          _serial = s;
          return;
        }
      }
    }
    final avds = await _listAvds();
    String? avd = query == null ? null : avds.where((a) => a.toLowerCase() == query).firstOrNull;
    avd ??= query == null ? (_string('avd') ?? avds.firstOrNull) : null;
    if (avd == null) {
      throw StateError(query == null
          ? 'no Android device or emulator is running and no AVD is available; create one or set "android.avd"'
          : 'no running device or AVD matches "${options.deviceQuery}". Running: ${online.join(', ')}; AVDs: ${avds.join(', ')}');
    }
    await _bootAvd(avd, online.toSet());
  }

  Future<void> _bootAvd(String avd, Set<String> before) async {
    final progress = Progress('Booting emulator $avd (headless)');
    final log = StringBuffer();
    try {
      final emulator = _emulator = await Processes.start(_tool('emulator/emulator', 'emulator'), [
        '-avd',
        avd,
        '-no-window',
        '-no-audio',
        '-no-boot-anim',
        '-no-snapshot-save',
        ..._list('emulatorArgs'),
      ]);
      _bootedByUs = true;
      emulator.stdout.transform(utf8.decoder).listen((s) {
        log.write(s);
        if (options.verbose) stdout.write(s);
      });
      emulator.stderr.transform(utf8.decoder).listen(log.write);
      var exited = false;
      unawaited(emulator.exitCode.then((_) => exited = true));
      final timeoutSeconds = int.tryParse(_string('bootTimeoutSeconds') ?? '') ?? 300;
      final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
      String? serial;
      while (DateTime.now().isBefore(deadline)) {
        if (exited) throw StateError('emulator exited while booting:\n${tail(log.toString())}');
        if (serial == null) {
          for (final s in await _onlineDevices()) {
            if (!before.contains(s) && s.startsWith('emulator-')) serial = s;
          }
        }
        if (serial != null && await _shell(serial, ['getprop', 'sys.boot_completed']) == '1') {
          // The package manager answers a little after boot completes.
          final pm = await _adbRun(['shell', 'pm', 'path', 'android'], serial: serial);
          if (pm.exitCode == 0 && '${pm.stdout}'.contains('package:')) {
            _serial = serial;
            progress.done(serial);
            return;
          }
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      throw StateError('emulator $avd did not finish booting within ${timeoutSeconds}s');
    } catch (_) {
      progress.fail();
      rethrow;
    }
  }

  /// Apps cannot start while the user's storage is locked (file-based
  /// encryption before the first unlock after boot).
  Future<void> _ensureUnlocked() async {
    for (var i = 0; i < 15; i++) {
      final state = await _shell(_serial, ['am', 'get-started-user-state', '0']);
      if (!state.contains('RUNNING_LOCKED')) return;
      await _adbRun(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'], serial: _serial);
      await _adbRun(['shell', 'wm', 'dismiss-keyguard'], serial: _serial);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('$_serial is locked (a screen lock credential is set); unlock it once, then retry');
  }

  // ---------------------------------------------------------------- build

  String get _variant => _string('variant') ?? 'debug';

  String _capitalized(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  String get _modulePath {
    final m = _string('module') ?? 'app';
    return m.startsWith(':') ? m : ':$m';
  }

  String get _moduleDir {
    final explicit = _string('moduleDir');
    if (explicit != null) return _resolve(explicit);
    final project = Directory(options.projectDir).absolute.path;
    final hasBuildFile =
        File('$project/build.gradle.kts').existsSync() || File('$project/build.gradle').existsSync();
    if (hasBuildFile && Directory(project).resolveSymbolicLinksSync() != Directory(_gradleDir).resolveSymbolicLinksSync()) {
      return project;
    }
    return '$_gradleDir/${_modulePath.substring(1).replaceAll(':', '/')}';
  }

  List<String> get _gradleArgs => [
        ..._list('gradleArgs'),
        ...?Platform.environment[gradleArgsEnv]?.split(RegExp(r'\s+')).where((a) => a.isNotEmpty),
        if (options.buildSha != null) ...[
          '-PbugcapsuleGitSha=${options.buildSha}',
          '-PbugcapsuleGitDirty=${options.dirty}',
        ],
      ];

  Future<(String, String)> _build() async {
    final apk = options.artifacts['apk'];
    final testApk = options.artifacts['test-apk'];
    if (apk != null || testApk != null) {
      if (apk == null || testApk == null) {
        throw StateError('pass both --apk and --test-apk (the androidTest APK carries the replay runner)');
      }
      for (final f in [apk, testApk]) {
        if (!File(f).existsSync()) throw StateError('no such file: $f');
      }
      return (File(apk).absolute.path, File(testApk).absolute.path);
    }
    final gradleDir = _gradleDir;
    final wrapper = File('$gradleDir/gradlew');
    final gradle = wrapper.existsSync() ? wrapper.path : 'gradle';
    final variant = _capitalized(_variant);
    final progress = Progress('Building $_modulePath ($_variant + androidTest) with Gradle');
    try {
      await runChecked(
        gradle,
        [
          '$_modulePath:assemble$variant',
          '$_modulePath:assemble${variant}AndroidTest',
          '--console=plain',
          ..._gradleArgs,
        ],
        workingDirectory: gradleDir,
        verbose: options.verbose,
        label: 'gradle assemble$variant',
        timeout: options.projectConfig.buildTimeout,
      );
      progress.done();
    } catch (_) {
      progress.fail();
      rethrow;
    }
    final outputs = Directory('$_moduleDir/build/outputs/apk');
    if (!outputs.existsSync()) throw StateError('no APKs under ${outputs.path}; set "android.moduleDir"');
    final apks = outputs
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.apk'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    final lower = _variant.toLowerCase();
    File? pick(bool test) => apks
        .where((f) => f.path.contains('/androidTest/') == test && f.path.toLowerCase().contains(lower))
        .firstOrNull;
    final app = pick(false);
    final test = pick(true);
    if (app == null || test == null) {
      throw StateError('could not find the $_variant APKs under ${outputs.path} after the build');
    }
    return (app.path, test.path);
  }

  Future<void> _install(String apk) async {
    var res = await _adbRun(['install', '-r', '-t', apk], serial: _serial);
    final out = '${res.stdout}${res.stderr}';
    if (res.exitCode != 0 || !out.contains('Success')) {
      if (out.contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE') || out.contains('INSTALL_FAILED_VERSION_DOWNGRADE')) {
        final pkg = apk == _lastTestApk ? _testAppId : _appId;
        await _adbRun(['uninstall', pkg], serial: _serial);
        res = await _adbRun(['install', '-r', '-t', apk], serial: _serial);
        if (res.exitCode == 0 && '${res.stdout}'.contains('Success')) return;
      }
      throw StateError('adb install $apk failed: ${tail(out, 10)}');
    }
  }

  String? _lastTestApk;

  @override
  Future<void> prepare(ReplayServer server) async {
    if (_sdk.isEmpty && _adb == 'adb') {
      stdout.writeln(yellow('! Android SDK not found (set ANDROID_HOME); using adb from PATH'));
    }
    // Validate configuration before booting or building anything.
    _appId;
    await _pickDevice();
    await _ensureUnlocked();
    _target = await _describe(_serial);
    final (apk, testApk) = await _build();
    _lastTestApk = testApk;
    final progress = Progress('Installing on $_serial');
    try {
      await _install(apk);
      await _install(testApk);
      progress.done();
    } catch (_) {
      progress.fail();
      rethrow;
    }
    final port = server.port;
    final reverse = await _adbRun(['reverse', 'tcp:$port', 'tcp:$port'], serial: _serial);
    if (reverse.exitCode != 0) throw StateError('adb reverse failed: ${reverse.stderr}');
    final serial = _serial;
    _removeReverse = Processes.onCleanup(() async {
      await Process.run(_adb, ['-s', serial, 'reverse', '--remove', 'tcp:$port']);
    });
  }

  // -------------------------------------------------------------- attempt

  @override
  Future<ReplayReport> attempt(
      ReplayServer server, List<int> capsule, ReplaySettings settings, Duration timeout) async {
    final armed = server.arm(capsule, settings);
    Process? process;
    final subs = <StreamSubscription<String>>[];
    final log = StringBuffer();
    try {
      await _adbRun(['shell', 'am', 'force-stop', _appId], serial: _serial);
      // Attempt isolation: fresh app data (storage is restored from the capsule).
      final clear = await _adbRun(['shell', 'pm', 'clear', _appId], serial: _serial);
      if (!'${clear.stdout}'.contains('Success')) {
        throw StateError('pm clear $_appId failed: ${clear.stdout}${clear.stderr}');
      }
      final p = process = await Processes.start(_adb, [
        '-s',
        _serial,
        'shell',
        'am',
        'instrument',
        '-r',
        '-w',
        '-e',
        'bugcapsuleReplayUrl',
        armed.url,
        '-e',
        'class',
        _testClass,
        '$_testAppId/$_runner',
      ]);
      void onLine(String line) {
        log.writeln(line);
        if (options.verbose) stdout.writeln(dim(line));
        server.offerLine(armed, line);
      }

      subs
        ..add(p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine))
        ..add(p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine));
      var reported = false;
      unawaited(armed.report.then((_) => reported = true));
      final exited = p.exitCode.then((code) async {
        // The HTTP report can land just after the instrumentation ends.
        await Future.any([armed.report, Future<void>.delayed(const Duration(seconds: 3))]);
        if (reported) return armed.report;
        return errorReport(armed.settings,
            'instrumentation ended (exit $code) without a BugCapsule result:\n${tail(log.toString(), 20)}');
      });
      return await Future.any([armed.report, exited]).timeout(timeout,
          onTimeout: () => errorReport(armed.settings, 'no result within ${timeout.inSeconds}s'));
    } finally {
      armed.close();
      final p = process;
      if (p != null) {
        final done = await p.exitCode.timeout(const Duration(milliseconds: 100), onTimeout: () => -999);
        if (done == -999) await Processes.kill(p);
      }
      // Stops the instrumentation (it runs in the app's process) on timeout or interruption.
      await _adbRun(['shell', 'am', 'force-stop', _appId], serial: _serial);
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  @override
  Future<void> dispose() async {
    final remove = _removeReverse;
    _removeReverse = null;
    if (remove != null) await remove();
    final emulator = _emulator;
    if (_bootedByUs && emulator != null) {
      _bootedByUs = false;
      try {
        await _adbRun(['emu', 'kill'], serial: _serial);
      } catch (_) {
        emulator.kill();
      }
      await emulator.exitCode.timeout(const Duration(seconds: 30), onTimeout: () {
        emulator.kill(ProcessSignal.sigkill);
        return -1;
      });
    }
  }
}
