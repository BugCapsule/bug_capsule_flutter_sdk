// Opt-in actual SDK/native-runtime -> actual localhost backend integration.
// No mocked envelope transport, session payloads, engine identity, or clock.
import 'dart:convert';
import 'dart:io';
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/backend.dart';
import 'package:bug_capsule/src/runtime/monitoring/hub.dart';
import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter_test/flutter_test.dart';

final module = PatchModule<Map<String, Object?>, Map<String, Object?>>(
  id: 'pricing.coupon',
  inputSchema:
      'rec(couponPercent:int,lines:list(rec(qty:int,sku:str,unitPrice:dec(2))))',
  outputSchema: 'rec(discount:dec(2),label:str,subtotal:dec(2),total:dec(2))',
  encode: (v) => v,
  decode: (v) => (v! as Map).cast<String, Object?>(),
  fallback: (_) => {
    'subtotal': '69.98',
    'discount': '1399.60',
    'total': '-1329.62',
    'label': 'BASE 20%',
  },
);
final input = <String, Object?>{
  'couponPercent': 20,
  'lines': [
    {'sku': 'a', 'qty': 2, 'unitPrice': '19.99'},
    {'sku': 'b', 'qty': 10, 'unitPrice': '3.00'},
  ],
};

class ObservedTransport implements EnvelopeTransport {
  ObservedTransport(this.real, this.evidence);
  final BugCapsuleBackendClient real;
  final List<Map<String, Object?>> evidence;
  @override
  Future<UploadResult> sendEnvelope(List<int> bytes) async {
    final result = await real.sendEnvelope(bytes);
    final decoded = jsonDecode(utf8.decode(gzip.decode(bytes)));
    evidence.add({
      'envelope': decoded,
      'status': result.status.name,
      'httpStatus': result.httpStatus,
    });
    return result;
  }
}

