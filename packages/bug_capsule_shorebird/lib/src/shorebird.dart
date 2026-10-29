import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter/foundation.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

import 'updater.dart';

const bugCapsuleShorebirdVersion = '0.1.0-dev.1';

/// Hotfix adapter (§7.7 of the emergency client contract) on
/// `package:shorebird_code_push`.
///
/// ```dart
/// await BugCapsule.emergency.initialize(EmergencyConfig(
///   trustAnchor: 'bcek.v1.…',
///   hotfixProvider: BugCapsuleShorebird(),
/// ));
/// final result = await BugCapsule.emergency.hotfix?.downloadAvailablePatch();
/// if (result is HotfixRestartRequired) showRestartPrompt();
/// ```
///
/// Works only in builds made with `shorebird release`; any other build
/// (including `flutter build` and debug runs) reports `available: false`
/// and can only be fixed by a store release. Shorebird patches Dart code
/// only. A downloaded patch becomes active the next time the app starts;
/// the adapter reports [HotfixState.restartRequired] and never restarts the
/// app.
///
/// Failures are returned in the results and never thrown.
class BugCapsuleShorebird implements HotfixProvider {
  /// Checks and downloads patches on [track] (Shorebird's `stable` when
  /// null). [releaseVersion] is the Shorebird release this build is, as
  /// `version+build` from pubspec.yaml; when null, runtime reports use the
  /// app version the SDK was configured with.
  BugCapsuleShorebird({this.track, this.releaseVersion}) : _create = _shorebird;

  /// Runs against [updater] instead of the Shorebird engine.
  @visibleForTesting
  BugCapsuleShorebird.withUpdater(
    CodePushUpdater updater, {
    this.track,
    this.releaseVersion,
  }) : _create = (() => updater);

  static CodePushUpdater _shorebird() =>
      ShorebirdCodePushUpdater(ShorebirdUpdater());

  /// The `provider` of runtime reports.
  static const providerName = 'shorebird';

  final UpdateTrack? track;
  final String? releaseVersion;

  final CodePushUpdater Function() _create;
  CodePushUpdater? _created;

  /// Created on first use: the Shorebird updater probes the engine when it
  /// is constructed.
  CodePushUpdater get _updater => _created ??= _create();

  /// The answer of the last check in this process.
  HotfixState? _checked;
  bool _downloading = false;

  @override
  Future<HotfixAvailability> checkAvailability() async =>
      HotfixAvailability((await _check()).status);

  @override
  Future<HotfixResult> downloadAvailablePatch() async {
    try {
      final updater = _updater;
      if (!updater.isAvailable) return HotfixUnavailable(_unavailable());
      final (:update, :status) = await _check();
      switch (update) {
        case null:
          return HotfixDownloadFailed(
            status,
            reason: 'check_failed',
            message: status.error,
          );
        case UpdateStatus.unavailable:
          return HotfixUnavailable(status);
        case UpdateStatus.upToDate:
          return HotfixNothingToDownload(status);
        case UpdateStatus.restartRequired:
          return HotfixRestartRequired(status);
        case UpdateStatus.outdated:
          return await _download(updater);
      }
    } catch (e) {
      _checked = HotfixState.failed;
      return HotfixDownloadFailed(
        await _failure(e),
        reason: 'error',
        message: '$e',
      );
    }
  }

  Future<HotfixResult> _download(CodePushUpdater updater) async {
    final before = await _patches(updater);
    _downloading = true;
    try {
      await updater.update(track: track);
    } on UpdateException catch (e) {
      if (e.reason == UpdateFailureReason.noUpdate) {
        _checked = HotfixState.upToDate;
        return _downloaded(_statusOf(before, HotfixState.upToDate));
      }
      _checked = HotfixState.failed;
      return HotfixDownloadFailed(
        _statusOf(before, HotfixState.failed, error: e.message),
        reason: _reason(e.reason),
        message: e.message,
      );
    } finally {
      _downloading = false;
    }
    var after = await _patches(updater);
    if (after.next == before.next) {
      // Nothing new on disk: either there was no patch after all, or
      // another download (Shorebird's automatic update) is still running.
      final again = await updater.checkForUpdate(track: track);
      if (again == UpdateStatus.unavailable) {
        return HotfixUnavailable(_unavailable());
      }
      _checked = _stateOf(again);
      if (again == UpdateStatus.outdated) {
        return HotfixDownloadInProgress(
          _statusOf(after, HotfixState.downloading),
        );
      }
      after = await _patches(updater);
    } else {
      _checked = HotfixState.upToDate;
    }
    return _downloaded(_statusOf(after, HotfixState.upToDate));
  }

