import '../version.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import '../core/core.dart';

import 'backend_client.dart';
import 'browser_login.dart';
import 'capsule_source.dart';
import 'gate.dart';
import 'git.dart';
import 'inspect.dart';
import 'launcher.dart';
import 'processes.dart';
import 'patch_commands.dart';
import 'project_config.dart';
import 'replay.dart';
import 'replay_server.dart';
import 'symbols.dart';
import 'term.dart';

const version = bugCapsuleVersion;

CommandRunner<int> buildRunner() =>
    CommandRunner<int>('bugcapsule', 'Inspect, replay and verify capsules.')
      ..argParser.addFlag(
        'version',
        negatable: false,
        help: 'Print the version.',
      )
      ..addCommand(InspectCommand())
      ..addCommand(ReplayCommand(ReplayKind.replay))
      ..addCommand(ReplayCommand(ReplayKind.verify))
      ..addCommand(RegressCommand())
      ..addCommand(GateCommand())
      ..addCommand(LoginCommand())
      ..addCommand(LogoutCommand())
      ..addCommand(ListCommand())
      ..addCommand(PullCommand())
      ..addCommand(PushCommand())
      ..addCommand(ShareCommand())
      ..addCommand(KillSwitchCommand())
      ..addCommand(SymbolsCommand())
      ..addCommand(PatchCommand());

