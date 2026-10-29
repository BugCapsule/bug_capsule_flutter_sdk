import 'dart:async';

import 'package:bug_capsule/bug_capsule.dart';
// The report validation of the core, to check every status is reportable.
// ignore: implementation_imports
import 'package:bug_capsule/src/runtime/emergency/hotfix.dart'
    show hotfixRuntimeJson;
import 'package:bug_capsule_shorebird/bug_capsule_shorebird.dart';
import 'package:bug_capsule_shorebird/src/updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// A scripted Shorebird engine. [next] follows [current] unless a download
/// sets it; [update] runs [onUpdate].
class FakeUpdater implements CodePushUpdater {
  FakeUpdater({
    this.isAvailable = true,
    this.current,
    int? next,
    this.status = UpdateStatus.upToDate,
  }) : next = next ?? current;

  @override
  bool isAvailable;
  int? current;
  int? next;
  UpdateStatus status;
  final List<String> calls = [];
  final List<UpdateTrack?> tracks = [];

  /// What `update` does; by default it downloads patch `current + 1`.
  FutureOr<void> Function()? onUpdate;

  /// Answers of `checkForUpdate` after the first one, in order.
  final List<UpdateStatus> laterChecks = [];
  Object? readError;
  Object? checkError;

  int get checks => calls.where((c) => c == 'checkForUpdate').length;

  @override
  Future<int?> readCurrentPatch() async {
    calls.add('readCurrentPatch');
    final e = readError;
    if (e != null) throw e;
    return current;
  }

  @override
  Future<int?> readNextPatch() async {
    calls.add('readNextPatch');
    final e = readError;
    if (e != null) throw e;
    return next;
  }

  @override
  Future<UpdateStatus> checkForUpdate({UpdateTrack? track}) async {
    calls.add('checkForUpdate');
    tracks.add(track);
    final e = checkError;
    if (e != null) throw e;
    if (checks > 1 && laterChecks.isNotEmpty) return laterChecks.removeAt(0);
    return status;
  }

  @override
  Future<void> update({UpdateTrack? track}) async {
    calls.add('update');
    tracks.add(track);
    final custom = onUpdate;
    if (custom != null) return custom();
    next = (current ?? 0) + 1;
  }
}

/// `package:shorebird_code_push`'s interface, scripted.
class FakeShorebirdUpdater implements ShorebirdUpdater {
  Patch? current;
  Patch? next;
  UpdateTrack? track;

  @override
  bool get isAvailable => true;

  @override
  Future<Patch?> readCurrentPatch() async => current;

  @override
  Future<Patch?> readNextPatch() async => next;

  @override
  Future<UpdateStatus> checkForUpdate({UpdateTrack? track}) async {
    this.track = track;
    return UpdateStatus.outdated;
  }

  @override
  Future<void> update({UpdateTrack? track}) async => this.track = track;
}

