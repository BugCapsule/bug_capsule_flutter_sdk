import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'backend_client.dart';
import 'patch_client.dart';

const _json = JsonEncoder.withIndent('  ');
typedef PatchProcess =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments,
      String directory,
    );

class PatchCommand extends Command<int> {
  PatchCommand({
    Credentials? credentials,
    void Function(String)? output,
    PatchProcess? process,
    String? directory,
    Map<String, String>? environment,
  }) {
    final localEnvironment =
        Map<String, String>.from(environment ?? Platform.environment)
          ..remove('BUGCAPSULE_PATCH_SESSION_TOKEN')
          ..remove('BUGCAPSULE_TOKEN')
          ..remove('BUGCAPSULE_SECRET_KEY')
          ..remove('BUGCAPSULE_INGEST_KEY');
    final context = _Context(
      credentials,
      output ?? stdout.writeln,
      process ??
          ((exe, args, dir) => Process.run(
            exe,
            args,
            workingDirectory: dir,
            environment: localEnvironment,
            includeParentEnvironment: false,
          )),
      directory ?? Directory.current.path,
      environment ?? Platform.environment,
    );
    for (final operation in [
      'doctor',
      'init',
      'build',
      'inspect',
      'classify',
      'validate',
      'upload',
      'plan',
      'deploy',
      'status',
      'rollback',
    ]) {
      addSubcommand(_PatchOperation(operation, context));
    }
    addSubcommand(_BaseCommand(context));
  }
  @override
  String get name => 'patch';
  @override
  String get description =>
      'Build, review, validate and deliver exact module patches.';
}

class _Context {
  _Context(
    this.credentials,
    this.output,
    this.process,
    this.directory,
    this.environment,
  );
  final Credentials? credentials;
  final void Function(String) output;
  final PatchProcess process;
  final String directory;
  final Map<String, String> environment;
  PatchClient client({String? projectId}) {
    final c = credentials ?? Credentials.load();
    if (c == null) {
      throw StateError(
        'No backend configured. Run bugcapsule login or set BUGCAPSULE_URL and BUGCAPSULE_TOKEN.',
      );
    }
    return PatchClient(
      c,
      sessionToken: environment['BUGCAPSULE_PATCH_SESSION_TOKEN'],
      projectId: projectId ?? environment['BUGCAPSULE_PATCH_PROJECT_ID'],
    );
  }

  String path(String path) => File(path).isAbsolute ? path : '$directory/$path';
}

class _BaseCommand extends Command<int> {
  _BaseCommand(_Context context) {
    addSubcommand(_PatchOperation('register', context));
  }
  @override
  String get name => 'base';
  @override
  String get description =>
      'Register an immutable installed base-build manifest.';
}

