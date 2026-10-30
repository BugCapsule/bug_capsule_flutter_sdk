import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final hash = 'sha256:${'a' * 64}';
final digest = 'sha256:${'b' * 64}';

final class FakeBinding implements PatchBinding {
  FakeBinding(this.identity);

  @override
  CapsulePatchIdentity? identity;
  bool prepared = false;

  /// A plugin call: only possible once `init` created the Flutter binding.
  @override
  Future<void> prepare() async {
    expect(WidgetsBinding.instance, isNotNull);
    prepared = true;
  }

  @override
  Future<CapsulePatchIdentity?> pinForReplay(Uint8List? bundle, {Uint8List? keyring, Uint8List? keyringSignature}) async => identity;
}

/// A real capture through `BugCapsule`, not a hand-built manifest.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('bcpc'));

  tearDown(() async {
    await BugCapsule.resetForTest();
    BugCapsule.debugOverrides = null;
    dir.deleteSync(recursive: true);
  });

  Future<Capsule> capture(PatchBinding? binding) async {
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(storageDirectory: dir);
    await BugCapsule.init(
      config: BugCapsuleConfig(appVersion: '1.0.0', appBuild: '1', mode: CaptureMode.qa, gitSha: 'abc', autoCaptureOnFailure: false, patchBinding: binding),
      appRunner: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final r = (await BugCapsule.capture())!;
    return CapsuleCodec.decode(await r.file.readAsBytes());
  }

  test('a capture on a patch records it and requires the runtime', () async {
    final c = await capture(FakeBinding(CapsulePatchIdentity(baseBuildId: 'build-1', patchSetDigest: digest, engineAbi: 1, hostAbiHash: hash, artifactDigest: hash)));
    expect(c.manifest.patch!.patchSetDigest, digest);
    expect(c.manifest.patch!.artifactDigest, hash);
    expect(c.specVersion, 2, reason: 'older v1 readers must not take this for a plain capsule');
    expect(c.manifest.requiredDependencies.single.kind, patchRuntimeDependencyKind);
  });

  test('init prepares the binding before anything reads it', () async {
    final b = FakeBinding(CapsulePatchIdentity(baseBuildId: 'build-1', engineAbi: 1, hostAbiHash: hash));
    await capture(b);
    expect(b.prepared, isTrue);
  });

  test('a capture on the bare base records the identity and needs no runtime', () async {
    final c = await capture(FakeBinding(CapsulePatchIdentity(baseBuildId: 'build-1', engineAbi: 1, hostAbiHash: hash)));
    expect(c.manifest.patch!.baseBuildId, 'build-1');
    expect(c.manifest.patch!.patchSetDigest, isNull);
    expect(c.manifest.requiredDependencies, isEmpty);
  });

  test('without a binding a capture is unchanged', () async {
    final c = await capture(null);
    expect(c.manifest.patch, isNull);
    expect(c.manifest.requiredDependencies, isEmpty);
  });

  test('a failing binding never breaks a capture', () async {
    final c = await capture(_Throwing());
    expect(c.manifest.patch, isNull);
  });
}

final class _Throwing implements PatchBinding {
  @override
  Future<void> prepare() async => throw StateError('no directory');

  @override
  CapsulePatchIdentity? get identity => throw StateError('runtime gone');

  @override
  Future<CapsulePatchIdentity?> pinForReplay(Uint8List? bundle, {Uint8List? keyring, Uint8List? keyringSignature}) async => null;
}