void main() {
  BugCapsuleShorebird adapter(
    FakeUpdater updater, {
    UpdateTrack? track,
    String? releaseVersion = '2.4.1+42',
  }) => BugCapsuleShorebird.withUpdater(
    updater,
    track: track,
    releaseVersion: releaseVersion,
  );

  group('a build without the Shorebird engine', () {
    test('reports available: false and never touches the network', () async {
      final updater = FakeUpdater(isAvailable: false);
      final a = adapter(updater);
      const unavailable = HotfixStatus(
        provider: 'shorebird',
        available: false,
        state: HotfixState.unavailable,
      );
      expect(await a.getStatus(), unavailable);
      final availability = await a.checkAvailability();
      expect(availability.runtimeAvailable, isFalse);
      expect(availability.patchAvailable, isFalse);
      final result = await a.downloadAvailablePatch();
      expect(result, isA<HotfixUnavailable>());
      expect(result.status, unavailable);
      expect(updater.calls, isEmpty);
    });

    test('the real updater in a test build (no Shorebird engine)', () async {
      final status = await BugCapsuleShorebird().getStatus();
      expect(status.provider, 'shorebird');
      expect(status.available, isFalse);
      expect(status.state, HotfixState.unavailable);
    });

    test('Shorebird reporting unavailable after all', () async {
      final updater = FakeUpdater(status: UpdateStatus.unavailable);
      final a = adapter(updater);
      expect((await a.checkAvailability()).status.available, isFalse);
      expect(await a.downloadAvailablePatch(), isA<HotfixUnavailable>());
      expect(updater.calls, isNot(contains('update')));
    });
  });

  group('checkAvailability', () {
    test('up to date on the base release', () async {
      final a = adapter(FakeUpdater());
      final status = (await a.checkAvailability()).status;
      expect(
        status,
        const HotfixStatus(
          provider: 'shorebird',
          available: true,
          state: HotfixState.upToDate,
          releaseVersion: '2.4.1+42',
        ),
      );
    });

    test('outdated: a patch can be downloaded', () async {
      final a = adapter(FakeUpdater(current: 3, status: UpdateStatus.outdated));
      final availability = await a.checkAvailability();
      expect(availability.patchAvailable, isTrue);
      expect(availability.status.state, HotfixState.outdated);
      expect(availability.status.currentPatch, 3);
      expect(availability.status.nextPatch, isNull);
    });

    test('restart required with the downloaded patch as next', () async {
      final a = adapter(
        FakeUpdater(current: 3, next: 4, status: UpdateStatus.restartRequired),
      );
      final availability = await a.checkAvailability();
      expect(availability.restartRequired, isTrue);
      expect(availability.status.currentPatch, 3);
      expect(availability.status.nextPatch, 4);
    });

    test('a rolled back patch: restart required, next start is the base '
        'release', () async {
      final updater = FakeUpdater(
        current: 3,
        status: UpdateStatus.restartRequired,
      )..next = null;
      final status = (await adapter(updater).checkAvailability()).status;
      expect(status.state, HotfixState.restartRequired);
      expect(status.currentPatch, 3);
      expect(status.nextPatch, isNull);
    });

    test('a ReadPatchException is a failed status', () async {
      final updater = FakeUpdater(current: 3)
        ..readError = const ReadPatchException(message: 'no state file');
      final status = (await adapter(updater).checkAvailability()).status;
      expect(status.state, HotfixState.failed);
      expect(status.available, isTrue);
      expect(status.error, 'no state file');
      expect(status.currentPatch, isNull);
    });

    test('a check that throws is a failed status with the patches', () async {
      final updater = FakeUpdater(current: 3)..checkError = StateError('ffi');
      final status = (await adapter(updater).checkAvailability()).status;
      expect(status.state, HotfixState.failed);
      expect(status.currentPatch, 3);
      expect(status.error, contains('ffi'));
    });

    test('checks and downloads use the configured track', () async {
      final updater = FakeUpdater(current: 1, status: UpdateStatus.outdated);
      await adapter(updater, track: UpdateTrack.beta).downloadAvailablePatch();
      expect(updater.tracks, [UpdateTrack.beta, UpdateTrack.beta]);
      final other = FakeUpdater();
      await adapter(other).checkAvailability();
      expect(other.tracks, [null], reason: "Shorebird's default track");
    });
  });

  group('downloadAvailablePatch', () {
    test('outdated: downloads; restart required with the new patch as '
        'next, the current patch unchanged', () async {
      final updater = FakeUpdater(current: 3, status: UpdateStatus.outdated);
      final a = adapter(updater);
      final result = await a.downloadAvailablePatch();
      expect(result, isA<HotfixRestartRequired>());
      expect((result as HotfixRestartRequired).nextPatch, 4);
      expect(result.status.currentPatch, 3);
      expect(result.status.state, HotfixState.restartRequired);
      expect(updater.calls.where((c) => c == 'update'), hasLength(1));

      final checks = updater.checks;
      final status = await a.getStatus();
      expect(status.state, HotfixState.restartRequired);
      expect(status.currentPatch, 3);
      expect(status.nextPatch, 4);
      expect(updater.checks, checks, reason: 'getStatus reads locally');
    });

    test('a newer patch while one waits for a restart is downloaded', () async {
      final updater = FakeUpdater(
        current: 3,
        next: 4,
        status: UpdateStatus.outdated,
      );
      updater.onUpdate = () => updater.next = 5;
      final a = adapter(updater);
      final availability = await a.checkAvailability();
      expect(availability.status.state, HotfixState.outdated);
      expect(availability.status.nextPatch, 4);
      final result = await a.downloadAvailablePatch();
      expect(result, isA<HotfixRestartRequired>());
      expect(result.status.nextPatch, 5);
    });

    test('up to date: nothing to download', () async {
      final updater = FakeUpdater(current: 3);
      final result = await adapter(updater).downloadAvailablePatch();
      expect(result, isA<HotfixNothingToDownload>());
      expect(result.status.state, HotfixState.upToDate);
      expect(updater.calls, isNot(contains('update')));
    });

    test('already downloaded: restart required without a download', () async {
      final updater = FakeUpdater(
        current: 3,
        next: 4,
        status: UpdateStatus.restartRequired,
      );
      final result = await adapter(updater).downloadAvailablePatch();
      expect(result, isA<HotfixRestartRequired>());
      expect(result.status.nextPatch, 4);
      expect(updater.calls, isNot(contains('update')));
    });

    for (final (reason, wire) in [
      (UpdateFailureReason.downloadFailed, 'download_failed'),
      (UpdateFailureReason.installFailed, 'install_failed'),
      (UpdateFailureReason.unknown, 'unknown'),
    ]) {
      test('UpdateException ${reason.name} fails as $wire', () async {
        final updater = FakeUpdater(current: 3, status: UpdateStatus.outdated)
          ..onUpdate = () =>
              throw UpdateException(message: 'patch broken', reason: reason);
        final a = adapter(updater);
        final result = await a.downloadAvailablePatch();
        expect(result, isA<HotfixDownloadFailed>());
        result as HotfixDownloadFailed;
        expect(result.reason, wire);
        expect(result.message, 'patch broken');
        expect(result.status.state, HotfixState.failed);
        expect(result.status.currentPatch, 3);
        expect(result.status.nextPatch, isNull);
        expect((await a.getStatus()).state, HotfixState.failed);
      });
    }

    test('UpdateException noUpdate: nothing to download', () async {
      final updater = FakeUpdater(current: 3, status: UpdateStatus.outdated)
        ..onUpdate = () => throw const UpdateException(
          message: 'no update',
          reason: UpdateFailureReason.noUpdate,
        );
      final a = adapter(updater);
      expect(await a.downloadAvailablePatch(), isA<HotfixNothingToDownload>());
      expect((await a.getStatus()).state, HotfixState.upToDate);
    });

    test('another download still running: in progress', () async {
      final updater = FakeUpdater(current: 3, status: UpdateStatus.outdated)
        ..onUpdate = () {}
        ..laterChecks.add(UpdateStatus.outdated);
      final result = await adapter(updater).downloadAvailablePatch();
      expect(result, isA<HotfixDownloadInProgress>());
      expect(result.status.state, HotfixState.downloading);
      expect(result.status.nextPatch, isNull);
    });

    test('a download that found nothing after all', () async {
      final updater = FakeUpdater(current: 3, status: UpdateStatus.outdated)
        ..onUpdate = () {}
        ..laterChecks.add(UpdateStatus.upToDate);
      final result = await adapter(updater).downloadAvailablePatch();
      expect(result, isA<HotfixNothingToDownload>());
    });

    test('a check that fails fails the download before it starts', () async {
      final updater = FakeUpdater(current: 3)
        ..checkError = StateError('network');
      final result = await adapter(updater).downloadAvailablePatch();
      expect(result, isA<HotfixDownloadFailed>());
      expect((result as HotfixDownloadFailed).reason, 'check_failed');
      expect(updater.calls, isNot(contains('update')));
    });

    test('any other error is a failed result, never thrown', () async {
      final updater = FakeUpdater(current: 3, status: UpdateStatus.outdated)
        ..onUpdate = () => throw StateError('isolate died');
      final result = await adapter(updater).downloadAvailablePatch();
      expect(result, isA<HotfixDownloadFailed>());
      expect((result as HotfixDownloadFailed).reason, 'error');
      expect(result.status.state, HotfixState.failed);
    });
  });

  group('getStatus', () {
    test('checks once, then reads locally', () async {
      final updater = FakeUpdater(current: 2, status: UpdateStatus.outdated);
      final a = adapter(updater);
      expect((await a.getStatus()).state, HotfixState.outdated);
      expect((await a.getStatus()).state, HotfixState.outdated);
      expect(updater.checks, 1);
    });

    test(
      'a patch downloaded in the background shows as restart required',
      () async {
        final updater = FakeUpdater(current: 2);
        final a = adapter(updater);
        expect((await a.getStatus()).state, HotfixState.upToDate);
        updater.next = 3; // Shorebird's automatic update.
        final status = await a.getStatus();
        expect(status.state, HotfixState.restartRequired);
        expect(status.nextPatch, 3);
      },
    );

    test('downloading while a download runs', () async {
      final gate = Completer<void>();
      final updater = FakeUpdater(current: 2, status: UpdateStatus.outdated);
      updater.onUpdate = () async {
        await gate.future;
        updater.next = 3;
      };
      final a = adapter(updater);
      final download = a.downloadAvailablePatch();
      await pumpEventQueue();
      expect((await a.getStatus()).state, HotfixState.downloading);
      gate.complete();
      expect(await download, isA<HotfixRestartRequired>());
    });

    test(
      'without a release version, none is reported by the adapter',
      () async {
        final status = await adapter(
          FakeUpdater(current: 1),
          releaseVersion: null,
        ).getStatus();
        expect(status.releaseVersion, isNull);
      },
    );
  });

  test('every status the adapter returns can be reported', () async {
    final statuses = <HotfixStatus>[
      await adapter(FakeUpdater(isAvailable: false)).getStatus(),
      await adapter(FakeUpdater()).getStatus(),
      await adapter(
        FakeUpdater(current: 3, status: UpdateStatus.outdated),
      ).getStatus(),
      (await adapter(
        FakeUpdater(current: 3, status: UpdateStatus.outdated),
      ).downloadAvailablePatch()).status,
      await adapter(
        FakeUpdater(current: 3)..checkError = StateError('x'),
      ).getStatus(),
      await adapter(
        FakeUpdater(current: 3, status: UpdateStatus.restartRequired)
          ..next = null,
      ).getStatus(),
    ];
    for (final s in statuses) {
      final json = hotfixRuntimeJson(s, '2.4.1+42');
      expect(json['provider'], 'shorebird');
      expect(json.keys, [
        'provider',
        'available',
        'releaseVersion',
        'currentPatch',
        'nextPatch',
        'state',
      ]);
    }
    expect(statuses.map((s) => s.state.wire), [
      'unavailable',
      'up_to_date',
      'outdated',
      'restart_required',
      'failed',
      'restart_required',
    ]);
  });

  group('ShorebirdCodePushUpdater', () {
    test('maps patches to numbers and passes the track on', () async {
      final shorebird = FakeShorebirdUpdater()
        ..current = const Patch(number: 7)
        ..next = const Patch(number: 8);
      final updater = ShorebirdCodePushUpdater(shorebird);
      expect(updater.isAvailable, isTrue);
      expect(await updater.readCurrentPatch(), 7);
      expect(await updater.readNextPatch(), 8);
      shorebird.next = null;
      expect(await updater.readNextPatch(), isNull);
      expect(
        await updater.checkForUpdate(track: UpdateTrack.staging),
        UpdateStatus.outdated,
      );
      expect(shorebird.track, UpdateTrack.staging);
      await updater.update(track: const UpdateTrack('qa'));
      expect(shorebird.track, const UpdateTrack('qa'));
    });
  });
}