class _PatchOperation extends Command<int> {
  _PatchOperation(this.operation, this.context) {
    argParser
      ..addFlag(
        'json',
        negatable: false,
        help: 'Machine-readable result or error envelope.',
      )
      ..addOption(
        'config',
        defaultsTo: 'bugcapsule.patch.json',
        help: 'Local patch configuration.',
      )
      ..addOption(
        'engine',
        help: 'Explicit patch-engine checkout (or BUGCAPSULE_PATCH_ENGINE).',
      )
      ..addOption(
        'project',
        help:
            'Project UUID for an explicit person session and artifact signing.',
      )
      ..addOption(
        'node',
        defaultsTo: 'node',
        help: 'Node executable capable of running the engine TypeScript tools.',
      )
      ..addOption(
        'idempotency-key',
        help: 'Reuse this key only for the exact same mutation.',
      );
    switch (operation) {
      case 'doctor':
        argParser.addFlag(
          'online',
          negatable: false,
          help: 'Also check backend patch access.',
        );
      case 'init':
        argParser
          ..addOption(
            'platform',
            allowed: ['flutter', 'android', 'ios'],
            mandatory: true,
          )
          ..addOption('out', defaultsTo: '.');
      case 'build':
        for (final option in [
          'base',
          'source',
          'patch-id',
          'key',
          'key-id',
          'out',
          'base-rev',
        ]) {
          argParser.addOption(option);
        }
        argParser
          ..addOption('sequence', defaultsTo: '1')
          ..addOption('profile', defaultsTo: 'internal')
          ..addOption('repo', defaultsTo: '.')
          ..addOption('head-rev', defaultsTo: 'HEAD')
          ..addMultiOption('asset')
          ..addMultiOption('surface');
      case 'classify':
        argParser
          ..addOption('registered', mandatory: true)
          ..addOption('repo', defaultsTo: '.')
          ..addOption('base-rev', mandatory: true)
          ..addOption('head-rev', defaultsTo: 'HEAD');
      case 'validate':
        argParser
          ..addMultiOption('capsule')
          ..addOption('affected-digest')
          ..addOption('deadline-hours', defaultsTo: '48')
          ..addOption(
            'evidence',
            help: 'Submit real evidence JSON to the validation ID argument.',
          )
          ..addFlag(
            'get',
            negatable: false,
            help: 'Read a validation ID instead of starting a validation.',
          );
      case 'upload':
        argParser
          ..addOption(
            'state',
            help: 'Resume checkpoint file; defaults to <artifact>.upload.json.',
          )
          ..addOption('change-report')
          ..addOption('source-diff');
      case 'plan':
        argParser
          ..addOption('environment', mandatory: true)
          ..addOption(
            'stages',
            defaultsTo: '100,500,2500,10000',
            help: 'Increasing basis points ending at 10000.',
          );
      case 'deploy':
        argParser
          ..addOption('reason', mandatory: true)
          ..addOption('expected-version', mandatory: true);
      case 'rollback':
        argParser
          ..addOption('reason', mandatory: true)
          ..addOption('expected-version', mandatory: true)
          ..addOption('to-digest')
          ..addFlag('to-base', negatable: false)
          ..addFlag('revoke', negatable: false);
    }
  }
  final String operation;
  final _Context context;
  @override
  String get name => operation;
  @override
  String get description => const {
    'doctor':
        'Check local engine, Node, credentials and optional backend access.',
    'init':
        'Create patch configuration without modifying native application code.',
    'register': 'Register an exact base manifest JSON.',
    'build':
        'Classify committed changes, then compile and sign a patch for an exact base.',
    'inspect': 'Inspect a local .bcpatch using the installed engine.',
    'classify': 'Report patchability of all changes between two commits.',
    'validate':
        'Start/read exact-patch validation or submit real replay evidence; never infer a pass.',
    'upload':
        'Resume an authenticated artifact upload and immutable source review.',
    'plan': 'Create a deployment plan without publishing it.',
    'deploy':
        'Explicitly request deployment, respecting approval and expected version.',
    'status': 'Read deployment state and receipt coverage.',
    'rollback':
        'Publish a version-checked rollback; devices may still be offline.',
  }[operation]!;
  Map<String, Object?> config = {};
  String? requestKey;
  String? option(String name) =>
      argResults!.options.contains(name) ? argResults![name] as String? : null;
  String need(String name) {
    final value =
        option(name) ??
        config[name] as String? ??
        (name == 'project'
            ? context.environment['BUGCAPSULE_PATCH_PROJECT_ID']
            : null);
    if (value == null || value.trim().isEmpty) {
      throw UsageException('--$name is required', usage);
    }
    return value;
  }

  String one() {
    if (argResults!.rest.length != 1) {
      throw UsageException('Expected exactly one argument.', usage);
    }
    return argResults!.rest.single;
  }

