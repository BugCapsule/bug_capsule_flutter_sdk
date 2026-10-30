import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

const baseBuildId = String.fromEnvironment('BCPATCH_BASE_BUILD', defaultValue: 'flutter-demo-1');
const trustAnchor = 'bcpk.v1.dev-root-1.BA4PNvbk7UmdPR93U56lG_Bpqwq3WgzIrI3zk7IuT-hKhRymUfOY4eQFQGei0tjUkzmpyqaHCZf3MtgxbBxq68U';

typedef Line = ({String sku, int qty, int unitCents});
typedef Cart = ({List<Line> lines, int couponPercent});
typedef Priced = ({String subtotal, String discount, String total, String label});

String _money(int cents) {
  final abs = cents.abs();
  return '${cents < 0 ? '-' : ''}${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}

/// The shipped behavior, with the bug the patch fixes: the percentage is
/// applied without dividing by 100.
Priced bundledCoupon(Cart cart) {
  final subtotal = cart.lines.fold<int>(0, (acc, l) => acc + l.unitCents * l.qty);
  final discount = subtotal * cart.couponPercent;
  return (subtotal: _money(subtotal), discount: _money(discount), total: _money(subtotal - discount), label: 'BASE ${cart.couponPercent}%');
}

final coupon = PatchModule<Cart, Priced>(
  id: 'pricing.coupon',
  inputSchema: 'rec(couponPercent:int,lines:list(rec(qty:int,sku:str,unitPrice:dec(2))))',
  outputSchema: 'rec(discount:dec(2),label:str,subtotal:dec(2),total:dec(2))',
  encode: (c) => {
    'couponPercent': c.couponPercent,
    'lines': [
      for (final l in c.lines) {'sku': l.sku, 'qty': l.qty, 'unitPrice': _money(l.unitCents)},
    ],
  },
  decode: (o) {
    final m = o! as Map<String, Object?>;
    return (subtotal: m['subtotal']! as String, discount: m['discount']! as String, total: m['total']! as String, label: m['label']! as String);
  },
  fallback: bundledCoupon,
);

const sample = (
  couponPercent: 20,
  lines: <Line>[(sku: 'a', qty: 2, unitCents: 1999), (sku: 'b', qty: 10, unitCents: 300)],
);

const summarySurface = PatchSurfaceContract(
  id: 'lab.summary',
  components: ['column', 'row', 'text', 'spacer', 'button'],
  actions: ['lab.pay'],
  requiredActions: ['lab.pay'],
);

Future<Directory> _exchangeDir() async {
  // Android: readable by adb on a release build. iOS: reachable with devicectl.
  if (Platform.isAndroid) return (await getExternalStorageDirectory())!;
  return getApplicationDocumentsDirectory();
}

/// Applies whatever the delivery harness dropped. Takes effect next launch.
List<String> processInbox(BugCapsulePatch patch, Directory exchange) {
  final log = <String>[];
  final inbox = Directory('${exchange.path}/inbox');
  if (!inbox.existsSync()) return log;
  final files = inbox.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    try {
      if (name.endsWith('.channel')) {
        final sig = File('${f.path}.sig');
        log.add('channel ${jsonEncode(patch.applyChannel(f.readAsBytesSync(), sig.readAsBytesSync()))}');
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
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final exchange = await _exchangeDir();
  // Test-only: an acceptance run points the lab at a real backend. Without
  // this file the lab uses its file inbox. The base build id stays the binary's.
  final remoteFile = File('${exchange.path}/patch-config.json');
  final remote = remoteFile.existsSync() ? jsonDecode(remoteFile.readAsStringSync()) as Map<String, Object?> : null;
  const applicationId = 'dev.bugcapsule.patchlab.flutter';
  final platform = Platform.isAndroid ? 'flutter_android' : 'flutter_ios';
  final patch = BugCapsulePatch.open(
    PatchConfig(
      storeDir: '${support.path}/bcpatch',
      projectId: remote?['projectId'] as String? ?? 'demo',
      applicationId: applicationId,
      environment: 'staging',
      platform: platform,
      distributionProfile: 'development',
      baseBuildId: baseBuildId,
      installationId: 'device-1',
      trustRoots: [remote?['trustRoot'] as String? ?? trustAnchor],
    ),
    modules: [coupon],
    surfaces: const [summarySurface],
  );
  final watch = Stopwatch()..start();
  final result = patch.call(coupon, sample);
  final micros = watch.elapsedMicroseconds;
  final before = patch.available ? patch.status() : <String, Object?>{'state': 'UNAVAILABLE', 'reason': patch.unavailableReason};
  final inbox = patch.available ? processInbox(patch, exchange) : <String>[];
  final smokeOk = result.value.total.isNotEmpty;
  if (patch.available && smokeOk) patch.markHealthy('first_screen');
  final record = {
    'at': DateTime.now().toUtc().toIso8601String(),
    'mode': const bool.fromEnvironment('dart.vm.product') ? 'release' : 'debug',
    'platform': Platform.operatingSystem,
    'baseBuildId': baseBuildId,
    'source': result.source.name,
    'reason': result.reason,
    'output': {'subtotal': result.value.subtotal, 'discount': result.value.discount, 'total': result.value.total, 'label': result.value.label},
    'evalMicros': micros,
    'state': before['state'],
    'running': before['running'],
    'inbox': inbox,
    'status': patch.available ? patch.status() : null,
  };
  runApp(PatchLab(record, patch));
  if (remote != null) {
    final updater = PatchUpdater(
      patch,
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
    final r = await updater.checkForUpdate();
    var sent = -1;
    try {
      sent = await updater.flushReceipts();
    } on Object catch (e) {
      record['receiptError'] = '$e';
    }
    record['update'] = {'state': r.state.name, 'artifactDigest': r.artifactDigest, 'reason': r.reason, 'receiptsSent': sent};
    record['status'] = patch.status();
  }
  File('${exchange.path}/results.jsonl').writeAsStringSync('${jsonEncode(record)}\n', mode: FileMode.append, flush: true);
}

class PatchLab extends StatelessWidget {
  const PatchLab(this.record, this.patch, {super.key});

  final Map<String, Object?> record;
  final BugCapsulePatch patch;

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
            PatchSurfaceView(
              patch: patch,
              id: summarySurface.id,
              actions: {'lab.pay': () {}},
              bundled: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [const Text('Bundled summary'), FilledButton(onPressed: () {}, child: const Text('Pay'))],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
