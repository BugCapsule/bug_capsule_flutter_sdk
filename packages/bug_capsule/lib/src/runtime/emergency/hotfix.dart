import 'package:flutter/foundation.dart';

/// Where a hotfix runtime stands (§7.6 `hotfix.state`).
enum HotfixState {
  /// The release runs the newest patch there is.
  upToDate('up_to_date'),

  /// A newer patch can be downloaded.
  outdated('outdated'),

  /// A patch is being downloaded.
  downloading('downloading'),

  /// A downloaded patch (or the base release, after a rollback) becomes
  /// active on the next start. The app decides when that is.
  restartRequired('restart_required'),

  /// The build has no patch runtime, for example because it was not built
  /// with the provider's release tooling.
  unavailable('unavailable'),

  /// The last check or download failed.
  failed('failed');

  const HotfixState(this.wire);

  /// The name on the wire, e.g. `restart_required`.
  final String wire;
}

/// What a hotfix provider knows about the running build (§7.6 `hotfix`).
@immutable
final class HotfixStatus {
  const HotfixStatus({
    required this.provider,
    required this.available,
    required this.state,
    this.releaseVersion,
    this.currentPatch,
    this.nextPatch,
    this.error,
  });

  /// `^[a-z][a-z0-9_]{0,31}$`, e.g. `shorebird`.
  final String provider;

  /// The build carries the provider's patch runtime.
  final bool available;
  final HotfixState state;

  /// The release patches apply to; null when the provider does not know it.
  /// Runtime reports then send the app version (`EmergencyConfig.appVersion`
  /// or `BugCapsuleConfig.appVersion`) for an available runtime.
  final String? releaseVersion;

  /// The patch the running process uses; null on the base release. With
  /// [HotfixState.failed] or [HotfixState.unavailable], null means unknown.
  final int? currentPatch;

  /// The patch that becomes active on the next start, when it differs from
  /// [currentPatch]; otherwise null. Never active in this process.
  final int? nextPatch;

  /// Why [state] is [HotfixState.failed]. Not reported to the backend.
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is HotfixStatus &&
      other.provider == provider &&
      other.available == available &&
      other.state == state &&
      other.releaseVersion == releaseVersion &&
      other.currentPatch == currentPatch &&
      other.nextPatch == nextPatch &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    provider,
    available,
    state,
    releaseVersion,
    currentPatch,
    nextPatch,
    error,
  );

  @override
  String toString() =>
      'HotfixStatus($provider, ${available ? 'available' : 'unavailable'}, '
      '${state.wire}, release: $releaseVersion, current: $currentPatch, '
      'next: $nextPatch${error == null ? '' : ', error: $error'})';
}

/// What [HotfixProvider.checkAvailability] found.
@immutable
final class HotfixAvailability {
  const HotfixAvailability(this.status);

  /// The status after the check.
  final HotfixStatus status;

  /// The build carries the provider's patch runtime.
  bool get runtimeAvailable => status.available;

  /// A newer patch can be downloaded with
  /// [HotfixProvider.downloadAvailablePatch].
  bool get patchAvailable => status.state == HotfixState.outdated;

  /// A patch is waiting for the next start.
  bool get restartRequired => status.state == HotfixState.restartRequired;

  @override
  String toString() => 'HotfixAvailability($status)';
}

/// The outcome of [HotfixProvider.downloadAvailablePatch]. Every outcome
/// carries the status after the call.
sealed class HotfixResult {
  const HotfixResult(this.status);
  final HotfixStatus status;
}

/// No newer patch: the build is up to date.
final class HotfixNothingToDownload extends HotfixResult {
  const HotfixNothingToDownload(super.status);

  @override
  String toString() => 'HotfixNothingToDownload($status)';
}

/// A patch was downloaded (or the current one was rolled back). It becomes
/// active on the next start, which the app chooses; the running process
/// keeps its current code.
final class HotfixRestartRequired extends HotfixResult {
  const HotfixRestartRequired(super.status);

  /// The patch of the next start; null when that is the base release.
  int? get nextPatch => status.nextPatch;

  @override
  String toString() => 'HotfixRestartRequired($status)';
}

/// Another download is running, for example the provider's automatic
/// update. Check the status again later.
final class HotfixDownloadInProgress extends HotfixResult {
  const HotfixDownloadInProgress(super.status);

  @override
  String toString() => 'HotfixDownloadInProgress($status)';
}

/// The download failed. Nothing changed for the running process or the
/// next start.
final class HotfixDownloadFailed extends HotfixResult {
  const HotfixDownloadFailed(
    super.status, {
    required this.reason,
    this.message,
  });

  /// A short code such as `download_failed` or `install_failed`.
  final String reason;
  final String? message;

  @override
  String toString() =>
      'HotfixDownloadFailed($reason${message == null ? '' : ': $message'})';
}

/// The build has no patch runtime; only a store release can change it.
final class HotfixUnavailable extends HotfixResult {
  const HotfixUnavailable(super.status);

  @override
  String toString() => 'HotfixUnavailable($status)';
}

