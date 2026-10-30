import 'dart:typed_data';

import '../core/capsule.dart';
import '../core/replay_protocol.dart';

/// Connects the patch runtime to capture and replay. `bug_capsule_patch`
/// implements this; pass it as `BugCapsuleConfig.patchBinding`.
abstract interface class PatchBinding {
  /// What this process runs. Capsules record it.
  CapsulePatchIdentity? get identity;

  /// Replay: load exactly [bundle], or the bare base when null, offline and
  /// without the device store or live channel. A bundle signed by a delegated
  /// key comes with the archived [keyring] and its [keyringSignature]. Throws
  /// when that is impossible, because running anything else would make the
  /// attempt meaningless.
  Future<CapsulePatchIdentity?> pinForReplay(Uint8List? bundle, {Uint8List? keyring, Uint8List? keyringSignature});
}

/// Why a capsule can't replay with this patch setup, or null. A wrong or
/// missing patch is `incompatible`, never a run of something else.
String? patchPreflight({
  required CapsuleManifest manifest,
  required ReplaySettings settings,
  required bool hasBinding,
  required CapsulePatchIdentity? running,
}) {
  final captured = manifest.patch;
  final needsRuntime = captured?.patchSetDigest != null || manifest.requiredDependencies.any((d) => d.kind == patchRuntimeDependencyKind);
  if (!hasBinding) {
    if (needsRuntime || settings.patchArtifact) {
      return 'dependency.unsupported: $patchRuntimeAdapter is not set up in '
          'this build; pass patchBinding to BugCapsuleConfig';
    }
    return null;
  }
  if (running == null) return 'patch.unavailable: the patch runtime reported no identity';
  if (captured != null) {
    if (captured.baseBuildId != running.baseBuildId) {
      return 'patch.base: captured on base ${captured.baseBuildId}, this build is ${running.baseBuildId}';
    }
    if (captured.engineAbi != running.engineAbi || captured.hostAbiHash != running.hostAbiHash) {
      return 'patch.abi: captured on engine ABI ${captured.engineAbi}, this build has ${running.engineAbi}';
    }
    if (!settings.patchArtifact && captured.patchSetDigest != null) {
      return 'patch.artifact_missing: captured with ${captured.patchSetDigest}; '
          'pass its archived artifact with --patch-artifact';
    }
  }
  final expected = settings.expectedPatchSetDigest;
  if (settings.patchArtifact && running.patchSetDigest != expected) {
    return 'patch.mismatch: loaded ${running.patchSetDigest}, expected $expected';
  }
  return null;
}