  HotfixResult _downloaded(HotfixStatus status) =>
      status.state == HotfixState.restartRequired
      ? HotfixRestartRequired(status)
      : HotfixNothingToDownload(status);

  /// Reads the patches without a network call, except before the first
  /// check of this process, which this then runs.
  @override
  Future<HotfixStatus> getStatus() async {
    try {
      final updater = _updater;
      if (!updater.isAvailable) return _unavailable();
      if (_downloading) {
        return _statusOf(await _patches(updater), HotfixState.downloading);
      }
      final checked = _checked;
      if (checked == null) return (await _check()).status;
      return _statusOf(await _patches(updater), checked);
    } catch (e) {
      return _failure(e);
    }
  }

  /// Shorebird's answer (null when the check failed) and the status after
  /// it.
  Future<({UpdateStatus? update, HotfixStatus status})> _check() async {
    try {
      final updater = _updater;
      if (!updater.isAvailable) return (update: null, status: _unavailable());
      final update = await updater.checkForUpdate(track: track);
      if (update == UpdateStatus.unavailable) {
        _checked = HotfixState.unavailable;
        return (update: update, status: _unavailable());
      }
      final state = _checked = _stateOf(update);
      return (
        update: update,
        status: _statusOf(await _patches(updater), state),
      );
    } catch (e) {
      _checked = HotfixState.failed;
      return (update: null, status: await _failure(e));
    }
  }

  static HotfixState _stateOf(UpdateStatus status) => switch (status) {
    UpdateStatus.upToDate => HotfixState.upToDate,
    UpdateStatus.outdated => HotfixState.outdated,
    UpdateStatus.restartRequired => HotfixState.restartRequired,
    UpdateStatus.unavailable => HotfixState.unavailable,
  };

  static String _reason(UpdateFailureReason reason) => switch (reason) {
    UpdateFailureReason.noUpdate => 'no_update',
    UpdateFailureReason.downloadFailed => 'download_failed',
    UpdateFailureReason.installFailed => 'install_failed',
    UpdateFailureReason.unknown => 'unknown',
  };

  static Future<({int? current, int? next})> _patches(
    CodePushUpdater updater,
  ) async => (
    current: await updater.readCurrentPatch(),
    next: await updater.readNextPatch(),
  );

  /// A next patch that differs from the current one (a download, or a
  /// rollback to the base release) waits for the next start. An up-to-date
  /// build with one pending is [HotfixState.restartRequired].
  HotfixStatus _statusOf(
    ({int? current, int? next}) patches,
    HotfixState state, {
    String? error,
  }) {
    final pending = patches.next != patches.current;
    return HotfixStatus(
      provider: providerName,
      available: true,
      state: pending && state == HotfixState.upToDate
          ? HotfixState.restartRequired
          : state,
      releaseVersion: releaseVersion,
      currentPatch: patches.current,
      nextPatch: pending ? patches.next : null,
      error: error,
    );
  }

  static HotfixStatus _unavailable() => const HotfixStatus(
    provider: providerName,
    available: false,
    state: HotfixState.unavailable,
  );

  /// A failed status, with the patches when they can still be read.
  Future<HotfixStatus> _failure(Object e) async {
    final error = switch (e) {
      UpdateException(:final message) => message,
      ReadPatchException(:final message) => message,
      _ => '$e',
    };
    try {
      final updater = _updater;
      if (updater.isAvailable) {
        return _statusOf(
          await _patches(updater),
          HotfixState.failed,
          error: error,
        );
      }
    } catch (_) {
      // The patches are unknown too.
    }
    bool available;
    try {
      available = _created?.isAvailable ?? false;
    } catch (_) {
      available = false;
    }
    return HotfixStatus(
      provider: providerName,
      available: available,
      state: HotfixState.failed,
      releaseVersion: releaseVersion,
      error: error,
    );
  }
}