/// A code push service that patches the Dart code of a release (§7.7), such
/// as Shorebird (`bug_capsule_shorebird`). Pass one as
/// `EmergencyConfig.hotfixProvider`.
///
/// A provider never restarts the app and never reports a downloaded patch
/// as active: a downloaded patch is [HotfixStatus.nextPatch] with
/// [HotfixState.restartRequired] until the app starts again. Failures are
/// returned in the result, not thrown.
abstract interface class HotfixProvider {
  /// Asks the provider whether a newer patch exists. Downloads nothing.
  Future<HotfixAvailability> checkAvailability();

  /// Downloads the newest patch, if there is one. The patch becomes active
  /// on the next start.
  Future<HotfixResult> downloadAvailablePatch();

  /// The current status.
  Future<HotfixStatus> getStatus();
}

final RegExp _provider = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
const _maxPatch = 2147483647;

bool _validPatch(int? n) => n == null || (n >= 1 && n <= _maxPatch);

/// The `hotfix` object of a runtime report (§7.6), or a [FormatException]
/// when [status] cannot be reported. A null [HotfixStatus.releaseVersion] of
/// an available runtime becomes [appVersion]; a release version longer than
/// 64 characters is sent as null.
Map<String, Object?> hotfixRuntimeJson(
  HotfixStatus status,
  String? appVersion,
) {
  if (!_provider.hasMatch(status.provider)) {
    throw FormatException('provider "${status.provider}" is not a name');
  }
  if (!_validPatch(status.currentPatch) || !_validPatch(status.nextPatch)) {
    throw FormatException(
      'patch numbers must be 1 to $_maxPatch '
      '(current: ${status.currentPatch}, next: ${status.nextPatch})',
    );
  }
  var release = status.releaseVersion;
  if (release == null && status.available) release = appVersion;
  if (release != null && (release.isEmpty || release.length > 64)) {
    release = null;
  }
  final next = status.nextPatch == status.currentPatch
      ? null
      : status.nextPatch;
  return {
    'provider': status.provider,
    'available': status.available,
    'releaseVersion': release,
    'currentPatch': status.currentPatch,
    'nextPatch': next,
    'state': status.state.wire,
  };
}

/// `BugCapsule.emergency.hotfix`: the configured [HotfixProvider], with
/// every status it returns reported to the BugCapsule backend (§7.6).
///
/// ```dart
/// final hotfix = BugCapsule.emergency.hotfix;
/// final result = await hotfix?.downloadAvailablePatch();
/// if (result is HotfixRestartRequired) askToRestart();
/// ```
///
/// Never throws: a provider that throws gives a failed result. The app is
/// never restarted.
final class EmergencyHotfix implements HotfixProvider {
  /// Created by `BugCapsule.emergency.initialize`.
  @internal
  EmergencyHotfix.internal(this.provider, this._onStatus);

  final HotfixProvider provider;
  final void Function(HotfixStatus status) _onStatus;
  HotfixStatus? _last;
  Future<HotfixResult>? _downloading;

  /// The status of the last call; null before the first one completes.
  HotfixStatus? get lastStatus => _last;

  @override
  Future<HotfixAvailability> checkAvailability() async {
    try {
      final a = await provider.checkAvailability();
      _seen(a.status);
      return a;
    } catch (e) {
      return HotfixAvailability(_failed('checkAvailability', e));
    }
  }

  /// Joins a download already started through this object.
  @override
  Future<HotfixResult> downloadAvailablePatch() =>
      _downloading ??= _download().whenComplete(() => _downloading = null);

  Future<HotfixResult> _download() async {
    try {
      final r = await provider.downloadAvailablePatch();
      _seen(r.status);
      return r;
    } catch (e) {
      return HotfixDownloadFailed(
        _failed('downloadAvailablePatch', e),
        reason: 'provider_error',
        message: '$e',
      );
    }
  }

  @override
  Future<HotfixStatus> getStatus() async {
    try {
      final s = await provider.getStatus();
      _seen(s);
      return s;
    } catch (e) {
      return _failed('getStatus', e);
    }
  }

  void _seen(HotfixStatus status) {
    _last = status;
    try {
      _onStatus(status);
    } catch (e) {
      debugPrint('[bugcapsule] emergency: hotfix status not reported: $e');
    }
  }

  /// The last status marked failed; reported only when the provider gave
  /// one before, since its name is known only then.
  HotfixStatus _failed(String operation, Object e) {
    debugPrint('[bugcapsule] emergency: hotfix $operation failed: $e');
    final last = _last;
    if (last == null) {
      return HotfixStatus(
        provider: 'unknown',
        available: false,
        state: HotfixState.failed,
        error: '$e',
      );
    }
    final failed = HotfixStatus(
      provider: last.provider,
      available: last.available,
      state: HotfixState.failed,
      releaseVersion: last.releaseVersion,
      currentPatch: last.currentPatch,
      nextPatch: last.nextPatch,
      error: '$e',
    );
    _seen(failed);
    return failed;
  }
}
