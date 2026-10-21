import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import '../core/core.dart';

import 'backend_client.dart';
import 'capsule_source.dart';
import 'inspect.dart';
import 'launcher.dart';
import 'processes.dart';
import 'project_config.dart';
import 'replay.dart';
import 'replay_server.dart';
import 'term.dart';

const version = '0.4.0';

CommandRunner<int> buildRunner() => CommandRunner<int>(
      'bugcapsule',
      'Inspect, replay and verify capsules.',
    )
      ..argParser.addFlag('version', negatable: false, help: 'Print the version.')
      ..addCommand(InspectCommand())
      ..addCommand(ReplayCommand(ReplayKind.replay))
      ..addCommand(ReplayCommand(ReplayKind.verify))
      ..addCommand(RegressCommand())
      ..addCommand(LoginCommand())
      ..addCommand(ListCommand())
      ..addCommand(PullCommand())
      ..addCommand(PushCommand())
      ..addCommand(ShareCommand())
      ..addCommand(KillSwitchCommand());

Future<int> runBugCapsule(List<String> args) async {
  final runner = buildRunner();
  try {
    final parsed = runner.parse(args);
    if (parsed['version'] == true) {
      stdout.writeln('bugcapsule $version (capsule spec v${CapsuleCodec.specVersion})');
      return 0;
    }
    return await runner.runCommand(parsed) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    return 64;
  } on ApiException catch (e) {
    stderr.writeln(red('backend: $e'));
    return 1;
  } on CapsuleFormatException catch (e) {
    stderr.writeln(red(e.message));
    return 3;
  } on StateError catch (e) {
    stderr.writeln(red(e.message));
    return 1;
  } on SocketException catch (e) {
    stderr.writeln(red('network: ${e.message} ${e.address?.host ?? ''}'));
    return 1;
  }
}

String _rest(Command<int> c, String what) {
  final rest = c.argResults!.rest;
  if (rest.length != 1) throw UsageException('expected exactly one $what', c.usage);
  return rest.single;
}

BackendClient _client() {
  final creds = Credentials.load();
  if (creds == null) throw StateError('no backend configured; run `bugcapsule login --url ... --secret-key ...`');
  return BackendClient(creds);
}

// ------------------------------------------------------------------ inspect

class InspectCommand extends Command<int> {
  InspectCommand() {
    argParser
      ..addFlag('json', negatable: false, help: 'Print the manifest as JSON.')
      ..addOption('timeline', defaultsTo: '40', help: 'Number of timeline events to show.');
  }

  @override
  String get name => 'inspect';
  @override
  String get description => 'Show what a capsule contains: failure, eligibility, network, timeline.';
  @override
  String get invocation => 'bugcapsule inspect <file | capsule-id | share-url>';

  @override
  Future<int> run() async {
    final loaded = await loadCapsule(_rest(this, 'capsule'));
    printInspect(loaded.capsule,
        timeline: int.parse(argResults!['timeline'] as String), json: argResults!['json'] as bool);
    return 0;
  }
}

// ------------------------------------------------------------- run / verify

void _addLaunchOptions(ArgParser p) {
  p
    ..addOption('runtime',
        allowed: ProjectConfig.runtimes,
        help: 'App runtime (default: "runtime" in bugcapsule.json, else detected from the project).')
    ..addOption('device', abbr: 'd', help: 'Device id or name (default: first simulator/emulator).')
    ..addOption('project', abbr: 'p', defaultsTo: '.', help: 'App project directory.')
    ..addOption('target', abbr: 't', defaultsTo: 'lib/main.dart', help: 'Entry point (flutter).')
    ..addOption('flavor', help: 'Build flavor (flutter).')
    ..addMultiOption('dart-define', help: 'Extra --dart-define values (KEY=VALUE, flutter).')
    ..addOption('apk', help: 'Prebuilt app APK (android); skips the Gradle build.')
    ..addOption('test-apk', help: 'Prebuilt instrumentation APK (android).')
    ..addOption('xctestrun', help: 'Prebuilt .xctestrun from build-for-testing (ios); skips the build.')
    ..addOption('app-url', help: 'URL of an already running web app (web); skips build and serve.')
    ..addOption('attempt-timeout', help: 'Seconds per attempt (default: recorded duration + settle + 45s).')
    ..addFlag('lan', negatable: false, help: 'Bind the replay server on the LAN (physical devices).')
    ..addOption('strategy',
        allowed: ['auto', 'pointer', 'semantic'], defaultsTo: 'auto', help: 'How input is replayed.')
    ..addOption('settle', defaultsTo: '8', help: 'Seconds to wait for the failure after the last input.')
    ..addFlag('lenient-network',
        negatable: false, help: 'Send unrecorded requests to the real network instead of failing them.')
    ..addFlag('compress-idle',
        defaultsTo: true,
        help: 'Skip long idle gaps between inputs (recorded network latency is always kept).')
    ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Show build and device output.');
}