  Map<String, Object?> readJson(String path) =>
      (jsonDecode(File(context.path(path)).readAsStringSync()) as Map)
          .cast<String, Object?>();
  String get engine {
    final value =
        option('engine') ??
        context.environment['BUGCAPSULE_PATCH_ENGINE'] ??
        config['engine'] as String?;
    if (value == null || value.isEmpty) {
      throw StateError(
        'Set --engine, BUGCAPSULE_PATCH_ENGINE or engine in bugcapsule.patch.json to an installed patch-engine checkout. No tools are downloaded automatically.',
      );
    }
    final path = context.path(value);
    if (!File('$path/tools/bcpatch.ts').existsSync()) {
      throw StateError('No tools/bcpatch.ts found in $path');
    }
    return path;
  }

  Future<ProcessResult> engineRun(List<String> args) => context.process(
    need('node'),
    ['$engine/tools/bcpatch.ts', ...args],
    context.directory,
  );
  Future<String> git(String repo, List<String> args) async {
    final result = await context.process('git', [
      '-C',
      repo,
      ...args,
    ], context.directory);
    if (result.exitCode != 0) {
      throw StateError('git ${args.first} failed: ${result.stderr}');
    }
    return result.stdout.toString();
  }

  Map<String, Object?> toolJson(ProcessResult result) {
    try {
      return (jsonDecode(result.stdout.toString()) as Map)
          .cast<String, Object?>();
    } on Object {
      throw StateError(
        'Engine exited ${result.exitCode}: ${result.stderr.toString().trim()}',
      );
    }
  }

  Future<Map<String, Object?>> tool(List<String> args) async {
    final result = await engineRun(args);
    final data = toolJson(result);
    if (result.exitCode != 0) {
      throw _CommandFailure(result.exitCode, 'engine_failed', data);
    }
    return data;
  }

  Future<PatchResponse> call(
    String method,
    String path, {
    Object? body,
    List<int>? bytes,
    String? key,
  }) {
    final client = context.client(
      projectId: option('project') ?? config['project'] as String?,
    );
    if (method != 'GET' &&
        ['validate', 'plan', 'deploy', 'rollback'].contains(operation) &&
        client.sessionToken == null) {
      throw PatchApiException(403, {
        'code': 'person_session_required',
        'detail':
            'This action requires a signed-in person, not a persistent CLI/CI credential. Use Emergency Recovery in the dashboard, or supply an ephemeral BUGCAPSULE_PATCH_SESSION_TOKEN from POST /v1/console/auth/login and select --project / BUGCAPSULE_PATCH_PROJECT_ID. It is not saved; backend roles, expiry and second-person approval still apply.',
      });
    }
    return client.request(
      method,
      '/v1/patches$path',
      body: body,
      bytes: bytes,
      idempotencyKey: method == 'GET' ? null : key ?? requestKey,
    );
  }

  Map<String, Object?> response(PatchResponse r) => {
    'httpStatus': r.status,
    'replayed': r.replayed,
    ...r.data,
  };

