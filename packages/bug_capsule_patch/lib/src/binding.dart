import 'dart:io';
import 'dart:typed_data';

import 'package:bug_capsule/bug_capsule.dart';

import 'runtime.dart';
import 'surface.dart';

/// Opens the runtime for BugCapsule: normally from the device store, and in a
/// replay attempt pinned to one exact artifact. Pass it as
/// `BugCapsuleConfig.patchBinding`, then use [patch].
final class BugCapsulePatchBinding implements PatchBinding {
  BugCapsulePatchBinding(this.config, {required this.modules, this.surfaces = const [], this.libraryPath});

  final PatchConfig config;
  final List<PatchModule<dynamic, dynamic>> modules;
  final List<PatchSurfaceContract> surfaces;
  final String? libraryPath;
  BugCapsulePatch? _patch;

  /// The runtime of this process.
  BugCapsulePatch get patch => _patch ??= BugCapsulePatch.open(config, modules: modules, surfaces: surfaces, libraryPath: libraryPath);

  @override
  CapsulePatchIdentity? get identity => _identityOf(patch);

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

    final p = BugCapsulePatch.open(
      config,
      modules: modules,
      surfaces: surfaces,
      libraryPath: libraryPath,
      replay: PatchReplay(
        bundlePath: await write('artifact.bcpatch', bundle),
        keyringPath: await write('keyring.json', keyring),
        keyringSignaturePath: await write('keyring.sig', keyringSignature),
      ),
    );
    if (!p.available) throw StateError('the pinned artifact was refused: ${p.unavailableReason}');
    _patch = p;
    return _identityOf(p);
  }
}