Future<int> runBugCapsule(List<String> args) async {
  final runner = buildRunner();
  try {
    final parsed = runner.parse(args);
    if (parsed['version'] == true) {
      stdout.writeln(
        'bugcapsule $version (capsule spec v${CapsuleCodec.specVersion})',
      );
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
  if (rest.length != 1) {
    throw UsageException('expected exactly one $what', c.usage);
  }
  return rest.single;
}

BackendClient _client() {
  final creds = Credentials.load();
  if (creds == null) {
    throw StateError(
      'no backend configured; run `bugcapsule login --url ... --token ...`',
    );
  }
  return BackendClient(creds);
}

// ------------------------------------------------------------------ inspect

class InspectCommand extends Command<int> {
  InspectCommand() {
    argParser
      ..addFlag('json', negatable: false, help: 'Print the manifest as JSON.')
      ..addOption(
        'timeline',
        defaultsTo: '40',
        help: 'Number of timeline events to show.',
      );
  }

  @override
  String get name => 'inspect';
  @override
  String get description =>
      'Show what a capsule contains: failure, eligibility, network, timeline.';
  @override
  String get invocation => 'bugcapsule inspect <file | capsule-id | share-url>';

  @override
  Future<int> run() async {
    final loaded = await loadCapsule(_rest(this, 'capsule'));
    printInspect(
      loaded.capsule,
      timeline: int.parse(argResults!['timeline'] as String),
      json: argResults!['json'] as bool,
    );
    return 0;
  }
}

// ------------------------------------------------------------- run / verify

/// `--patch-artifact`, with `--patch-keyring` and `--patch-keyring-signature`
/// for a delegated signer. A named file that can't be read stops the run:
/// replaying the bare base instead would prove nothing about the patch.
PatchArchive? _patchArchive(ArgResults args) {
  if (!args.options.contains('patch-artifact')) return null;
  final path = args['patch-artifact'] as String?;
  final keyring = args['patch-keyring'] as String?;
  final signature = args['patch-keyring-signature'] as String?;
  if ((keyring == null) != (signature == null)) {
    throw UsageException('--patch-keyring and --patch-keyring-signature go together', '');
  }
  if (path == null) {
    if (keyring != null) throw UsageException('a keyring needs --patch-artifact', '');
    return null;
  }
  return PatchArchive(
    File(path).readAsBytesSync(),
    keyring: keyring == null ? null : File(keyring).readAsBytesSync(),
    keyringSignature: signature == null ? null : File(signature).readAsBytesSync(),
  );
}

void _addPatchOptions(ArgParser p) {
  p
    ..addOption('patch-artifact', help: 'Pin every attempt to this .bcpatch. Without it the attempt runs the bare base.')
    ..addOption('patch-keyring', help: 'The archived keyring authorizing a delegated signer.')
    ..addOption('patch-keyring-signature', help: 'The raw root signature of --patch-keyring.');
}

void _addLaunchOptions(ArgParser p, {bool release = true}) {
  p
    ..addOption(
      'runtime',
      allowed: ProjectConfig.runtimes,
      help:
          'App runtime (default: "runtime" in bugcapsule.json, else detected from the project).',
    )
    ..addOption(
      'device',
      abbr: 'd',
      help: 'Device id or name (default: first simulator/emulator).',
    )
    ..addOption(
      'project',
      abbr: 'p',
      defaultsTo: '.',
      help: 'App project directory.',
    )
    ..addOption(
      'target',
      abbr: 't',
      defaultsTo: 'lib/main.dart',
      help: 'Entry point (flutter).',
    )
    ..addOption('flavor', help: 'Build flavor (flutter).')
    ..addMultiOption(
      'dart-define',
      help: 'Extra --dart-define values (KEY=VALUE, flutter).',
    )
    ..addOption(
      'apk',
      help: 'Prebuilt app APK (android); skips the Gradle build.',
    )
    ..addOption('test-apk', help: 'Prebuilt instrumentation APK (android).')
    ..addOption(
      'xctestrun',
      help:
          'Prebuilt .xctestrun from build-for-testing (ios); skips the build.',
    )
    ..addOption(
      'app-url',
      help: 'URL of an already running web app (web); skips build and serve.',
    )
    ..addOption(
      'attempt-timeout',
      help: 'Seconds per attempt (default: recorded duration + settle + 45s).',
    )
    ..addFlag(
      'lan',
      negatable: false,
      help: 'Bind the replay server on the LAN (physical devices).',
    )
    ..addOption(
      'strategy',
      allowed: ['auto', 'pointer', 'semantic'],
      defaultsTo: 'auto',
      help: 'How input is replayed.',
    )
    ..addOption(
      'settle',
      defaultsTo: '8',
      help: 'Seconds to wait for the failure after the last input.',
    )
    ..addFlag(
      'lenient-network',
      negatable: false,
      help:
          'Send unrecorded requests to the real network instead of failing them.',
    )
    ..addFlag(
      'compress-idle',
      defaultsTo: true,
      help:
          'Skip long idle gaps between inputs (recorded network latency is always kept).',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Show build and device output.',
    );
  if (release) {
    p
      ..addOption(
        'release',
        help:
            'Release of the build under test, <appId>@<version>+<build> '
            '(default: read from the build).',
      )
      ..addOption(
        'environment',
        help: 'Environment the run is recorded for (e.g. staging).',
      );
  }
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
    throw StateError(
      'cannot tell the runtime of $project; pass --runtime or add ${ProjectConfig.fileName}',
    );
  }
  return (config, runtime);
}

/// Stops child processes and runs cleanups on Ctrl-C, then exits 130.
StreamSubscription<ProcessSignal> _onInterrupt(
  Future<void> Function() cleanup,
) => ProcessSignal.sigint.watch().listen((_) async {
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
  if (raw != null) {
    return Duration(milliseconds: (double.parse(raw) * 1000).round());
  }
  return config.attemptTimeout;
}

Map<String, String> _defines(ArgResults args, String? sha, bool dirty) => {
  'BUGCAPSULE_GIT_SHA': ?sha,
  if (sha != null) 'BUGCAPSULE_GIT_DIRTY': '$dirty',
  for (final d in args['dart-define'] as List<String>)
    if (d.contains('='))
      d.substring(0, d.indexOf('=')): d.substring(d.indexOf('=') + 1),
};

class ReplayCommand extends Command<int> {
  ReplayCommand(this.kind) {
    _addLaunchOptions(argParser);
    argParser.addOption(
      'runs',
      abbr: 'n',
      defaultsTo: kind == ReplayKind.replay ? '3' : '5',
      help: 'Attempts.',
    );
    if (kind == ReplayKind.replay) {
      argParser.addFlag(
        'pin',
        defaultsTo: true,
        help: "Build the capsule's git commit in a temporary worktree.",
      );
    }
    argParser.addOption(
      'report-to',
      help:
          'Backend capsule id to record the result on (automatic for backend capsules).',
    );
    _addPatchOptions(argParser);
  }

  final ReplayKind kind;

  @override
  String get name => kind == ReplayKind.replay ? 'run' : 'verify';
  @override
  String get description => kind == ReplayKind.replay
      ? 'Replay a capsule on a simulator/emulator and check the failure happens again.'
      : 'Replay a capsule on the current (patched) code and check the failure is gone.';
  @override
  String get invocation =>
      'bugcapsule $name <file | capsule-id | share-url> [options]';

  @override
  Future<int> run() async {
    final args = argResults!;
    final loaded = await loadCapsule(
      _rest(this, 'capsule'),
      serverId: args['report-to'] as String?,
    );
    final m = loaded.capsule.manifest;
    stdout.writeln(
      '${bold('Capsule')} ${shortId(m.capsuleId)}  ${m.app.version}+${m.app.build}  '
      '${m.platform.os}  ${dim(m.mode.name)}',
    );
    stdout.writeln(
      '${bold('Failure')} ${m.failure == null ? yellow('none') : red(m.failure!.signature)}',
    );
    if (m.eligibility.status != EligibilityStatus.eligible) {
      stdout.writeln(
        '${bold('Eligibility')} ${yellow(m.eligibility.status.name)}: '
        '${m.eligibility.missing.map((x) => x.dependency).join(', ')}',
      );
    }

    final project = args['project'] as String;
    final (config, runtime) = _runtimeFor(args, project);
    stdout.writeln(
      '${bold('Runtime')} $runtime'
      '${loaded.capsule.manifest.runtime == null ? '' : dim('  (captured: ${m.runtimeName} ${m.runtime?.version ?? ''})')}',
    );
    final attempts = int.parse(args['runs'] as String);
    final mismatch = runtimeMismatch(loaded.capsule, runtime);
    if (mismatch != null) {
      final summary = incompatibleSummary(
        kind,
        attempts,
        mismatch,
        runtime: runtime,
      );
      printSummary(summary, loaded.capsule);
      await _report(loaded, summary, runtime, null);
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
    final device = runtime == 'flutter'
        ? await pickDevice(args['device'] as String?)
        : null;
    if (device != null) stdout.writeln('${bold('Device')} $device');

    final server = await ReplayServer.start(lan: args['lan'] as bool);
    final launcher = AppLauncher.forOptions(
      LaunchOptions(
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
      ),
    );
    final interrupt = _onInterrupt(() async {
      await launcher.dispose();
      await server.close();
    });
    try {
      await launcher.prepare(server);
      if (device == null) {
        stdout.writeln('${bold('Target')} ${launcher.target}');
      }
      final summary = await replayCapsule(
        loaded: loaded,
        launcher: launcher,
        server: server,
        kind: kind,
        attempts: attempts,
        strategy: ReplayStrategy.values.byName(args['strategy'] as String),
        settleTimeoutMs: (double.parse(args['settle'] as String) * 1000)
            .round(),
        strictNetwork: !(args['lenient-network'] as bool),
        idleCompression: args['compress-idle'] as bool,
        buildSha: buildSha,
        runtime: runtime,
        attemptTimeout: _attemptTimeout(args, config),
            patch: _patchArchive(args),
      );
      printSummary(summary, loaded.capsule);
      await _report(loaded, summary, launcher.target, launcher.release);
      return exitCodeFor(summary);
    } finally {
      await interrupt.cancel();
      await launcher.dispose();
      await server.close();
      await Processes.stopAll();
    }
  }

  Future<void> _report(
    LoadedCapsule loaded,
    ReplaySummary s,
    String device,
    AppRelease? built,
  ) async {
    final id = loaded.serverId;
    final creds = Credentials.load();
    if (id == null || creds?.projectCredential == null) return;
    final release = argResults!['release'] as String? ?? built?.toString();
    try {
      await BackendClient(creds!).createRun(
        id,
        s.runPayload(
          device: device,
          release: release,
          environment: argResults!['environment'] as String?,
        ),
      );
      stdout.writeln(
        dim(
          'Recorded on backend capsule $id (${s.wireOutcome}'
          '${release == null ? '' : ', $release'})',
        ),
      );
    } catch (e) {
      stdout.writeln(yellow('! could not record result on backend: $e'));
    }
  }
}

// --------------------------------------------------------------------- gate

/// Builds the launcher for a gate (tests replace it).
typedef LauncherFactory = AppLauncher Function(LaunchOptions options);

/// `bugcapsule gate` (verification.md §3.3): verifies every capsule a
/// release must not reproduce against one build, records the runs with the
/// release, posts the gate report and fails CI by `--fail-on`.
class GateCommand extends Command<int> {
  GateCommand({LauncherFactory? launcherFactory})
    : _launcher = launcherFactory {
    _addLaunchOptions(argParser, release: false);
    _addPatchOptions(argParser);
    argParser
      ..addOption(
        'release',
        help:
            'The release this build is, <appId>@<version>+<build> (required).',
      )
      ..addOption(
        'platform',
        allowed: ProjectConfig.runtimes,
        help: 'Which capsules to verify, by runtime (required).',
      )
      ..addOption(
        'scope',
        allowed: ['all', 'fixes', 'regressions'],
        defaultsTo: 'all',
        help:
            'fixes: capsules of issues resolved in this release or earlier; '
            'regressions: capsules already fixed that must stay fixed.',
      )
      ..addOption('issue', help: 'Only the capsules of this issue id.')
      ..addOption('attempts', defaultsTo: '3', help: 'Attempts per capsule.')
      ..addOption(
        'fail-on',
        defaultsTo: GateOutcomes.defaultFailOn.join(','),
        help:
            'Outcomes that fail the gate: reproduced, flaky, error '
            '(error: a capsule could not run).',
      )
      ..addOption('junit', help: 'Write JUnit XML to this file.')
      ..addFlag(
        'json',
        negatable: false,
        help: 'Print the result as JSON on stdout (progress goes to stderr).',
      )
      ..addOption(
        'environment',
        help: 'Environment the runs are recorded for (e.g. staging).',
      )
      ..addOption(
        'token',
        help: 'Service token (bcv_…); default: \$BUGCAPSULE_TOKEN or login.',
      )
      ..addOption(
        'url',
        help: 'Backend URL; default: \$BUGCAPSULE_URL or login.',
      );
  }

  final LauncherFactory? _launcher;

  @override
  String get name => 'gate';
  @override
  String get description =>
      'Release gate for CI: verify that a build does not reproduce the bugs '
      'fixed in its release (or earlier), and report it.';
  @override
  String get invocation =>
      'bugcapsule gate --release <appId>@<version>+<build> --platform <runtime> [options]';

  @override
  Future<int> run() async {
    final args = argResults!;
    final release = args['release'] as String?;
    final platform = args['platform'] as String?;
    if (release == null || release.isEmpty || release.length > 200) {
      throw UsageException(
        '--release is required (at most 200 characters)',
        usage,
      );
    }
    if (platform == null) throw UsageException('--platform is required', usage);
    final attempts = int.tryParse(args['attempts'] as String) ?? 0;
    if (attempts < 1 || attempts > 100) {
      throw UsageException('--attempts must be 1-100', usage);
    }
    final failOn = {
      for (final v in (args['fail-on'] as String).split(','))
        if (v.trim().isNotEmpty) v.trim(),
    };
    final unknown = failOn.difference(GateOutcomes.failOnValues.toSet());
    if (unknown.isNotEmpty) {
      throw UsageException(
        '--fail-on takes ${GateOutcomes.failOnValues.join(', ')} (got ${unknown.join(', ')})',
        usage,
      );
    }
    final json = args['json'] as bool;
    final realStdout = stdout;
    // With --json, stdout carries only the JSON document.
    final (code, document) = await IOOverrides.runZoned(
      () => _gate(args, release, platform, attempts, failOn),
      stdout: json ? () => stderr : null,
    );
    if (json) realStdout.writeln(document);
    return code;
  }

  Credentials _credentials(ArgResults args) {
    final saved = Credentials.load();
    final url = args['url'] as String? ?? saved?.url;
    if (url == null) {
      throw StateError(
        'no backend: pass --url or set BUGCAPSULE_URL (and BUGCAPSULE_TOKEN)',
      );
    }
    final token = args['token'] as String?;
    return Credentials(
      url: url,
      token: token ?? saved?.token,
      secretKey: token == null ? saved?.secretKey : null,
      ingestKey: saved?.ingestKey,
    );
  }

  Future<(int, String)> _gate(
    ArgResults args,
    String release,
    String platform,
    int attempts,
    Set<String> failOn,
  ) async {
    final scope = args['scope'] as String;
    final client = BackendClient(_credentials(args));
    final startedAt = DateTime.now();
    final plan = await client.verificationPlan(
      release: release,
      platform: platform,
      scope: scope,
      issue: args['issue'] as String?,
    );
    final items = [
      for (final i in (plan['items'] as List?) ?? const [])
        GateItem.fromJson((i as Map).cast<String, Object?>()),
    ];
    // The backend sends at most 10 capsules per issue and 200 in all.
    final truncated = plan['truncated'] == true;
    stdout.writeln(
      '${bold('Gate')} $release  ${dim('$platform, scope $scope, ${items.length} capsule${items.length == 1 ? '' : 's'}')}',
    );
    if (truncated) {
      stderr.writeln(
        yellow(
          '! the plan left some capsules out (at most 10 per issue and 200 '
          'in all); narrow it with --scope or --issue to check the rest',
        ),
      );
    }

    final project = args['project'] as String;
    final git = await gitInfo(project);
    final gitSha = git?.head;
    final results = <GateResult>[];
    final errors = <String>[];
    if (items.isEmpty) {
      stdout.writeln(
        green('✓ nothing to verify for $release ($platform): the gate passes'),
      );
    } else {
      await _verifyAll(
        args,
        client,
        items,
        results,
        errors,
        release: release,
        attempts: attempts,
        git: git,
      );
    }
    final finishedAt = DateTime.now();
    var code = gateExitCode(results, failOn);
    final passed = code == 0;
    String? reportId;
    try {
      final report = await client.createGateReport(
        gateReport(
          release: release,
          platform: platform,
          gitSha: gitSha,
          results: results,
          passed: passed,
          startedAt: startedAt,
          finishedAt: finishedAt,
          requirePatchedIdentity: args['patch-artifact'] != null,
        ),
      );
      reportId = report['id'] as String?;
    } on Object catch (e) {
      errors.add('could not post the gate report: $e');
    }

    if (results.isNotEmpty) {
      stdout
        ..writeln('')
        ..writeln(gateTable(results, failOn).join('\n'));
    }
    final junit = args['junit'] as String?;
    if (junit != null) {
      File(junit)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          gateJunit(
            release: release,
            platform: platform,
            gitSha: gitSha,
            results: results,
            failOn: failOn,
            startedAt: startedAt,
            finishedAt: finishedAt,
            truncated: truncated,
          ),
        );
      stdout.writeln(dim('JUnit: $junit'));
    }
    for (final e in errors) {
      stderr.writeln(red('backend: $e'));
    }
    // A gate that could not record its result fails (backend errors exit 1).
    if (errors.isNotEmpty) code = 1;
    stdout.writeln(
      '${bold('Result:')} ${code == 0 ? green('PASSED') : red('FAILED')}'
      '${reportId == null ? '' : dim('  report $reportId')}',
    );
    return (
      code,
      gateJson(
        release: release,
        platform: platform,
        scope: scope,
        gitSha: gitSha,
        results: results,
        passed: passed,
        exitCode: code,
        reportId: reportId,
        truncated: truncated,
        errors: errors,
      ),
    );
  }

  /// Builds once, then verifies each item and records its run.
  Future<void> _verifyAll(
    ArgResults args,
    BackendClient client,
    List<GateItem> items,
    List<GateResult> results,
    List<String> errors, {
    required String release,
    required int attempts,
    required GitInfo? git,
  }) async {
    final project = args['project'] as String;
    final (config, runtime) = _runtimeFor(args, project);
    final artifacts = _artifacts(args);
    final buildSha = artifacts.isEmpty ? git?.head : null;
    final dirty = artifacts.isEmpty && (git?.dirty ?? false);
    final device = runtime == 'flutter' && _launcher == null
        ? await pickDevice(args['device'] as String?)
        : null;
    final options = LaunchOptions(
      runtime: runtime,
      config: config,
      projectDir: project,
      target: args['target'] as String,
      device: device,
      deviceQuery: args['device'] as String?,
      dartDefines: _defines(args, buildSha, dirty),
      flavor: args['flavor'] as String?,
      verbose: args['verbose'] as bool,
      buildSha: buildSha,
      dirty: dirty,
      artifacts: artifacts,
    );
    final launcher = (_launcher ?? AppLauncher.forOptions)(options);
    final server = await ReplayServer.start(lan: args['lan'] as bool);
    final interrupt = _onInterrupt(() async {
      await launcher.dispose();
      await server.close();
    });
    try {
      try {
        await launcher.prepare(server);
      } catch (e) {
        final why = 'build failed: ${e is StateError ? e.message : e}';
        stderr.writeln(red(why));
        results.addAll([
          for (final item in items)
            GateResult(item, GateOutcomes.error, error: why),
        ]);
        return;
      }
      stdout.writeln('${bold('Target')} ${launcher.target}');
      final built = launcher.release?.toString();
      if (built != null && built != release) {
        stdout.writeln(
          yellow('! the build says $built; runs are recorded for $release'),
        );
      }
      for (final item in items) {
        stdout.writeln(
          '\n${bold(item.reason == 'fix' ? 'Fix' : 'Regression')} '
          '${shortId(item.capsuleId)}  ${item.issueTitle ?? item.issueId ?? ''}',
        );
        final started = DateTime.now();
        final LoadedCapsule loaded;
        try {
          final bytes = await client.downloadCapsule(item.capsuleId);
          loaded = LoadedCapsule(
            bytes,
            CapsuleCodec.decode(bytes),
            serverId: item.capsuleId,
            origin: 'backend',
          );
        } on ApiException catch (e) {
          errors.add('could not download capsule ${item.capsuleId}: $e');
          results.add(GateResult(item, GateOutcomes.error, error: '$e'));
          continue;
        } on CapsuleFormatException catch (e) {
          results.add(GateResult(item, 'incompatible', error: e.message));
          continue;
        }
        final mismatch = runtimeMismatch(loaded.capsule, runtime);
        final ReplaySummary summary;
        if (mismatch != null) {
          summary = incompatibleSummary(
            ReplayKind.verify,
            attempts,
            mismatch,
            runtime: runtime,
          );
        } else {
          summary = await replayCapsule(
            loaded: loaded,
            launcher: launcher,
            server: server,
            kind: ReplayKind.verify,
            attempts: attempts,
            strategy: ReplayStrategy.values.byName(args['strategy'] as String),
            settleTimeoutMs: (double.parse(args['settle'] as String) * 1000)
                .round(),
            strictNetwork: !(args['lenient-network'] as bool),
            idleCompression: args['compress-idle'] as bool,
            buildSha: buildSha,
            runtime: runtime,
            attemptTimeout: _attemptTimeout(args, config),
            patch: _patchArchive(args),
          );
        }
        String? runId;
        try {
          final run = await client.createRun(
            item.capsuleId,
            summary.runPayload(
              device: launcher.target,
              release: release,
              environment: args['environment'] as String?,
            ),
          );
          runId = run['id'] as String?;
        } on Object catch (e) {
          errors.add('could not record the run of ${item.capsuleId}: $e');
        }
        results.add(
          GateResult(
            item,
            summary.wireOutcome,
            runId: runId,
            summary: summary,
            durationMs: DateTime.now().difference(started).inMilliseconds,
          ),
        );
      }
    } finally {
      await interrupt.cancel();
      await launcher.dispose();
      await server.close();
      await Processes.stopAll();
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
  String get description =>
      'Keep fixed capsules as regression tests and run them (e.g. in CI).';
}

class RegressionSuite {
  RegressionSuite(this.projectDir)
    : _file = File('$projectDir/bugcapsule/regressions.json');

  final String projectDir;
  final File _file;

  List<Map<String, Object?>> load() {
    if (!_file.existsSync()) return [];
    final json = jsonDecode(_file.readAsStringSync()) as Map;
    return [
      for (final t in json['tests'] as List) (t as Map).cast<String, Object?>(),
    ];
  }

  void save(List<Map<String, Object?>> tests) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'version': 1, 'tests': tests})}\n',
    );
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
  String get description =>
      'Add a capsule to the regression suite (bugcapsule/regressions).';

  @override
  Future<int> run() async {
    final loaded = await loadCapsule(_rest(this, 'capsule'));
    final m = loaded.capsule.manifest;
    if (m.failure == null) {
      throw StateError(
        'capsule has no failure assertion; it cannot guard a regression',
      );
    }
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
    stdout.writeln(
      '${green('✓')} added $relative (${tests.length} tests). Commit it with your fix.',
    );
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
      stdout.writeln(
        'No regression tests. Add one with `bugcapsule regress add <capsule>`.',
      );
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
      stdout.writeln(
        '${shortId('${t['capsuleId']}')}  ${colored.padRight(12)}  ${t['name']}'
        '${last == null ? '' : dim('  last: ${last['result']} ${last['at']}')}',
      );
    }
    return 0;
  }
}