  @override
  Future<int> run() async {
    try {
      final file = File(context.path(need('config')));
      if (file.existsSync()) config = readJson(file.path);
      requestKey = option('idempotency-key') ?? patchRequestKey();
      if (!RegExp(r'^[A-Za-z0-9_.:-]{8,200}$').hasMatch(requestKey!)) {
        throw UsageException(
          'Invalid --idempotency-key (8–200 letters, digits, _, ., :, -).',
          usage,
        );
      }
      final result = await execute();
      final pending =
          result['result'] == 'approval_required' ||
          ['PENDING', 'RUNNING'].contains(result['status']);
      final failed = [
        'FAILED',
        'REGRESSION_FAILED',
        'INCONCLUSIVE',
        'UNSUPPORTED',
        'CANCELLED',
      ].contains(result['status']);
      final code = failed
          ? 3
          : pending
          ? 2
          : 0;
      context.output(
        _json.convert({
          'ok': !failed,
          'command': 'patch $operation',
          'exitCode': code,
          if (requestKey != null) 'idempotencyKey': requestKey,
          'result': result,
        }),
      );
      return code;
    } on UsageException catch (e) {
      return error(64, 'usage', e.message);
    } on PatchApiException catch (e) {
      return error(
        e.status == 401 || e.status == 403
            ? 77
            : e.status == 409 || e.status == 410
            ? 3
            : 1,
        e.problem['code']?.toString() ?? 'backend_error',
        e.toString(),
        {'httpStatus': e.status, 'problem': e.problem},
      );
    } on _CommandFailure catch (e) {
      return error(e.code, e.reason, e.reason, {'result': e.data});
    } on FileSystemException catch (e) {
      return error(1, 'file_error', e.message);
    } on ProcessException catch (e) {
      return error(1, 'tool_unavailable', e.message);
    } on TimeoutException {
      return error(
        1,
        'timeout',
        'The response was not confirmed. Retry the exact same request with the returned idempotency key.',
      );
    } on SocketException catch (e) {
      return error(1, 'network', e.message);
    } on HttpException catch (e) {
      return error(1, 'network', e.message);
    } on FormatException catch (e) {
      return error(64, 'invalid_input', e.message);
    } on StateError catch (e) {
      return error(1, 'configuration', e.message);
    } on TypeError {
      return error(
        64,
        'invalid_input',
        'Expected an object with the documented field types.',
      );
    } on ArgumentError catch (e) {
      return error(64, 'invalid_input', e.message.toString());
    }
  }

  int error(
    int code,
    String reason,
    String message, [
    Map<String, Object?> extra = const {},
  ]) {
    context.output(
      _json.convert({
        'ok': false,
        'command': 'patch $operation',
        'exitCode': code,
        'error': {'code': reason, 'message': message, ...extra},
        if (requestKey != null) 'idempotencyKey': requestKey,
      }),
    );
    return code;
  }