void main() {
  final statePath = Platform.environment['BCPATCH_SESSION_STATE'];
  test(
    'actual host SDK sessions drive a real backend rollout',
    () async {
      final p = (jsonDecode(File(statePath!).readAsStringSync()) as Map)
          .cast<String, Object?>();
      final phase = Platform.environment['BCPATCH_SESSION_PHASE']!;
      final root = Directory('${p['directory']}/sdk');
      root.createSync(recursive: true);
      final observations = <Map<String, Object?>>[];
      final backend = BugCapsuleBackendConfig(
        url: p['url']! as String,
        ingestKey: (p['project']! as Map)['ingestKey'] as String,
      );
      final client = BugCapsuleBackendClient(backend);
      final wire = ObservedTransport(client, observations);
      final artifact = p['artifact']! as Map;
      final expectedDigest = (artifact['identity'] as Map)['patchSetDigest'];
      BugCapsulePatchBinding binding(String id) => BugCapsulePatchBinding(
        PatchConfig(
          storeDir: '${root.path}/$id/runtime',
          projectId: p['projectId']! as String,
          applicationId: p['applicationId']! as String,
          environment: 'staging',
          platform: 'flutter_ios',
          distributionProfile: 'development',
          baseBuildId: p['baseBuildId']! as String,
          installationId: id,
          trustRoots: [p['trustRoot']! as String],
        ),
        modules: [module],
        libraryPath: Platform.environment['BCPATCH_HOST_LIB'],
      );
      Future<void> update(BugCapsulePatchBinding b) async {
        final updater = PatchUpdater(
          b.patch,
          HttpPatchTransport(
            baseUrl: p['url']! as String,
            deliveryToken: (p['delivery']! as Map)['token'] as String,
            applicationId: p['applicationId']! as String,
            platform: 'flutter_ios',
            distributionProfile: 'development',
            baseBuildId: p['baseBuildId']! as String,
            installationId: b.config.installationId,
          ),
        );
        final result = await updater.checkForUpdate();
        expect(result.state, PatchUpdateState.restartRequired);
      }

      Future<void> session(
        String id, {
        required bool patched,
        bool crash = false,
        bool leaveOpen = false,
        bool delivery = false,
      }) async {
        var b = binding(id);
        if (delivery &&
            b.identity!.patchSetDigest != (patched ? expectedDigest : null)) {
          await update(b);
          b.patch
              .close(); // Models process shutdown before next-launch activation.
          b = binding(id);
        }
        expect(b.patch.available, true);
        expect(b.identity!.patchSetDigest, patched ? expectedDigest : null);
        final evaluated = b.patch.call(module, input);
        expect(
          evaluated.source,
          patched ? PatchSource.patched : PatchSource.bundled,
        );
        expect(evaluated.value['total'], patched ? '54.78' : '-1329.62');
        b.patch.markHealthy('host_session_output_verified');
        final config = BugCapsuleConfig(
          appId: p['applicationId']! as String,
          appVersion: '1.0.0',
          appBuild: '1',
          backend: backend,
          patchBinding: b,
        );
        final hub = MonitoringHub(
          options: MonitoringOptions(
            release: p['release']! as String,
            environment: 'staging',
            enableNativeCrashHandling: false,
            captureIsolateErrors: false,
            enableFramesTracking: false,
            enableAppStartTracking: false,
            enableAppHangTracking: false,
          ),
          host: MonitoringHost(
            config: config,
            redactor: Redactor.new,
            remote: () => null,
            uploadsAllowed: () => true,
            ensureFreshConfig: () async {},
            refreshConfig: () async {},
            writeCapsule: (_, _) async => null,
            isRecording: () => true,
            patchIdentity: () => b.identity,
          ),
          sdkVersion: 'host-proof-74e6aad',
          startedAt: DateTime.now(),
          storage: Directory('${root.path}/$id/monitor')
            ..createSync(recursive: true),
          transport: wire,
        );
        await hub.start();
        expect(await hub.flush(), true);
        if (crash) {
          hub.capture(
            hub.prepareException(
              StateError('controlled host crash health signal'),
              StackTrace.current,
              mechanism: Mechanism.uncaught,
            ),
          );
        }
        if (!leaveOpen) hub.endSession();
        expect(await hub.flush(), true);
        await hub.dispose();
        b.patch.close();
      }

      try {
        if (phase == 'healthy') {
          for (final id in ['patched-1', 'patched-2']) {
            await session(id, patched: true, delivery: true);
          }
          for (final id in ['control-1', 'control-2']) {
            await session(id, patched: false);
          }
        } else if (phase == 'crash' || phase == 'breach') {
          await session(
            'patched-1',
            patched: true,
            crash: true,
            delivery: phase == 'breach',
          );
          await session(
            'patched-2',
            patched: true,
            leaveOpen: true,
            delivery: phase == 'breach',
          );
          if (phase == 'breach') {
            for (final id in ['control-1', 'control-2']) {
              await session(id, patched: false);
            }
          }
        } else if (phase == 'rollback') {
          await session('patched-1', patched: false, delivery: true);
          await session('patched-2', patched: false, delivery: true);
        } else {
          throw StateError('unknown phase');
        }
        final sessions = observations
            .expand((o) => ((o['envelope'] as Map)['items'] as List))
            .cast<Map<Object?, Object?>>()
            .where((item) => item['type'] == 'session')
            .map((item) => item['payload'] as Map)
            .toList();
        expect(sessions, isNotEmpty);
        expect(
          sessions.every((s) => s['patchBaseBuildId'] == p['baseBuildId']),
          true,
        );
        if (phase == 'healthy') {
          final initial = sessions.where((s) => s['init'] == true).toList();
          expect(initial, hasLength(4));
          expect(
            initial.where((s) => s['patchSetDigest'] == expectedDigest),
            hasLength(2),
          );
          expect(
            initial.where((s) => !s.containsKey('patchSetDigest')),
            hasLength(2),
          );
          expect(sessions.where((s) => s['status'] == 'exited'), hasLength(4));
        } else if (phase == 'crash' || phase == 'breach') {
          expect(
            sessions.where(
              (s) =>
                  s['status'] == 'crashed' &&
                  s['patchSetDigest'] == expectedDigest,
            ),
            hasLength(1),
          );
        } else if (phase == 'rollback') {
          expect(
            sessions.where(
              (s) => s['init'] == true && !s.containsKey('patchSetDigest'),
            ),
            hasLength(2),
          );
          expect(
            sessions.where(
              (s) =>
                  s['status'] == 'abnormal' &&
                  s['patchSetDigest'] == expectedDigest &&
                  s['init'] == false,
            ),
            hasLength(1),
          );
        }
        expect(observations, isNotEmpty);
        expect(observations.every((x) => x['status'] == 'uploaded'), true);
      } finally {
        File('${p['directory']}/sdk-$phase-evidence.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'scope':
                'actual Flutter SDK monitoring hub/outbox/HTTP and actual native engine on macOS host; synthetic installations; not device fleet',
            'phase': phase,
            'observations': observations,
          }),
          flush: true,
        );
        client.close();
      }
    },
    skip: statePath == null
        ? 'set BCPATCH_SESSION_STATE, BCPATCH_SESSION_PHASE and BCPATCH_HOST_LIB'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