class _RegressRun extends Command<int> {
  _RegressRun() {
    _addLaunchOptions(argParser);
    argParser
      ..addOption(
        'runs',
        abbr: 'n',
        defaultsTo: '2',
        help: 'Attempts per test.',
      )
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
        .where(
          (t) =>
              t['status'] == 'active' ||
              (includeQ && t['status'] == 'quarantined'),
        )
        .toList();
    if (selected.isEmpty) {
      stdout.writeln('No active regression tests.');
      return 0;
    }
    final (config, runtime) = _runtimeFor(args, project);
    final artifacts = _artifacts(args);
    final device = runtime == 'flutter'
        ? await pickDevice(args['device'] as String?)
        : null;
    final first = await loadCapsule('$project/${selected.first['file']}');
    final (projectDir, sha, dirty) = artifacts.isNotEmpty
        ? (project, null, false)
        : await resolveTree(
            first,
            projectDir: project,
            kind: ReplayKind.verify,
            pin: false,
          );
    final server = await ReplayServer.start(lan: args['lan'] as bool);
    final launcher = AppLauncher.forOptions(
      LaunchOptions(
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
      ),
    );
    final interrupt = _onInterrupt(() async {
      suite.save(tests);
      await launcher.dispose();
      await server.close();
    });
    var failed = 0;
    try {
      await launcher.prepare(server);
      for (final t in selected) {
        stdout.writeln(
          '\n${bold('${t['name']}')} ${dim(shortId('${t['capsuleId']}'))}',
        );
        final loaded = await loadCapsule('$project/${t['file']}');
        final mismatch = runtimeMismatch(loaded.capsule, runtime);
        final s = mismatch != null
            ? incompatibleSummary(
                ReplayKind.verify,
                int.parse(args['runs'] as String),
                mismatch,
                runtime: runtime,
              )
            : await replayCapsule(
                loaded: loaded,
                launcher: launcher,
                server: server,
                kind: ReplayKind.verify,
                attempts: int.parse(args['runs'] as String),
                strategy: ReplayStrategy.values.byName(
                  args['strategy'] as String,
                ),
                settleTimeoutMs: (double.parse(args['settle'] as String) * 1000)
                    .round(),
                strictNetwork: !(args['lenient-network'] as bool),
                idleCompression: args['compress-idle'] as bool,
                buildSha: sha,
                runtime: runtime,
                attemptTimeout: _attemptTimeout(args, config),
            patch: _patchArchive(args),
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
          case Verdict.inconclusive ||
              Verdict.reproduced ||
              Verdict.notReproduced:
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
          if (s.evaluation.reasons.isNotEmpty)
            'reasons': s.evaluation.reasons.take(10).toList(),
        };
        stdout.writeln(
          '  → ${result == 'pass'
              ? green(result)
              : result == 'fail'
              ? red(result)
              : yellow(result)}',
        );
      }
    } finally {
      await interrupt.cancel();
      suite.save(tests);
      await launcher.dispose();
      await server.close();
      await Processes.stopAll();
    }
    stdout.writeln();
    stdout.writeln(
      failed == 0
          ? green('All ${selected.length} regression capsules pass.')
          : red('$failed of ${selected.length} regression capsules fail.'),
    );
    return failed == 0 ? 0 : 1;
  }
}

