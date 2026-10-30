import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real runtime: a replay pin must change what callers actually execute.
void main() {
  final path = Platform.environment['BCPATCH_HOST_LIB'];
  final skip = path == null ? 'set BCPATCH_HOST_LIB' : null;
  final wire = jsonDecode(File('test/fixtures/wire.json').readAsStringSync()) as Map<String, Object?>;
  final t = wire['target']! as Map<String, Object?>;
  final m = (t['modules']! as List<Object?>).first! as Map<String, Object?>;
  Uint8List artifact(String name) => base64Decode((wire['artifacts']! as List<Object?>).cast<Map<String, Object?>>().firstWhere((a) => a['name'] == name)['bundle']! as String);

  // Vector module: x + 1. The fallback is x, so the two are distinguishable.
  final module = PatchModule<int, int>(id: m['id']! as String, inputSchema: m['input']! as String, outputSchema: m['output']! as String, encode: (i) => i, decode: (o) => o! as int, fallback: (i) => i);

  BugCapsulePatchBinding binding(String dir) => BugCapsulePatchBinding(
    PatchConfig(
      storeDir: dir,
      projectId: t['projectId']! as String,
      applicationId: t['applicationId']! as String,
      environment: t['environment']! as String,
      platform: t['platform']! as String,
      distributionProfile: t['distributionProfile']! as String,
      baseBuildId: t['baseBuildId']! as String,
      installationId: 'install-1',
      trustRoots: [wire['trustRoot']! as String],
    ),
    modules: [module],
    libraryPath: path,
  );

  test('dispatch and holders of the handle follow a replay pin', () async {
    final dir = Directory.systemTemp.createTempSync('bcb').path;
    final b = binding(dir);
    final held = b.patch;
    PatchDispatch.install(held);
    final fallback = PatchModule<Map<String, Object?>, int>(id: module.id, inputSchema: module.inputSchema, outputSchema: module.outputSchema, encode: (i) => i['x'], decode: (o) => o! as int, fallback: (i) => i['x']! as int);
    expect(held.call(module, 1).value, 1, reason: 'live store is on base');
    expect(PatchDispatch.call(fallback, {'x': 1}), 1);

    final id = await b.pinForReplay(artifact('valid'));
    expect(id!.patchSetDigest, isNotNull);
    expect(identical(b.patch, held), isTrue);
    expect(held.call(module, 1).value, 2, reason: 'the handle now runs the pinned artifact');
    expect(PatchDispatch.call(fallback, {'x': 1}), 2, reason: 'generated stubs run the pinned artifact');
    expect(held.status()['replay'], isTrue);
    expect(() => held.stage(artifact('valid')), throwsA(anything), reason: 'replay is read-only');
    held.close();
  }, skip: skip);

  test('a bare-base pin ignores a patch active in the live store', () async {
    final dir = Directory.systemTemp.createTempSync('bcb').path;
    final live = binding(dir);
    live.patch.stage(artifact('valid'));
    live.patch.close();
    final next = binding(dir);
    expect(next.patch.call(module, 1).value, 2);
    final held = next.patch;
    expect((await next.pinForReplay(null))!.patchSetDigest, isNull);
    expect(held.call(module, 1).value, 1);
    held.close();
  }, skip: skip);

  test('a refused artifact throws and leaves the handle alone', () async {
    final b = binding(Directory.systemTemp.createTempSync('bcb').path);
    final held = b.patch;
    await expectLater(b.pinForReplay(artifact('payload bit flip')), throwsStateError);
    expect(held.available, isTrue);
    held.close();
  }, skip: skip);
}