Map<String, String> _artifacts(ArgResults args) => {
      for (final k in const ['apk', 'test-apk', 'xctestrun', 'app-url'])
        if (args[k] != null) k: args[k] as String,
    };

/// Resolves the runtime for [project] and refuses a capsule from another one.
(ProjectConfig, String) _runtimeFor(ArgResults args, String project) {
  final config = ProjectConfig.load(project);
  final runtime = config.resolveRuntime(override: args['runtime'] as String?);
  if (runtime == null) {
    throw StateError('cannot tell the runtime of $project; pass --runtime or add ${ProjectConfig.fileName}');
  }
  return (config, runtime);
}

/// Stops child processes and runs cleanups on Ctrl-C, then exits 130.
StreamSubscription<ProcessSignal> _onInterrupt(Future<void> Function() cleanup) =>
    ProcessSignal.sigint.watch().listen((_) async {
      stderr.writeln(yellow('\ninterrupted; stopping replay processes'));
      try {
        await cleanup();
      } finally {
        await Processes.stopAll();
        exit(130);
      }
    });

Duration? _attemptTimeout(ArgResults args, ProjectConfig config) {
  final raw = args['attempt-timeout'] as String?;
  if (raw != null) return Duration(milliseconds: (double.parse(raw) * 1000).round());
  return config.attemptTimeout;
}

Map<String, String> _defines(ArgResults args, String? sha, bool dirty) => {
      'BUGCAPSULE_GIT_SHA': ?sha,
      if (sha != null) 'BUGCAPSULE_GIT_DIRTY': '$dirty',
      for (final d in args['dart-define'] as List<String>)
        if (d.contains('=')) d.substring(0, d.indexOf('=')): d.substring(d.indexOf('=') + 1),
    };

class ReplayCommand extends Command<int> {
  ReplayCommand(this.kind) {
    _addLaunchOptions(argParser);
    argParser.addOption('runs',
        abbr: 'n', defaultsTo: kind == ReplayKind.replay ? '3' : '5', help: 'Attempts.');
    if (kind == ReplayKind.replay) {
      argParser.addFlag('pin',
          defaultsTo: true, help: "Build the capsule's git commit in a temporary worktree.");
    }
    argParser.addOption('report-to',
        help: 'Backend capsule id to record the result on (automatic for backend capsules).');
  }

  final ReplayKind kind;

  @override
  String get name => kind == ReplayKind.replay ? 'run' : 'verify';
  @override
  String get description => kind == ReplayKind.replay
      ? 'Replay a capsule on a simulator/emulator and check the failure happens again.'
      : 'Replay a capsule on the current (patched) code and check the failure is gone.';
  @override
  String get invocation => 'bugcapsule $name <file | capsule-id | share-url> [options]';