// ------------------------------------------------------------------ backend

class LoginCommand extends Command<int> {
  LoginCommand() {
    argParser
      ..addOption(
        'url',
        help:
            'Backend URL (default: BUGCAPSULE_URL, then the saved login, then $defaultBackendUrl).',
      )
      ..addFlag(
        'browser',
        defaultsTo: true,
        help:
            'Open the sign-in page in the browser. With --no-browser, only print its address '
            '(to open on another device, e.g. over SSH).',
      )
      ..addOption(
        'token',
        help:
            'Sign in without a browser: a personal token (bcp_...) from Project Settings › Keys & CLI access, '
            'or a service token (bcv_...) in CI.',
      )
      ..addOption(
        'secret-key',
        help: 'Legacy: the project secret key (bcs_...), shared full access.',
      )
      ..addOption(
        'ingest-key',
        help: 'Project ingest key (bci_...), for `bugcapsule push`.',
      );
  }

  @override
  String get name => 'login';
  @override
  String get description =>
      'Sign in through the browser (or with a token) and save it to ~/.bugcapsule/config.json.';

  @override
  Future<int> run() async {
    final saved = Credentials.loadFile();
    final url =
        argResults!['url'] as String? ??
        Platform.environment['BUGCAPSULE_URL'] ??
        saved?.url ??
        defaultBackendUrl;
    var token = argResults!['token'] as String?;
    var secretKey = argResults!['secret-key'] as String?;
    final ingestKey = argResults!['ingest-key'] as String?;
    if (token == null && secretKey == null && ingestKey == null) {
      return _browserLogin(url, saved);
    }
    if (token != null && secretKey != null) {
      throw UsageException('use --token or --secret-key, not both', usage);
    }
    // A token given as --secret-key (CLI 0.4.1-beta.1 docs) is stored as a token.
    if (token == null && secretKey != null && Credentials.isToken(secretKey)) {
      token = secretKey;
      secretKey = null;
    }
    if (token != null &&
        (token.startsWith('bcsdk.') || token.startsWith('bct_'))) {
      throw UsageException(
        'that is an SDK token: it goes in your app (BugCapsule.init), not in the CLI. '
        'Run `bugcapsule login` without --token to sign in through the browser.',
        usage,
      );
    }
    if (token != null && !Credentials.isToken(token)) {
      throw UsageException(
        '--token takes a personal (bcp_...) or service (bcv_...) token; a bcs_ project key goes in --secret-key',
        usage,
      );
    }
    final creds = Credentials(
      url: url,
      token: token,
      secretKey: secretKey,
      ingestKey: ingestKey,
    );
    if (creds.projectCredential != null) {
      final project = await BackendClient(creds).project();
      final how = token == null
          ? 'the shared project secret key (legacy)'
          : token.startsWith('bcp_')
          ? 'your personal token'
          : 'a service token';
      stdout.writeln(
        '${green('✓')} project "${project['name']}" (${project['id']}) with $how',
      );
    }
    creds.save();
    stdout.writeln('Saved ${Credentials.file.path}');
    return 0;
  }

