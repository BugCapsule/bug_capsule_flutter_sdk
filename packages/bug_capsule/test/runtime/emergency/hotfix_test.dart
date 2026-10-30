import 'package:bug_capsule/src/runtime/emergency/hotfix.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The `hotfix` object of runtime reports (§7.6) and the
/// `BugCapsule.emergency.hotfix` wrapper on its own.

HotfixStatus _status({
  String provider = 'shorebird',
  bool available = true,
  HotfixState state = HotfixState.upToDate,
  String? releaseVersion = '2.4.1+42',
  int? currentPatch,
  int? nextPatch,
}) => HotfixStatus(
  provider: provider,
  available: available,
  state: state,
  releaseVersion: releaseVersion,
  currentPatch: currentPatch,
  nextPatch: nextPatch,
);

void main() {
  group('runtime object', () {
    test('the contract example', () {
      expect(
        hotfixRuntimeJson(
          _status(
            state: HotfixState.restartRequired,
            currentPatch: 3,
            nextPatch: 4,
          ),
          '2.4.1',
        ),
        {
          'provider': 'shorebird',
          'available': true,
          'releaseVersion': '2.4.1+42',
          'currentPatch': 3,
          'nextPatch': 4,
          'state': 'restart_required',
        },
      );
    });

    test('every state has its wire name', () {
      expect(HotfixState.values.map((s) => s.wire), [
        'up_to_date',
        'outdated',
        'downloading',
        'restart_required',
        'unavailable',
        'failed',
      ]);
    });

    test('a provider must match ^[a-z][a-z0-9_]{0,31}\$', () {
      for (final ok in ['shorebird', 'a', 'my_push2', 'a' * 32]) {
        expect(hotfixRuntimeJson(_status(provider: ok), null)['provider'], ok);
      }
      for (final bad in [
        '',
        'Shorebird',
        '2push',
        '_x',
        'code-push',
        'a' * 33,
      ]) {
        expect(
          () => hotfixRuntimeJson(_status(provider: bad), null),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('patch numbers are 1 to 2^31-1', () {
      for (final ok in [1, 2147483647]) {
        expect(
          hotfixRuntimeJson(_status(currentPatch: ok), null)['currentPatch'],
          ok,
        );
        expect(
          hotfixRuntimeJson(_status(nextPatch: ok), null)['nextPatch'],
          ok,
        );
      }
      for (final bad in [0, -1, 2147483648]) {
        expect(
          () => hotfixRuntimeJson(_status(currentPatch: bad), null),
          throwsFormatException,
        );
        expect(
          () => hotfixRuntimeJson(_status(nextPatch: bad), null),
          throwsFormatException,
        );
      }
    });

    test('a next patch equal to the current one is null', () {
      final json = hotfixRuntimeJson(
        _status(currentPatch: 5, nextPatch: 5),
        null,
      );
      expect(json['currentPatch'], 5);
      expect(json['nextPatch'], isNull);
    });

    test('release versions: at most 64 characters, else null; the app '
        'version when the provider has none', () {
      String? release(String? v, {bool available = true, String? app}) =>
          hotfixRuntimeJson(
                _status(releaseVersion: v, available: available),
                app,
              )['releaseVersion']
              as String?;
      expect(release('1' * 64), '1' * 64);
      expect(release('1' * 65), isNull);
      expect(release(''), isNull);
      expect(release(null, app: '2.4.1'), '2.4.1');
      expect(release(null, app: '2' * 65), isNull);
      expect(release(null, app: '2.4.1', available: false), isNull);
      expect(release('3.0.0', app: '2.4.1'), '3.0.0');
    });
  });

  group('EmergencyHotfix', () {
    final originalDebugPrint = debugPrint;
    late List<HotfixStatus> seen;

    setUp(() {
      seen = [];
      debugPrint = (String? message, {int? wrapWidth}) {};
    });
    tearDown(() => debugPrint = originalDebugPrint);

    test('passes every status on', () async {
      final provider = FakeHotfixProvider();
      final hotfix = EmergencyHotfix.internal(provider, seen.add);
      expect(hotfix.lastStatus, isNull);
      await hotfix.getStatus();
      final a = await hotfix.checkAvailability();
      expect(a.runtimeAvailable, isTrue);
      expect(a.patchAvailable, isFalse);
      expect(a.restartRequired, isFalse);
      await hotfix.downloadAvailablePatch();
      expect(seen, List.filled(3, FakeHotfixProvider.upToDate));
      expect(hotfix.lastStatus, FakeHotfixProvider.upToDate);
    });

    test('during replay nothing reaches the provider', () async {
      var replaying = true;
      final provider = FakeHotfixProvider();
      final hotfix = EmergencyHotfix.internal(
        provider,
        seen.add,
        isReplaying: () => replaying,
      );
      expect((await hotfix.getStatus()).state, HotfixState.unavailable);
      expect((await hotfix.checkAvailability()).status.available, isFalse);
      expect(
        await hotfix.downloadAvailablePatch(),
        isA<HotfixNothingToDownload>(),
      );
      expect(provider.calls, isEmpty);
      expect(seen, isEmpty);
      replaying = false;
      await hotfix.getStatus();
      expect(provider.calls, ['getStatus']);
    });

    test('a provider that throws before any status: a failed result that is '
        'not passed on', () async {
      final provider = FakeHotfixProvider()..error = StateError('boom');
      final hotfix = EmergencyHotfix.internal(provider, seen.add);
      final status = await hotfix.getStatus();
      expect(status.state, HotfixState.failed);
      expect(status.error, contains('boom'));
      final a = await hotfix.checkAvailability();
      expect(a.status.state, HotfixState.failed);
      final r = await hotfix.downloadAvailablePatch();
      expect(r, isA<HotfixDownloadFailed>());
      expect(seen, isEmpty);
    });

    test('an observer that throws does not affect the result', () async {
      final hotfix = EmergencyHotfix.internal(
        FakeHotfixProvider(),
        (_) => throw StateError('report bug'),
      );
      expect(await hotfix.getStatus(), FakeHotfixProvider.upToDate);
    });
  });
}