  @override
  Future<int> run() async {
    final args = argResults!;
    final loaded = await loadCapsule(_rest(this, 'capsule'), serverId: args['report-to'] as String?);
    final m = loaded.capsule.manifest;
    stdout.writeln('${bold('Capsule')} ${shortId(m.capsuleId)}  ${m.app.version}+${m.app.build}  '
        '${m.platform.os}  ${dim(m.mode.name)}');
    stdout.writeln('${bold('Failure')} ${m.failure == null ? yellow('none') : red(m.failure!.signature)}');
    if (m.eligibility.status != EligibilityStatus.eligible) {
      stdout.writeln('${bold('Eligibility')} ${yellow(m.eligibility.status.name)}: '
          '${m.eligibility.missing.map((x) => x.dependency).join(', ')}');
    }

    final project = args['project'] as String;
    final (config, runtime) = _runtimeFor(args, project);
    stdout.writeln('${bold('Runtime')} $runtime'
        '${loaded.capsule.manifest.runtime == null ? '' : dim('  (captured: ${m.runtimeName} ${m.runtime?.version ?? ''})')}');
    final attempts = int.parse(args['runs'] as String);
    final mismatch = runtimeMismatch(loaded.capsule, runtime);
    if (mismatch != null) {
      final summary = incompatibleSummary(kind, attempts, mismatch, runtime: runtime);
      printSummary(summary, loaded.capsule);
      await _report(loaded, summary, runtime);
      return exitCodeFor(summary);
    }

    final artifacts = _artifacts(args);
    final (projectDir, buildSha, dirty) = artifacts.isNotEmpty
        ? (project, null, false)
        : await resolveTree(
            loaded,
            projectDir: project,
            kind: kind,
            pin: kind == ReplayKind.replay ? args['pin'] as bool : false,
          );
    final device = runtime == 'flutter' ? await pickDevice(args['device'] as String?) : null;
    if (device != null) stdout.writeln('${bold('Device')} $device');

    final server = await ReplayServer.start(lan: args['lan'] as bool);
    final launcher = AppLauncher.forOptions(LaunchOptions(
      runtime: runtime,
      config: config,
      projectDir: projectDir,
      target: args['target'] as String,
      device: device,
      deviceQuery: args['device'] as String?,
      dartDefines: _defines(args, buildSha, dirty),
      flavor: args['flavor'] as String?,
      verbose: args['verbose'] as bool,
      buildSha: buildSha,
      dirty: dirty,
      artifacts: artifacts,
    ));
    final interrupt = _onInterrupt(() async {
      await launcher.dispose();
      await server.close();
    });
    try {
      await launcher.prepare(server);
      if (device == null) stdout.writeln('${bold('Target')} ${launcher.target}');
      final summary = await replayCapsule(
        loaded: loaded,
        launcher: launcher,
        server: server,
        kind: kind,
        attempts: attempts,
        strategy: ReplayStrategy.values.byName(args['strategy'] as String),
        settleTimeoutMs: (double.parse(args['settle'] as String) * 1000).round(),
        strictNetwork: !(args['lenient-network'] as bool),
        idleCompression: args['compress-idle'] as bool,
        buildSha: buildSha,
        runtime: runtime,
        attemptTimeout: _attemptTimeout(args, config),
      );
      printSummary(summary, loaded.capsule);
      await _report(loaded, summary, launcher.target);
      return exitCodeFor(summary);
    } finally {
      await interrupt.cancel();
      await launcher.dispose();
      await server.close();
      await Processes.stopAll();
    }
  }

  Future<void> _report(LoadedCapsule loaded, ReplaySummary s, String device) async {
    final id = loaded.serverId;
    final creds = Credentials.load();
    if (id == null || creds?.secretKey == null) return;
    try {
      await BackendClient(creds!).createRun(id, s.runPayload(device: device));
      stdout.writeln(dim('Recorded on backend capsule $id (${s.wireOutcome})'));
    } catch (e) {
      stdout.writeln(yellow('! could not record result on backend: $e'));
    }
  }
}

// ------------------------------------------------------------------ regress

class RegressCommand extends Command<int> {
  RegressCommand() {
    addSubcommand(_RegressAdd());
    addSubcommand(_RegressList());
    addSubcommand(_RegressRun());
  }

  @override
  String get name => 'regress';
  @override
  String get description => 'Keep fixed capsules as regression tests and run them (e.g. in CI).';
}

class RegressionSuite {
  RegressionSuite(this.projectDir) : _file = File('$projectDir/bugcapsule/regressions.json');

  final String projectDir;
  final File _file;

  List<Map<String, Object?>> load() {
    if (!_file.existsSync()) return [];
    final json = jsonDecode(_file.readAsStringSync()) as Map;
    return [for (final t in json['tests'] as List) (t as Map).cast<String, Object?>()];
  }