  Future<Map<String, Object?>> execute() async {
    switch (operation) {
      case 'doctor':
        final node = await context.process(need('node'), [
          '--version',
        ], context.directory);
        if (node.exitCode != 0) throw StateError('Node is unavailable.');
        final enginePath = engine;
        final probeDir = Directory.systemTemp.createTempSync(
          'bugcapsule-patch-doctor-',
        );
        Map<String, Object?> capability;
        try {
          final registry = File('${probeDir.path}/registered.json')
            ..writeAsStringSync('{"modules":[],"surfaces":[]}');
          capability = await tool([
            'capability',
            '--registered',
            registry.path,
          ]);
        } finally {
          probeDir.deleteSync(recursive: true);
        }
        final creds = context.credentials ?? Credentials.load();
        return {
          'engine': enginePath,
          'node': node.stdout.toString().trim(),
          'tokenConfigured': creds?.token != null,
          'capabilityProbe': capability,
          if (argResults!['online'] == true)
            'backend': response(await call('GET', '/bases')),
        };
      case 'init':
        return initialize();
      case 'register':
        return response(await call('POST', '/bases', body: readJson(one())));
      case 'inspect':
        return tool(['inspect', context.path(one())]);
      case 'classify':
        final result = await engineRun([
          'classify',
          '--registered',
          context.path(need('registered')),
          context.path(need('repo')),
          need('base-rev'),
          need('head-rev'),
        ]);
        final data = toolJson(result);
        if (result.exitCode != 0) {
          throw _CommandFailure(
            result.exitCode,
            'classification_refused',
            data,
          );
        }
        return data;
      case 'build':
        return build();
      case 'upload':
        return upload();
      case 'validate':
        final id = Uri.encodeComponent(one());
        if (option('evidence') != null) {
          if (argResults!['get'] == true ||
              (argResults!['capsule'] as List).isNotEmpty) {
            throw UsageException(
              '--evidence cannot be combined with --get or --capsule.',
              usage,
            );
          }
          return response(
            await call(
              'POST',
              '/validations/$id/evidence',
              body: readJson(need('evidence')),
            ),
          );
        }
        if (argResults!['get'] == true) {
          return response(await call('GET', '/validations/$id'));
        }
        final capsules = (argResults!['capsule'] as List<String>)
            .toSet()
            .toList();
        if (capsules.isEmpty) {
          throw UsageException(
            'At least one --capsule is required. The argument is an uploaded artifact ID.',
            usage,
          );
        }
        return response(
          await call(
            'POST',
            '/validations',
            body: {
              'artifactId': one(),
              'capsuleIds': capsules,
              'affectedPatchSetDigest': option('affected-digest'),
              'requireRegressions': true,
              'acceptPartial': false,
              'deadlineHours': positive(need('deadline-hours')),
            },
          ),
        );
      case 'plan':
        final stages = need('stages').split(',').map(positive).toList();
        if (stages.isEmpty ||
            stages.last != 10000 ||
            stages.any((s) => s > 10000) ||
            List.generate(
              stages.length - 1,
              (i) => stages[i] >= stages[i + 1],
            ).contains(true)) {
          throw UsageException(
            'Stages must increase and end at 10000 basis points.',
            usage,
          );
        }
        return response(
          await call(
            'POST',
            '/deployments',
            body: {
              'artifactId': one(),
              'environment': need('environment'),
              'rolloutStages': stages,
            },
          ),
        );
      case 'deploy':
        return response(
          await call(
            'POST',
            '/deployments/${Uri.encodeComponent(one())}/request',
            body: {
              'reason': need('reason'),
              'expectedVersion': positive(need('expected-version')),
            },
          ),
        );
      case 'status':
        final id = Uri.encodeComponent(one());
        return {
          'deployment': response(await call('GET', '/deployments/$id')),
          'receipts': response(await call('GET', '/deployments/$id/receipts')),
          'note':
              'Publication is not activation or fleet health. Missing and stale installation reports remain unknown.',
        };
      case 'rollback':
        if ((option('to-digest') == null) == (argResults!['to-base'] != true)) {
          throw UsageException(
            'Choose exactly one of --to-base or --to-digest.',
            usage,
          );
        }
        return response(
          await call(
            'POST',
            '/deployments/${Uri.encodeComponent(one())}/rollback',
            body: {
              'reason': need('reason'),
              'expectedVersion': positive(need('expected-version')),
              'toArtifactDigest': option('to-digest'),
              'revoke': argResults!['revoke'],
            },
          ),
        );
    }
    throw StateError('Unknown patch operation');
  }

  int positive(String value) {
    final n = int.tryParse(value);
    if (n == null || n < 1) {
      throw UsageException('Expected a positive integer, got $value.', usage);
    }
    return n;
  }

  Map<String, Object?> initialize() {
    final dir = Directory(context.path(need('out')));
    final configFile = File('${dir.path}/bugcapsule.patch.json');
    final registry = File('${dir.path}/patch/registered.json');
    if (configFile.existsSync() || registry.existsSync()) {
      throw StateError(
        'Patch configuration already exists; init never overwrites it.',
      );
    }
    registry.parent.createSync(recursive: true);
    registry.writeAsStringSync(_json.convert({'modules': [], 'surfaces': []}));
    Directory('${dir.path}/patch/modules').createSync(recursive: true);
    configFile.writeAsStringSync(
      _json.convert({
        'platform': need('platform'),
        'source': 'patch/modules',
        'registered': 'patch/registered.json',
        if (option('engine') != null) 'engine': context.path(need('engine')),
      }),
    );
    return {
      'config': configFile.path,
      'registered': registry.path,
      'note':
          'Populate contracts from the actual installed binary, configure an explicit engine checkout and integrate its SDK binding before registering a base. No native application or signing keys were modified.',
    };
  }