  Future<int> _browserLogin(String url, Credentials? saved) async {
    if (Platform.environment['CI'] != null) {
      throw UsageException(
        'browser sign-in needs a person; in CI use a service token: bugcapsule login --token bcv_...',
        usage,
      );
    }
    final BrowserLoginResult r;
    try {
      r = await BrowserLogin(
        url: url,
        launch: argResults!['browser'] as bool,
      ).run();
    } on BrowserLoginException catch (e) {
      stderr.writeln(red('✗ ${e.message}'));
      return 1;
    }
    // The ingest key for `bugcapsule push` stays when signing in to the same backend again.
    Credentials(
      url: url,
      token: r.token,
      ingestKey: saved?.url == url ? saved?.ingestKey : null,
    ).save();
    stdout
      ..writeln()
      ..writeln(
        '${green('✓')} Signed in as ${r.email} to project "${r.projectName}" (${r.projectId})',
      )
      ..writeln(
        dim(
          '  Personal token saved to ${Credentials.file.path}, valid until ${r.expiresAt.substring(0, 10)}. '
          'Run `bugcapsule logout` to revoke it.',
        ),
      );
    if (Platform.environment['BUGCAPSULE_TOKEN'] != null) {
      stdout.writeln(
        yellow(
          '  BUGCAPSULE_TOKEN is set in this shell and wins over the saved login; unset it to use this one.',
        ),
      );
    }
    return 0;
  }
}