  void save(List<Map<String, Object?>> tests) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({'version': 1, 'tests': tests})}\n');
  }
}

class _RegressAdd extends Command<int> {
  _RegressAdd() {
    argParser
      ..addOption('project', abbr: 'p', defaultsTo: '.')
      ..addOption('name', help: 'Human name for the test.');
  }

  @override
  String get name => 'add';
  @override
  String get description => 'Add a capsule to the regression suite (bugcapsule/regressions).';

  @override
  Future<int> run() async {
    final loaded = await loadCapsule(_rest(this, 'capsule'));
    final m = loaded.capsule.manifest;
    if (m.failure == null) throw StateError('capsule has no failure assertion; it cannot guard a regression');
    final project = argResults!['project'] as String;
    final suite = RegressionSuite(project);
    final tests = suite.load();
    final relative = 'bugcapsule/regressions/${m.capsuleId}.bugcapsule';
    File('$project/$relative')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(loaded.bytes);
    tests.removeWhere((t) => t['capsuleId'] == m.capsuleId);
    tests.add({
      'capsuleId': m.capsuleId,
      'name': argResults!['name'] ?? m.failure!.signature,
      'file': relative,
      'signature': m.failure!.signature,
      'status': 'active',
      'addedAt': DateTime.now().toUtc().toIso8601String(),
      'runtime': m.runtimeName,
      'lineage': {'serverId': loaded.serverId, 'capturedGitSha': m.gitSha},
      'lastRun': null,
    });
    suite.save(tests);
    stdout.writeln('${green('✓')} added $relative (${tests.length} tests). Commit it with your fix.');
    return 0;
  }
}

class _RegressList extends Command<int> {
  _RegressList() {
    argParser.addOption('project', abbr: 'p', defaultsTo: '.');
  }

  @override
  String get name => 'list';
  @override
  String get description => 'List regression tests and their state.';

  @override
  Future<int> run() async {
    final tests = RegressionSuite(argResults!['project'] as String).load();
    if (tests.isEmpty) {
      stdout.writeln('No regression tests. Add one with `bugcapsule regress add <capsule>`.');
      return 0;
    }
    for (final t in tests) {
      final status = '${t['status']}';
      final colored = switch (status) {
        'active' => green(status),
        'stale' || 'quarantined' => yellow(status),
        _ => dim(status),
      };
      final last = t['lastRun'] as Map?;
      stdout.writeln('${shortId('${t['capsuleId']}')}  ${colored.padRight(12)}  ${t['name']}'
          '${last == null ? '' : dim('  last: ${last['result']} ${last['at']}')}');
    }
    return 0;
  }
}

class _RegressRun extends Command<int> {
  _RegressRun() {
    _addLaunchOptions(argParser);
    argParser
      ..addOption('runs', abbr: 'n', defaultsTo: '2', help: 'Attempts per test.')
      ..addFlag('include-quarantined', negatable: false);
  }