  Future<Map<String, Object?>> build() async {
    final repo = Directory(
      context.path(need('repo')),
    ).resolveSymbolicLinksSync();
    final source = Directory(
      context.path(need('source')),
    ).resolveSymbolicLinksSync();
    final head = (await git(repo, [
      'rev-parse',
      '--verify',
      need('head-rev'),
    ])).trim();
    final actualHead = (await git(repo, [
      'rev-parse',
      '--verify',
      'HEAD',
    ])).trim();
    if (head != actualHead ||
        (await git(repo, [
          'status',
          '--porcelain=v1',
          '--untracked-files=all',
        ])).trim().isNotEmpty) {
      throw StateError(
        'Build requires the selected head to be HEAD and a clean committed checkout, including untracked files. Ignore output files before building.',
      );
    }
    final baseRevision = (await git(repo, [
      'rev-parse',
      '--verify',
      need('base-rev'),
    ])).trim();
    final base = (await call(
      'GET',
      '/bases/${Uri.encodeComponent(need('base'))}',
    )).data;
    final inventory = (base['inventory'] as Map).cast<String, Object?>();
    final temp = Directory.systemTemp.createTempSync('bugcapsule-patch-build-');
    try {
      final registered = File('${temp.path}/registered.json')
        ..writeAsStringSync(
          jsonEncode({
            'modules': inventory['modules'],
            'surfaces': inventory['surfaces'] ?? [],
          }),
        );
      final capability = await tool([
        'capability',
        '--registered',
        registered.path,
      ]);
      if (capability['baseCapabilityHash'] != base['capabilityHash'] ||
          capability['hostAbiHash'] != base['hostAbiHash']) {
        throw StateError(
          'Installed engine does not match this base capability or host ABI.',
        );
      }
      final classified = await engineRun([
        'classify',
        '--registered',
        registered.path,
        repo,
        baseRevision,
        head,
      ]);
      final report = toolJson(classified);
      if (classified.exitCode != 0 || report['verdict'] != 'PATCHABLE') {
        throw _CommandFailure(
          report['verdict'] == 'STORE_RELEASE_REQUIRED' ? 3 : 4,
          'classification_refused',
          report,
        );
      }
      final modules =
          Directory(source)
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((f) => f.path.endsWith('.bpl'))
              .map((f) => f.resolveSymbolicLinksSync())
              .toList()
            ..sort();
      final assets = (argResults!['asset'] as List<String>)
          .map((p) => File(context.path(p)).resolveSymbolicLinksSync())
          .toList();
      final surfaces = (argResults!['surface'] as List<String>)
          .map((p) => File(context.path(p)).resolveSymbolicLinksSync())
          .toList();
      final included = {...modules, ...assets, ...surfaces};
      if (included.isEmpty) {
        throw StateError(
          'No module sources or explicit assets/surfaces were selected.',
        );
      }
      if (included.any((p) => !p.startsWith('$repo/'))) {
        throw StateError(
          'All build inputs must be inside the classified repository.',
        );
      }
      for (final raw in report['findings'] as List) {
        final finding = (raw as Map).cast<String, Object?>();
        if (finding['verdict'] == 'PATCHABLE' &&
            !included.contains(
              File('$repo/${finding['path']}').absolute.path,
            )) {
          throw StateError(
            'Classified change ${finding['path']} was not included in the patch; expand --source or add --surface/--asset.',
          );
        }
      }
      final out = context.path(need('out'));
      if (File(out).existsSync() ||
          File('$out.source-diff.json').existsSync()) {
        throw StateError(
          'Build output already exists; choose a new --out path.',
        );
      }
      final args = [
        'pack',
        '--registered',
        registered.path,
        '--project',
        need('project'),
        '--app',
        base['applicationId'] as String,
        '--platform',
        base['platform'] as String,
        '--profile',
        need('profile'),
        '--base-build',
        need('base'),
        '--patch-id',
        need('patch-id'),
        '--sequence',
        positive(need('sequence')).toString(),
        '--key',
        context.path(need('key')),
        '--key-id',
        need('key-id'),
        '--out',
        out,
        for (final p in assets) ...['--asset', p],
        for (final p in surfaces) ...['--surface', p],
        ...modules,
      ];
      final result = await tool(args);
      final diff = await git(repo, [
        'diff',
        '--no-ext-diff',
        '--no-textconv',
        '--binary',
        baseRevision,
        head,
        '--',
      ]);
      final signedCommit = (result['provenance'] as Map?)?['sourceCommit'];
      File? diffFile;
      if (signedCommit == head) {
        diffFile = File('$out.source-diff.json')
          ..writeAsStringSync(
            _json.convert({
              'format': 'unified',
              'baseCommit': baseRevision,
              'headCommit': head,
              'diff': diff,
            }),
          );
      }
      return {
        ...result,
        'artifact': out,
        'classification': report,
        'sourceDiff': diffFile?.path,
        if (diffFile == null)
          'sourceReviewNote':
              'Development provenance is content-bound, not a Git commit. No commit-bound diff was produced; use a non-development profile for release source review.',
      };
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  Future<Map<String, Object?>> upload() async {
    final artifact = File(context.path(one()));
    if (artifact.lengthSync() > 10 * 1024 * 1024) {
      throw StateError('Artifact exceeds the backend 10 MiB bundle limit.');
    }
    final bytes = artifact.readAsBytesSync();
    final sha = patchSha256(bytes);
    final stateFile = File(
      context.path(option('state') ?? '${one()}.upload.json'),
    );
    final client = context.client(
      projectId: option('project') ?? config['project'] as String?,
    );
    final identity = patchSha256(
      utf8.encode(
        client.sessionToken ?? client.credentials.projectCredential ?? '',
      ),
    );
    final finalizeBody = <String, Object?>{
      if (option('change-report') != null)
        'changeReport': readJson(need('change-report')),
      if (option('source-diff') != null)
        'sourceDiff': readJson(need('source-diff')),
    };
    final finalizeHash = patchSha256(utf8.encode(jsonEncode(finalizeBody)));
    final state = stateFile.existsSync()
        ? readJson(stateFile.path)
        : <String, Object?>{
            'sha256': sha,
            'backend': client.credentials.url,
            'credentialHash': identity,
            'finalizeHash': finalizeHash,
            'createKey': requestKey,
            'finalizeKey': patchRequestKey(),
          };
    if (state['sha256'] != sha ||
        state['backend'] != client.credentials.url ||
        state['credentialHash'] != identity ||
        state['finalizeHash'] != finalizeHash) {
      throw StateError(
        'Upload checkpoint belongs to different bytes, backend, credentials or review metadata. Use another --state path.',
      );
    }
    void save() {
      stateFile.parent.createSync(recursive: true);
      final tmp = File('${stateFile.path}.tmp')
        ..writeAsStringSync(_json.convert(state), flush: true);
      tmp.renameSync(stateFile.path);
    }

    save();
    requestKey = state['createKey'] as String;
    if (state['result'] is Map) {
      return {
        ...(state['result'] as Map).cast<String, Object?>(),
        'resumed': true,
      };
    }
    if (state['uploadId'] == null) {
      final created = await call(
        'POST',
        '/uploads',
        body: {'sizeBytes': bytes.length, 'sha256': sha},
        key: state['createKey'] as String,
      );
      state['uploadId'] = created.data['id'];
      save();
    }
    final id = Uri.encodeComponent(state['uploadId'] as String);
    try {
      await call(
        'PUT',
        '/uploads/$id/content',
        bytes: bytes,
        key: state['createKey'] as String,
      );
    } on PatchApiException catch (e) {
      if (e.problem['reason'] != 'upload_finalized') rethrow;
    }
    final finished = response(
      await call(
        'POST',
        '/uploads/$id/finalize',
        body: finalizeBody,
        key: state['finalizeKey'] as String,
      ),
    );
    state['result'] = finished;
    save();
    return {...finished, 'uploadState': stateFile.path};
  }
}

class _CommandFailure implements Exception {
  _CommandFailure(this.code, this.reason, this.data);
  final int code;
  final String reason;
  final Map<String, Object?> data;
}
