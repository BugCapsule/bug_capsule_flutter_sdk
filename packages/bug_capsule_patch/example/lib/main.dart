import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'performance_harness.dart';
import 'smoke.dart';
import 'trust_config.dart';

const baseBuildId = String.fromEnvironment(
  'BCPATCH_BASE_BUILD',
  defaultValue: 'flutter-demo-1',
);
const moduleOnly = bool.fromEnvironment('BCPATCH_MODULE_ONLY');
const applicationId = String.fromEnvironment(
  'BCPATCH_APPLICATION_ID',
  defaultValue: 'dev.bugcapsule.patchlab.flutter',
);
const environment = String.fromEnvironment(
  'BCPATCH_ENVIRONMENT',
  defaultValue: 'staging',
);
const trustAnchor =
    'bcpk.v1.dev-root-1.BA4PNvbk7UmdPR93U56lG_Bpqwq3WgzIrI3zk7IuT-hKhRymUfOY4eQFQGei0tjUkzmpyqaHCZf3MtgxbBxq68U';

typedef Line = ({String sku, int qty, int unitCents});
typedef Cart = ({List<Line> lines, int couponPercent});
typedef Priced = ({
  String subtotal,
  String discount,
  String total,
  String label,
});

String _money(int cents) {
  final abs = cents.abs();
  return '${cents < 0 ? '-' : ''}${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}

/// The shipped behavior, with the bug the patch fixes: the percentage is
/// applied without dividing by 100.
Priced bundledCoupon(Cart cart) {
  final subtotal = cart.lines.fold<int>(
    0,
    (acc, l) => acc + l.unitCents * l.qty,
  );
  final discount = subtotal * cart.couponPercent;
  return (
    subtotal: _money(subtotal),
    discount: _money(discount),
    total: _money(subtotal - discount),
    label: 'BASE ${cart.couponPercent}%',
  );
}

final coupon = PatchModule<Cart, Priced>(
  id: 'pricing.coupon',
  inputSchema:
      'rec(couponPercent:int,lines:list(rec(qty:int,sku:str,unitPrice:dec(2))))',
  outputSchema: 'rec(discount:dec(2),label:str,subtotal:dec(2),total:dec(2))',
  encode: (c) => {
    'couponPercent': c.couponPercent,
    'lines': [
      for (final l in c.lines)
        {'sku': l.sku, 'qty': l.qty, 'unitPrice': _money(l.unitCents)},
    ],
  },
  decode: (o) {
    final m = o! as Map<String, Object?>;
    return (
      subtotal: m['subtotal']! as String,
      discount: m['discount']! as String,
      total: m['total']! as String,
      label: m['label']! as String,
    );
  },
  fallback: bundledCoupon,
);

const sample = (
  couponPercent: 20,
  lines: <Line>[
    (sku: 'a', qty: 2, unitCents: 1999),
    (sku: 'b', qty: 10, unitCents: 300),
  ],
);

const summarySurface = PatchSurfaceContract(
  id: 'lab.summary',
  components: ['column', 'row', 'text', 'spacer', 'button'],
  actions: ['lab.pay'],
  requiredActions: ['lab.pay'],
);

const labSurfaces = moduleOnly ? <PatchSurfaceContract>[] : [summarySurface];

Future<Directory> _exchangeDir() async {
  // Android: readable by adb on a release build. iOS: reachable with devicectl.
  if (Platform.isAndroid) return (await getExternalStorageDirectory())!;
  return getApplicationDocumentsDirectory();
}

/// Applies whatever the delivery harness dropped. Takes effect next launch.
List<String> processInbox(BugCapsulePatch patch, Directory exchange) {
  final log = <String>[];
  // The app owns its inbox: on Android 11+ a directory created by adb is not
  // listable by the app. An unreadable inbox is logged, never fatal.
  final inbox = Directory('${exchange.path}/inbox');
  final List<File> files;
  try {
    inbox.createSync(recursive: true);
    files = inbox.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  } on FileSystemException catch (e) {
    return log..add('inbox unreadable: ${e.osError?.message ?? e.message}');
  }
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    try {
      if (name.endsWith('.channel')) {
        final sig = File('${f.path}.sig');
        log.add(
          'channel ${jsonEncode(patch.applyChannel(f.readAsBytesSync(), sig.readAsBytesSync()))}',
        );
        sig.deleteSync();
        f.deleteSync();
      } else if (name.endsWith('.bcpatch')) {
        log.add('stage ${jsonEncode(patch.stage(f.readAsBytesSync()))}');
        f.deleteSync();
      }
    } on Object catch (e) {
      log.add('rejected $name: $e');
      f.deleteSync();
    }
  }
  return log;
}