  @override
  String get name => 'run';
  @override
  String get description =>
      'Verify every active regression capsule against the current code. Exit 1 if any fails.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final project = args['project'] as String;
    final suite = RegressionSuite(project);
    final tests = suite.load();
    final includeQ = args['include-quarantined'] as bool;
    final selected = tests
        .where((t) => t['status'] == 'active' || (includeQ && t['status'] == 'quarantined'))
        .toList();
    if (selected.isEmpty) {
      stdout.writeln('No active regression tests.');
      return 0;
    }
    final (config, runtime) = _runtimeFor(args, project);
    final artifacts = _artifacts(args);
    final device = runtime == 'flutter' ? await pickDevice(args['device'] as String?) : null;
    final first = await loadCapsule('$project/${selected.first['file']}');
    final (projectDir, sha, dirty) = artifacts.isNotEmpty
        ? (project, null, false)
        : await resolveTree(first, projectDir: project, kind: ReplayKind.verify, pin: false);
    final server = await ReplayServer.start(lan: args['lan'] as bool);
    final launcher = AppLauncher.forOptions(LaunchOptions(
      runtime: runtime,
      config: config,
      projectDir: projectDir,
      target: args['target'] as String,
      device: device,
      deviceQuery: args['device'] as String?,
      dartDefines: _defines(args, sha, dirty),
      flavor: args['flavor'] as String?,
      verbose: args['verbose'] as bool,
      buildSha: sha,
      dirty: dirty,
      artifacts: artifacts,
    ));
    final interrupt = _onInterrupt(() async {
      suite.save(tests);
      await launcher.dispose();
      await server.close();
    });
    var failed = 0;
    try {
      await launcher.prepare(server);
      for (final t in selected) {
        stdout.writeln('\n${bold('${t['name']}')} ${dim(shortId('${t['capsuleId']}'))}');
        final loaded = await loadCapsule('$project/${t['file']}');
        final mismatch = runtimeMismatch(loaded.capsule, runtime);
        final s = mismatch != null
            ? incompatibleSummary(ReplayKind.verify, int.parse(args['runs'] as String), mismatch, runtime: runtime)
            : await replayCapsule(
          loaded: loaded,
          launcher: launcher,
          server: server,
          kind: ReplayKind.verify,
          attempts: int.parse(args['runs'] as String),
          strategy: ReplayStrategy.values.byName(args['strategy'] as String),
          settleTimeoutMs: (double.parse(args['settle'] as String) * 1000).round(),
          strictNetwork: !(args['lenient-network'] as bool),
          idleCompression: args['compress-idle'] as bool,
          buildSha: sha,
          runtime: runtime,
          attemptTimeout: _attemptTimeout(args, config),
        );
        final String result;
        switch (s.verdict) {
          case Verdict.incompatible:
            // Schema changed without a migration: stale, not flaky.
            t['status'] = 'stale';
            result = 'stale';
          case Verdict.fixed:
            result = 'pass';
          case Verdict.flaky:
            t['status'] = 'quarantined';
            result = 'flaky';
          case Verdict.stillFailing:
            result = 'fail';
            failed++;
          case Verdict.inconclusive || Verdict.reproduced || Verdict.notReproduced:
            // A regression test only passes on a valid run without the failure.
            result = 'inconclusive';
            failed++;
        }
        t['lastRun'] = {
          'at': DateTime.now().toUtc().toIso8601String(),
          'result': result,
          'attempts': s.requestedAttempts,
          'validAttempts': s.evaluation.validAttempts,
          'reproductions': s.reproductions,
          'gitSha': sha,
          if (s.evaluation.reasons.isNotEmpty) 'reasons': s.evaluation.reasons.take(10).toList(),
        };
        stdout.writeln('  → ${result == 'pass' ? green(result) : result == 'fail' ? red(result) : yellow(result)}');
      }
    } finally {
      await interrupt.cancel();
      suite.save(tests);
      await launcher.dispose();
      await server.close();
      await Processes.stopAll();
    }
    stdout.writeln();
    stdout.writeln(failed == 0
        ? green('All ${selected.length} regression capsules pass.')
        : red('$failed of ${selected.length} regression capsules fail.'));
    return failed == 0 ? 0 : 1;
  }
}

// ------------------------------------------------------------------ backend

class LoginCommand extends Command<int> {
  LoginCommand() {
    argParser
      ..addOption('url', mandatory: true, help: 'Backend URL, e.g. http://127.0.0.1:8787')
      ..addOption('secret-key', help: 'Project secret key (bcs_...).')
      ..addOption('ingest-key', help: 'Project ingest key (bci_...), for `bugcapsule push`.');
  }

  @override
  String get name => 'login';
  @override
  String get description => 'Save backend URL and keys to ~/.bugcapsule/config.json.';

  @override
  Future<int> run() async {
    final creds = Credentials(
      url: argResults!['url'] as String,
      secretKey: argResults!['secret-key'] as String?,
      ingestKey: argResults!['ingest-key'] as String?,
    );
    if (creds.secretKey != null) {
      final project = await BackendClient(creds).project();
      stdout.writeln('${green('✓')} project "${project['name']}" (${project['id']})');
    }
    creds.save();
    stdout.writeln('Saved ${Credentials.file.path}');
    return 0;
  }
}