class LogoutCommand extends Command<int> {
  @override
  String get name => 'logout';
  @override
  String get description =>
      'Revoke the CLI’s personal token and remove it from ~/.bugcapsule/config.json.';

  @override
  Future<int> run() async {
    final saved = Credentials.loadFile();
    if (saved == null || saved.projectCredential == null) {
      stdout.writeln('Not signed in.');
      return 0;
    }
    final token = saved.token;
    if (token != null && token.startsWith('bcp_')) {
      try {
        await BackendClient(saved).revokeOwnToken();
        stdout.writeln('${green('✓')} Revoked the personal token.');
      } on Object catch (e) {
        // Already revoked or expired, or the backend is unreachable: the local copy still goes.
        stdout.writeln(
          yellow(
            'Couldn’t revoke the token on the backend ($e); revoke it in Project Settings › Keys & CLI access if it still shows.',
          ),
        );
      }
    }
    Credentials(url: saved.url, ingestKey: saved.ingestKey).save();
    stdout.writeln(
      'Signed out. Removed the project credential from ${Credentials.file.path}.',
    );
    return 0;
  }
}

class ListCommand extends Command<int> {
  ListCommand() {
    argParser
      ..addOption(
        'status',
        allowed: [
          'new',
          'reproduced',
          'not_reproduced',
          'fixed',
          'ineligible',
          'archived',
        ],
      )
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
      stdout.writeln(
        '${c['id']}  ${'${c['status']}'.padRight(14)} ${'${c['eligibility']}'.padRight(10)} '
        '${dim('${c['mode']} ${c['appVersion']}+${c['appBuild']} ${c['platform']}')}  '
        '${c['failureSignature'] ?? dim('(manual)')}',
      );
    }
    return 0;
  }
}

