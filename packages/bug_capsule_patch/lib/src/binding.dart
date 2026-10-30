import 'dart:io';
import 'dart:typed_data';

import 'package:bug_capsule/bug_capsule.dart';

import 'runtime.dart';
import 'surface.dart';

/// Opens the runtime for BugCapsule: normally from the device store, and in a
/// replay attempt pinned to one exact artifact. Pass it as
/// `BugCapsuleConfig.patchBinding`, then use [patch] from the app.
final class BugCapsulePatchBinding implements PatchBinding {
  BugCapsulePatchBinding(PatchConfig this._config, {required this.modules, this.surfaces = const [], this.libraryPath}) : _resolve = null;

  /// For a config that needs plugins, such as a store directory from
  /// path_provider. [resolve] runs inside `BugCapsule.init`, once the Flutter
  /// binding exists; `init` has to be the first line of `main`.
  BugCapsulePatchBinding.deferred(Future<PatchConfig> Function() resolve, {required this.modules, this.surfaces = const [], this.libraryPath}) : _config = null, _resolve = resolve;

  PatchConfig? _config;
  final Future<PatchConfig> Function()? _resolve;
  final List<PatchModule<dynamic, dynamic>> modules;
  final List<PatchSurfaceContract> surfaces;
  final String? libraryPath;
  BugCapsulePatch? _patch;

  PatchConfig get _ready => _config ?? (throw StateError('patch binding not prepared: pass it to BugCapsule.init first'));

  @override
  Future<void> prepare() async => _config ??= await _resolve!();

  /// The runtime of this process.
  BugCapsulePatch get patch => _patch ??= BugCapsulePatch.open(_ready, modules: modules, surfaces: surfaces, libraryPath: libraryPath);

  @override
  CapsulePatchIdentity? get identity => _config == null ? null : _identityOf(patch);

  CapsulePatchIdentity? _identityOf(BugCapsulePatch p) {
    if (!p.available) return null;
    final s = p.status();
    final running = s['running'] as Map<String, Object?>?;
    return CapsulePatchIdentity(
      baseBuildId: s['baseBuildId']! as String,
      patchSetDigest: running?['patchSetDigest'] as String?,
      engineAbi: s['engineAbi']! as int,
      hostAbiHash: s['hostAbiHash']! as String,
      artifactDigest: running?['artifactDigest'] as String?,
    );
  }

  @override
  Future<CapsulePatchIdentity?> pinForReplay(Uint8List? bundle, {Uint8List? keyring, Uint8List? keyringSignature}) async {
    if ((keyring == null) != (keyringSignature == null)) throw ArgumentError('a keyring needs its signature');
    final dir = await Directory.systemTemp.createTemp('bcpatch-replay');
    Future<String?> write(String name, Uint8List? bytes) async {
      if (bytes == null) return null;
      final path = '${dir.path}/$name';
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    }

    final BugCapsulePatch p;
    try {
      p = BugCapsulePatch.open(
        _ready,
        modules: modules,
        surfaces: surfaces,
        libraryPath: libraryPath,
        replay: PatchReplay(
          bundlePath: await write('artifact.bcpatch', bundle),
          keyringPath: await write('keyring.json', keyring),
          keyringSignaturePath: await write('keyring.sig', keyringSignature),
        ),
      );
    } finally {
      // The runtime loads the archive at open; nothing reads these afterwards.
      await dir.delete(recursive: true);
    }
    if (!p.available) throw StateError('the pinned artifact was refused: ${p.unavailableReason}');
    final handle = _patch;
    if (handle == null) {
      _patch = p;
    } else {
      handle.adoptReplay(p);
    }
    return _identityOf(patch);
  }
}