class ListCommand extends Command<int> {
  ListCommand() {
    argParser
      ..addOption('status', allowed: ['new', 'reproduced', 'not_reproduced', 'fixed', 'ineligible', 'archived'])
      ..addOption('mode', allowed: ['debug', 'qa', 'production'])
      ..addOption('eligibility', allowed: ['eligible', 'partial', 'ineligible'])
      ..addOption('limit', defaultsTo: '25');
  }

  @override
  String get name => 'list';
  @override
  String get description => 'List capsules on the backend, newest first.';

  @override
  Future<int> run() async {
    final query = {
      for (final k in ['status', 'mode', 'eligibility', 'limit'])
        if (argResults![k] != null) k: argResults![k] as String,
    };
    final page = await _client().listCapsules(query);
    final items = page['items'] as List;
    if (items.isEmpty) stdout.writeln('No capsules.');
    for (final c in items.cast<Map<String, Object?>>()) {
      stdout.writeln('${c['id']}  ${'${c['status']}'.padRight(14)} ${'${c['eligibility']}'.padRight(10)} '
          '${dim('${c['mode']} ${c['appVersion']}+${c['appBuild']} ${c['platform']}')}  '
          '${c['failureSignature'] ?? dim('(manual)')}');
    }
    return 0;
  }
}

class PullCommand extends Command<int> {
  PullCommand() {
    argParser.addOption('output', abbr: 'o', help: 'File to write (default: <capsuleId>.bugcapsule).');
  }

  @override
  String get name => 'pull';
  @override
  String get description => 'Download a capsule from the backend.';

  @override
  Future<int> run() async {
    final loaded = await loadCapsule(_rest(this, 'capsule id or share URL'));
    final out = argResults!['output'] as String? ?? '${loaded.capsule.manifest.capsuleId}.bugcapsule';
    File(out).writeAsBytesSync(loaded.bytes);
    stdout.writeln('${green('✓')} $out (${loaded.bytes.length} bytes)');
    return 0;
  }
}

class PushCommand extends Command<int> {
  @override
  String get name => 'push';
  @override
  String get description => 'Upload a local capsule file to the backend (uses the ingest key).';

  @override
  Future<int> run() async {
    final loaded = await loadCapsule(_rest(this, 'file'));
    final res = await _client().upload(loaded.bytes);
    stdout.writeln('${green('✓')} ${res['id']} (${res['status']}, ${res['eligibility']})');
    return 0;
  }
}

class ShareCommand extends Command<int> {
  ShareCommand() {
    argParser.addOption('hours', defaultsTo: '72', help: 'Link lifetime.');
  }

  @override
  String get name => 'share';
  @override
  String get description => 'Create an expiring download link for a backend capsule.';

  @override
  Future<int> run() async {
    final res = await _client().share(_rest(this, 'capsule id'), int.parse(argResults!['hours'] as String));
    stdout.writeln('${res['url']}\n${dim('expires ${res['expiresAt']}')}');
    return 0;
  }
}

class KillSwitchCommand extends Command<int> {
  KillSwitchCommand() {
    argParser
      ..addFlag('on', negatable: false, help: 'Stop all capture and uploads.')
      ..addFlag('off', negatable: false, help: 'Resume capture.')
      ..addOption('sample-rate', help: 'Fraction of production sessions to record (0-1).');
  }

  @override
  String get name => 'capture';
  @override
  String get description => 'Remote capture control: kill switch and production sampling.';

  @override
  Future<int> run() async {
    final a = argResults!;
    final patch = <String, Object?>{
      if (a['on'] as bool) 'enabled': false,
      if (a['off'] as bool) 'enabled': true,
      if (a['sample-rate'] != null) 'sampleRate': double.parse(a['sample-rate'] as String),
    };
    final client = _client();
    final project = patch.isEmpty ? await client.project() : await client.updateConfig(patch);
    final config = project['config'] as Map;
    stdout.writeln('capture ${config['enabled'] == true ? green('enabled') : red('DISABLED (kill switch)')}, '
        'sampleRate ${config['sampleRate']}, bodies ${config['captureNetworkBodies']}');
    return 0;
  }
}
