import 'package:shorebird_code_push/shorebird_code_push.dart';

/// The calls [BugCapsuleShorebird] makes, so tests can stand in for the
/// Shorebird engine. Patch numbers are null on the base release.
abstract interface class CodePushUpdater {
  bool get isAvailable;

  /// Throws [ReadPatchException].
  Future<int?> readCurrentPatch();

  /// The same as [readCurrentPatch] when nothing new was downloaded. Throws
  /// [ReadPatchException].
  Future<int?> readNextPatch();

  Future<UpdateStatus> checkForUpdate({UpdateTrack? track});

  /// Throws [UpdateException].
  Future<void> update({UpdateTrack? track});
}

/// [CodePushUpdater] on `package:shorebird_code_push`.
final class ShorebirdCodePushUpdater implements CodePushUpdater {
  ShorebirdCodePushUpdater(this._updater);

  final ShorebirdUpdater _updater;

  @override
  bool get isAvailable => _updater.isAvailable;

  @override
  Future<int?> readCurrentPatch() async =>
      (await _updater.readCurrentPatch())?.number;

  @override
  Future<int?> readNextPatch() async =>
      (await _updater.readNextPatch())?.number;

  @override
  Future<UpdateStatus> checkForUpdate({UpdateTrack? track}) =>
      _updater.checkForUpdate(track: track);

  @override
  Future<void> update({UpdateTrack? track}) => _updater.update(track: track);
}