Future<void> main() async {
  PerformanceHarness.clock.start();
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final exchange = await _exchangeDir();
  // Test-only: an acceptance run points the lab at a real backend. Without
  // this file the lab uses its file inbox. The base build id stays the binary's.
  final remoteFile = File('${exchange.path}/patch-config.json');
  final remote = remoteFile.existsSync()
      ? jsonDecode(remoteFile.readAsStringSync()) as Map<String, Object?>
      : null;
  final platform = Platform.isAndroid ? 'flutter_android' : 'flutter_ios';
  PatchConfig patchConfig() => PatchConfig(
    storeDir: '${support.path}/bcpatch',
    projectId: remote?['projectId'] as String? ?? 'demo',
    applicationId: applicationId,
    environment: environment,
    platform: platform,
    distributionProfile: 'development',
    baseBuildId: baseBuildId,
    installationId: 'device-1',
    trustRoots: labTrustRoots(remote, trustAnchor),
  );
  BugCapsulePatch openPatch() => BugCapsulePatch.open(
    patchConfig(),
    modules: [coupon],
    surfaces: labSurfaces,
  );
  if (PerformanceHarness.enabled(exchange)) {
    try {
      final benchmark = PerformanceHarness.run(
        exchange: exchange,
        module: coupon,
        input: sample,
        open: openPatch,
        output: (p) => {
          'subtotal': p.subtotal,
          'discount': p.discount,
          'total': p.total,
          'label': p.label,
        },
      );
      final record = benchmark.record;
      record['baseBuildId'] = baseBuildId;
      record['state'] = 'BENCHMARK';
      record['evalMicros'] = (record['firstCallNs']! as int) ~/ 1000;
      runApp(PatchLab(record, benchmark.patch));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!PerformanceHarness.enabled(exchange)) return;
        record['appCodeToFirstPostFrameNs'] = PerformanceHarness.nowNs;
        record['rssAtFirstPostFrame'] = PerformanceHarness.rss();
        PerformanceHarness.write(exchange, record);
      });
    } on Object catch (e) {
      final file = File('${exchange.path}/benchmark-result.json');
      if (!file.existsSync()) {
        PerformanceHarness.write(exchange, {
          'correctness': 'failed',
          'error': '$e',
        });
      }
      runApp(MaterialApp(home: Scaffold(body: Text('Benchmark failed: $e'))));
    }
    return;
  }
  // Test-only, opt-in: a local acceptance run turns on BugCapsule monitoring so
  // the SDK's own release-health sessions carry the running patch identity.
  // The binding then owns the one runtime of this process.
  final monitoringFile = File('${exchange.path}/monitoring-config.json');
  final monitoring = monitoringFile.existsSync()
      ? jsonDecode(monitoringFile.readAsStringSync()) as Map<String, Object?>
      : null;
  BugCapsulePatchBinding? binding;
  NativeProbe? probe;
  if (monitoring != null) {
    binding = BugCapsulePatchBinding(
      patchConfig(),
      modules: [coupon],
      surfaces: labSurfaces,
    );
    probe = NativeProbe.install();
    await BugCapsule.init(
      config: BugCapsuleConfig(
        backend: BugCapsuleBackendConfig(
          url: monitoring['backendUrl']! as String,
          ingestKey: monitoring['ingestKey']! as String,
        ),
        mode: CaptureMode.qa,
        gitSha: 'patchlab',
        autoCaptureOnFailure: false,
        patchBinding: binding,
        monitoring: MonitoringOptions(
          release:
              monitoring['release'] as String? ??
              'dev.bugcapsule.patchlab.flutter@1.0+1',
          environment: 'staging',
        ),
      ),
      appRunner: () {},
    );
  }
  final patch = binding?.patch ?? openPatch();
  final watch = Stopwatch()..start();
  final result = patch.call(coupon, sample);
  final micros = watch.elapsedMicroseconds;
  final before = patch.available
      ? patch.status()
      : <String, Object?>{
          'state': 'UNAVAILABLE',
          'reason': patch.unavailableReason,
        };
  final inbox = patch.available ? processInbox(patch, exchange) : <String>[];
  // Only a patched result that passes the app's own smoke check is healthy.
  var health = <String, Object?>{'checked': false};
  if (patch.available && result.source == PatchSource.patched) {
    final why = smokeFailure(
      lines: [
        for (final l in sample.lines) (qty: l.qty, unitCents: l.unitCents),
      ],
      couponPercent: sample.couponPercent,
      subtotal: result.value.subtotal,
      discount: result.value.discount,
      total: result.value.total,
      label: result.value.label,
    );
    if (why != null) {
      health = {'checked': true, 'ok': false, 'reason': why};
    } else {
      try {
        health = {
          'checked': true,
          'ok': true,
          'markHealthy': patch.markHealthy('first_screen'),
        };
      } on Object catch (e) {
        health = {'checked': true, 'ok': true, 'markHealthyError': '$e'};
      }
    }
  }
  final record = {
    'at': DateTime.now().toUtc().toIso8601String(),
    'mode': const bool.fromEnvironment('dart.vm.product') ? 'release' : 'debug',
    'platform': Platform.operatingSystem,
    'baseBuildId': baseBuildId,
    'source': result.source.name,
    'reason': result.reason,
    'output': {
      'subtotal': result.value.subtotal,
      'discount': result.value.discount,
      'total': result.value.total,
      'label': result.value.label,
    },
    'evalMicros': micros,
    'state': before['state'],
    'running': before['running'],
    'inbox': inbox,
    'health': health,
    'monitoring': binding == null ? 'off' : 'on',
    'status': patch.available ? patch.status() : null,
  };
  runApp(PatchLab(record, patch));
  if (remote != null) {
    final transport = TimedPatchTransport(
      HttpPatchTransport(
        baseUrl: remote['baseUrl']! as String,
        deliveryToken: remote['deliveryToken']! as String,
        applicationId: applicationId,
        platform: platform,
        distributionProfile: 'development',
        baseBuildId: baseBuildId,
        installationId: 'device-1',
      ),
    );
    final updater = PatchUpdater(patch, transport);
    final updateStart = PerformanceHarness.nowNs;
    final r = await updater.checkForUpdate();
    final updateNs = PerformanceHarness.nowNs - updateStart;
    final receiptStart = PerformanceHarness.nowNs;
    var sent = -1;
    try {
      sent = await updater.flushReceipts();
    } on Object catch (e) {
      record['receiptError'] = '$e';
    }
    if (remote['measurePerformance'] == true) {
      record['deliveryPerformance'] = {
        'checkVerifyStageNs': updateNs,
        'flushReceiptsNs': PerformanceHarness.nowNs - receiptStart,
        'artifactFetches': transport.artifactFetches,
        'scope':
            'whole transport download/buffering; update includes metadata, verification and staging; no cold-cache claim',
      };
    }
    record['update'] = {
      'state': r.state.name,
      'artifactDigest': r.artifactDigest,
      'reason': r.reason,
      'receiptsSent': sent,
    };
    record['status'] = patch.status();
    if (binding != null) {
      // Telemetry runs end the release-health session in order and send it
      // before the result is recorded: the harness then stops the process,
      // which must not read as an abnormal session. Wait until the app is
      // resumed (so no later resume opens another session), end and send it,
      // then close monitoring.
      var resumed = false;
      for (var i = 0; i < 100 && !resumed; i++) {
        resumed =
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        if (!resumed) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      record['resumed'] = resumed;
      record['nativeCrash'] =
          probe?.started ?? {'started': false, 'reporter': 'none'};
      // Acceptance only, telemetry mode only: a one-shot genuine native crash
      // (abort) while this session is open. The flag is removed first, so the
      // next launch runs normally and the SDK's native crash handling is what
      // reports it.
      final crashFlag = File('${exchange.path}/crash-once');
      if (!resumed) {
        // Fail visibly: the harness rejects a record without a resumed app.
        record['lifecycleError'] =
            'app not resumed within 5 s; session left open';
      } else {
        if (crashFlag.existsSync()) {
          crashFlag.deleteSync();
          deliberateNativeAbort();
        }
        BugCapsule.endSession();
        record['sessionFlushed'] = await BugCapsule.flush(
          const Duration(seconds: 10),
        );
        await BugCapsule.close();
      }
    }
  }
  File('${exchange.path}/results.jsonl').writeAsStringSync(
    '${jsonEncode(record)}\n',
    mode: FileMode.append,
    flush: true,
  );
}

