import 'dart:async';
import 'dart:convert';
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
  int pinCalls = 0;

  /// A plugin call: only possible once `init` created the Flutter binding.
  @override
  Future<void> prepare() async {
    expect(WidgetsBinding.instance, isNotNull);
    prepared = true;
  }

  @override
  Future<CapsulePatchIdentity?> pinForReplay(Uint8List? bundle, {Uint8List? keyring, Uint8List? keyringSignature}) async {
    pinCalls++;
    return identity;
  }
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

  test('failed preparation starts the app but does not capture unknown identity', () async {
    var ran = false;
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(storageDirectory: dir);
    await BugCapsule.init(
      config: BugCapsuleConfig(appVersion: '1', appBuild: '1', mode: CaptureMode.qa, patchBinding: _Throwing()),
      appRunner: () { ran = true; },
    );
    expect(ran, isTrue);
    expect(BugCapsule.isRecording, isFalse);
    expect(await BugCapsule.capture(), isNull);
  });

  test('hung preparation is bounded and late completion never enables capture', () async {
    final binding = _Pending();
    var ran = false;
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(storageDirectory: dir, setupTimeout: const Duration(milliseconds: 10));
    await BugCapsule.init(
      config: BugCapsuleConfig(appVersion: '1', appBuild: '1', mode: CaptureMode.qa, patchBinding: binding),
      appRunner: () { ran = true; },
    ).timeout(const Duration(seconds: 1));
    expect(ran, isTrue);
    expect(binding.ready.isCompleted, isFalse);
    expect(BugCapsule.isRecording, isFalse);
    binding.ready.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(binding.identityReads, 0);
    expect(BugCapsule.isRecording, isFalse);
    expect(await BugCapsule.capture(), isNull);
    // A fresh session may use the now-ready binding, with its real identity.
    await BugCapsule.resetForTest();
    final captured = await capture(binding);
    expect(captured.manifest.patch!.patchSetDigest, digest);
    expect(captured.manifest.requiredDependencies.single.kind, patchRuntimeDependencyKind);
  });

  test('timed-out preparation rejects replay even if it completes during download', () async {
    final capsule = await capture(null);
    final bytes = CapsuleCodec.encode(capsule);
    await BugCapsule.resetForTest();
    final binding = _Pending();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final report = Completer<Map<String, Object?>>();
    server.listen((request) async {
      if (request.uri.path == '/settings') {
        binding.ready.complete(); // Too late for this session, even before pinning.
        request.response.write('{}');
      } else if (request.uri.path == '/capsule') {
        request.response.add(bytes);
      } else if (request.uri.path == '/result') {
        report.complete((jsonDecode(await utf8.decoder.bind(request).join()) as Map).cast<String, Object?>());
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    try {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(storageDirectory: dir, setupTimeout: const Duration(milliseconds: 10));
      await HttpOverrides.runWithHttpOverrides(() => BugCapsule.init(
        config: BugCapsuleConfig(appVersion: '1', appBuild: '1', mode: CaptureMode.qa, patchBinding: binding, replayUrl: 'http://127.0.0.1:${server.port}'),
        appRunner: () {},
      ), _RealHttp()).timeout(const Duration(seconds: 2));
      final result = await report.future.timeout(const Duration(seconds: 1));
      expect(result['outcome'], 'incompatible');
      expect(result['message'], startsWith('patch.unavailable:'));
      expect(result['patch'], isNull);
      expect(binding.identityReads, 0);
      expect(binding.pinCalls, 0);
      expect(BugCapsule.isRecording, isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('completion from an abandoned session cannot overwrite a fresh session', () async {
    final old = _Pending();
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(storageDirectory: dir, setupTimeout: const Duration(milliseconds: 10));
    await BugCapsule.init(
      config: BugCapsuleConfig(appVersion: '1', appBuild: '1', mode: CaptureMode.qa, patchBinding: old),
      appRunner: () {},
    );
    await BugCapsule.resetForTest();
    final current = FakeBinding(CapsulePatchIdentity(baseBuildId: 'fresh', engineAbi: 1, hostAbiHash: hash, patchSetDigest: digest, artifactDigest: hash));
    final before = await capture(current);
    old.ready.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final result = (await BugCapsule.capture())!;
    final after = CapsuleCodec.decode(await result.file.readAsBytes());
    expect(before.manifest.patch!.baseBuildId, 'fresh');
    expect(after.manifest.patch!.baseBuildId, 'fresh');
    expect(after.manifest.patch!.patchSetDigest, digest);
    expect(old.identityReads, 0);
  });

  test('late preparation rejection is handled after startup has continued', () async {
    final binding = _Pending();
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(storageDirectory: dir, setupTimeout: const Duration(milliseconds: 10));
    await BugCapsule.init(
      config: BugCapsuleConfig(appVersion: '1', appBuild: '1', mode: CaptureMode.qa, patchBinding: binding),
      appRunner: () {},
    ).timeout(const Duration(seconds: 1));
    binding.ready.completeError(StateError('late plugin failure'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(BugCapsule.isRecording, isFalse);
    expect(await BugCapsule.capture(), isNull);
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

final class _Pending implements PatchBinding {
  final ready = Completer<void>();
  int identityReads = 0;
  int pinCalls = 0;
  @override
  Future<void> prepare() => ready.future;
  @override
  CapsulePatchIdentity? get identity {
    identityReads++;
    return CapsulePatchIdentity(baseBuildId: 'late', engineAbi: 1, hostAbiHash: hash, patchSetDigest: digest, artifactDigest: hash);
  }
  @override
  Future<CapsulePatchIdentity?> pinForReplay(Uint8List? bundle, {Uint8List? keyring, Uint8List? keyringSignature}) async {
    pinCalls++;
    return identity;
  }
}

final class _RealHttp extends HttpOverrides {}