class PullCommand extends Command<int> {
  PullCommand() {
    argParser.addOption(
      'output',
      abbr: 'o',
      help: 'File to write (default: <capsuleId>.bugcapsule).',
    );
  }

  @override
  String get name => 'pull';
  @override
  String get description => 'Download a capsule from the backend.';

  @override
  Future<int> run() async {
    final loaded = await loadCapsule(_rest(this, 'capsule id or share URL'));
    final out =
        argResults!['output'] as String? ??
        '${loaded.capsule.manifest.capsuleId}.bugcapsule';
    File(out).writeAsBytesSync(loaded.bytes);
    stdout.writeln('${green('✓')} $out (${loaded.bytes.length} bytes)');
    return 0;
  }
}

class PushCommand extends Command<int> {
  @override
  String get name => 'push';
  @override
  String get description =>
      'Upload a local capsule file to the backend (uses the ingest key).';

  @override
  Future<int> run() async {
    final loaded = await loadCapsule(_rest(this, 'file'));
    final res = await _client().upload(loaded.bytes);
    stdout.writeln(
      '${green('✓')} ${res['id']} (${res['status']}, ${res['eligibility']})',
    );
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
  String get description =>
      'Create an expiring download link for a backend capsule.';

  @override
  Future<int> run() async {
    final res = await _client().share(
      _rest(this, 'capsule id'),
      int.parse(argResults!['hours'] as String),
    );
    stdout.writeln('${res['url']}\n${dim('expires ${res['expiresAt']}')}');
    return 0;
  }
}

class KillSwitchCommand extends Command<int> {
  KillSwitchCommand() {
    argParser
      ..addFlag('on', negatable: false, help: 'Stop all capture and uploads.')
      ..addFlag('off', negatable: false, help: 'Resume capture.')
      ..addOption(
        'sample-rate',
        help: 'Fraction of production sessions to record (0-1).',
      );
  }

  @override
  String get name => 'capture';
  @override
  String get description =>
      'Remote capture control: kill switch and production sampling.';

  @override
  Future<int> run() async {
    final a = argResults!;
    final patch = <String, Object?>{
      if (a['on'] as bool) 'enabled': false,
      if (a['off'] as bool) 'enabled': true,
      if (a['sample-rate'] != null)
        'sampleRate': double.parse(a['sample-rate'] as String),
    };
    final client = _client();
    final project = patch.isEmpty
        ? await client.project()
        : await client.updateConfig(patch);
    final config = project['config'] as Map;
    stdout.writeln(
      'capture ${config['enabled'] == true ? green('enabled') : red('DISABLED (kill switch)')}, '
      'sampleRate ${config['sampleRate']}, bodies ${config['captureNetworkBodies']}',
    );
    return 0;
  }
}