/// Acceptance only: a real SIGABRT in this process (no Dart error handling).
void deliberateNativeAbort() {
  final libc = Platform.isAndroid
      ? DynamicLibrary.open('libc.so')
      : DynamicLibrary.process();
  libc.lookupFunction<Void Function(), void Function()>('abort')();
}

/// Telemetry runs record what the native crash handling reported at start
/// (handler installed, previous run crashed); it delegates everything.
class NativeProbe implements NativeCrashReporter {
  NativeProbe._(this._inner);

  /// Wraps the reporter `bug_capsule_native` registered. Without one, the
  /// recorded state says so.
  static NativeProbe? install() {
    final inner = NativeCrashReporter.instance;
    if (inner == null) return null;
    final probe = NativeProbe._(inner);
    NativeCrashReporter.instance = probe;
    return probe;
  }

  final NativeCrashReporter _inner;
  Map<String, Object?> started = {'started': false};

  @override
  Future<NativeCrashStart> start(NativeCrashSettings settings) async {
    final s = await _inner.start(settings);
    started = {
      'started': true,
      'handlerInstalled': s.handlerInstalled,
      'lastRunCrashed': s.lastRunCrashed,
    };
    return s;
  }

  @override
  Future<void> collectPending() => _inner.collectPending();

  @override
  Future<void> stop() => _inner.stop();

  @override
  void updateScope(String scopeJson) => _inner.updateScope(scopeJson);

  @override
  Stream<NativeCrashEvent> get events => _inner.events;
}

class PatchLab extends StatelessWidget {
  const PatchLab(this.record, this.patch, {super.key});

  final Map<String, Object?> record;
  final BugCapsulePatch? patch;

  @override
  Widget build(BuildContext context) {
    final output = record['output']! as Map<String, Object?>;
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Patch Lab · Flutter')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Source: ${record['source']}'),
            Text('State: ${record['state']}'),
            Text('Label: ${output['label']}'),
            Text('Subtotal: ${output['subtotal']}'),
            Text('Discount: ${output['discount']}'),
            Text('Total: ${output['total']}'),
            Text('Eval: ${record['evalMicros']} µs'),
            const SizedBox(height: 24),
            if (patch != null && !moduleOnly)
              PatchSurfaceView(
                patch: patch!,
                id: summarySurface.id,
                actions: {'lab.pay': () {}},
                bundled: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Bundled summary'),
                    FilledButton(onPressed: () {}, child: const Text('Pay')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
