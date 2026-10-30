import 'package:bug_capsule/bug_capsule.dart';

import 'runtime.dart';

/// Reports the patch runtime through the Emergency Recovery hotfix contract.
/// The provider name `bugcapsule_patch` matches the backend provider kind.
final class BugCapsulePatchHotfix implements HotfixProvider {
  BugCapsulePatchHotfix(this.patch, {this.release});

  final BugCapsulePatch patch;

  /// The base build patches apply to, reported as the release.
  final String? release;

  HotfixStatus _status() {
    if (!patch.available) {
      return HotfixStatus(provider: 'bugcapsule_patch', available: false, state: HotfixState.unavailable, releaseVersion: release, error: patch.unavailableReason);
    }
    final s = patch.status();
    final running = s['running'] as Map<String, Object?>?;
    final pending = s['pending'];
    return HotfixStatus(
      provider: 'bugcapsule_patch',
      available: true,
      state: pending != null ? HotfixState.restartRequired : HotfixState.upToDate,
      releaseVersion: release ?? s['baseBuildId'] as String?,
      currentPatch: running?['patchSequence'] as int?,
    );
  }

  @override
  Future<HotfixAvailability> checkAvailability() async => HotfixAvailability(_status());

  /// Downloads are driven by channel metadata; see [BugCapsulePatch.applyChannel].
  @override
  Future<HotfixResult> downloadAvailablePatch() async {
    final s = _status();
    if (!s.available) return HotfixUnavailable(s);
    return s.state == HotfixState.restartRequired ? HotfixRestartRequired(s) : HotfixNothingToDownload(s);
  }

  @override
  Future<HotfixStatus> getStatus() async => _status();
}
