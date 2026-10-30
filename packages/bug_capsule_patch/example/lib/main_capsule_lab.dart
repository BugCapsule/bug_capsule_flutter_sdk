import 'dart:io';
import 'dart:convert';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart' show coupon, processInbox, sample, summarySurface, trustAnchor;

const baseBuildId = String.fromEnvironment('BCPATCH_BASE_BUILD', defaultValue: 'flutter-demo-1');
const projectId = String.fromEnvironment('BCPATCH_PROJECT_ID', defaultValue: 'demo');
const profile = String.fromEnvironment('BCPATCH_PROFILE', defaultValue: 'development');
const pinnedRoot = String.fromEnvironment('BCPATCH_TRUST_ANCHOR', defaultValue: trustAnchor);
const installationId = String.fromEnvironment('BCPATCH_INSTALLATION_ID', defaultValue: 'device-1');
const gitSha = String.fromEnvironment('BUGCAPSULE_GIT_SHA', defaultValue: 'capsule-lab');

/// Captures a real failure on whatever patch is active, for replay acceptance.
/// A negative total fails an assertion, so a replay reproduces it exactly when
/// the pinned module still has the bug.
void main() {
  if (profile != 'development' && !RegExp(r'^[0-9a-f]{40}$').hasMatch(gitSha)) {
    throw StateError('nondevelopment capture requires explicit BUGCAPSULE_GIT_SHA');
  }
  late Directory exchange;
  final binding = BugCapsulePatchBinding.deferred(() async {
    final support = await getApplicationSupportDirectory();
    exchange = Platform.isAndroid ? (await getExternalStorageDirectory())! : await getApplicationDocumentsDirectory();
    return PatchConfig(
      storeDir: '${support.path}/bcpatch-capsule',
      projectId: projectId,
      applicationId: 'dev.bugcapsule.patchlab.flutter',
      environment: 'staging',
      platform: Platform.isAndroid ? 'flutter_android' : 'flutter_ios',
      distributionProfile: profile,
      baseBuildId: baseBuildId,
      installationId: installationId,
      trustRoots: const [pinnedRoot],
    );
  }, modules: [coupon], surfaces: const [summarySurface]);
  BugCapsule.init(
    config: BugCapsuleConfig(appVersion: '1.0.0', appBuild: '1', mode: CaptureMode.qa, gitSha: gitSha, autoCaptureOnFailure: false, patchBinding: binding),
    appRunner: () => runApp(CapsuleLab(binding, exchange)),
  );
}

class CapsuleLab extends StatefulWidget {
  const CapsuleLab(this.binding, this.exchange, {super.key});

  final BugCapsulePatchBinding binding;
  final Directory exchange;

  @override
  State<CapsuleLab> createState() => _CapsuleLabState();
}

class _CapsuleLabState extends State<CapsuleLab> {
  String _total = '';

  void _checkout() {
    final result = widget.binding.patch.call(coupon, sample);
    setState(() => _total = result.value.total);
    BugCapsule.check('order.total_positive', !result.value.total.startsWith('-'), 'negative order total');
  }

  @override
  void initState() {
    super.initState();
    if (BugCapsule.isReplaying) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final patch = widget.binding.patch;
      processInbox(patch, widget.exchange);
      patch.markHealthy('first_screen');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      BugCapsule.action('lab.checkout', _checkout)();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final captured = await BugCapsule.capture();
      if (captured != null) await captured.file.copy('${widget.exchange.path}/lab.bugcapsule');
      File('${widget.exchange.path}/capture.txt').writeAsStringSync('${patch.status()['running']}');
      final beforeUpdate = patch.status();
      PatchUpdateResult? update;
      var receipts = 0;
      final configFile = File('${widget.exchange.path}/acceptance-config.json');
      if (configFile.existsSync()) {
        final config = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
        final backendUrl = config['backendUrl'] as String;
        final deliveryToken = config['deliveryToken'] as String;
        final transport = HttpPatchTransport(
          baseUrl: backendUrl, deliveryToken: deliveryToken,
          applicationId: 'dev.bugcapsule.patchlab.flutter',
          platform: Platform.isAndroid ? 'flutter_android' : 'flutter_ios',
          distributionProfile: profile, baseBuildId: baseBuildId,
          installationId: installationId,
        );
        final updater = PatchUpdater(patch, transport);
        update = await updater.checkForUpdate();
        receipts = await updater.flushReceipts();
      }
      File('${widget.exchange.path}/acceptance.json').writeAsStringSync(jsonEncode({
        'gitSha': gitSha, 'total': _total, 'beforeUpdate': beforeUpdate,
        'afterUpdate': patch.status(), 'update': update?.state.name,
        'updateReason': update?.reason, 'receiptsFlushed': receipts,
      }));
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Total: $_total'),
            FilledButton(onPressed: BugCapsule.action('lab.checkout', _checkout), child: const Text('Check out')),
          ],
        ),
      ),
    ),
  );
}
