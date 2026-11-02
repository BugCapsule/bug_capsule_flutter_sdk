import 'dart:async';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
// ignore: implementation_imports
import 'package:bug_capsule/src/runtime/storage_root.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// BC-ENT-038: clearLocalData, the persisted collection switch and the
/// saved-capture TTL.
class FakeTransport implements BugCapsuleTransport {
  bool offline = false;
  int fetches = 0;
  final List<List<int>> uploads = [];
  Completer<void>? gate;

  @override
  Future<ConfigFetchResult> fetchConfig() async {
    fetches++;
    if (offline) return const ConfigFetchFailed('offline');
    return ConfigFetched(
      RemoteCaptureConfig(
        enabled: true,
        sampleRate: 1,
        maxCapsuleBytes: 5 * 1024 * 1024,
        captureNetworkBodies: true,
        redactKeys: const [],
        configTtlSeconds: 300,
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<UploadResult> upload(List<int> bytes) async {
    await gate?.future;
    uploads.add(bytes);
    return UploadResult(UploadStatus.uploaded, serverId: 's${uploads.length}');
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeTransport transport;
  late List<String> logs;
  final originalDebugPrint = debugPrint;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bugcapsule-local-data-');
    transport = FakeTransport();
    logs = [];
    debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(
      storageDirectory: dir,
      transport: transport,
    );
  });

  tearDown(() async {
    await BugCapsule.resetForTest();
    BugCapsule.debugOverrides = null;
    debugPrint = originalDebugPrint;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> start({
    bool collectionEnabled = true,
    Duration savedCaptureMaxAge = const Duration(days: 7),
  }) async {
    await BugCapsule.init(
      config: BugCapsuleConfig(
        appVersion: '1.0.0',
        appBuild: '1',
        mode: CaptureMode.qa,
        gitSha: 'abc123',
        autoCaptureOnFailure: false,
        collectionEnabled: collectionEnabled,
        savedCaptureMaxAge: savedCaptureMaxAge,
        backend: const BugCapsuleBackendConfig(
          url: 'https://bugcapsule.test',
          ingestKey: 'bci_test',
        ),
      ),
      appRunner: () {},
    );
    await settle();
  }

  /// A restart: the process ends, the next launch reads the disk again.
  Future<void> restart({bool collectionEnabled = true}) async {
    await BugCapsule.resetForTest();
    await start(collectionEnabled: collectionEnabled);
  }

  List<FileSystemEntity> filesIn(String name) {
    final d = Directory('${dir.path}/$name');
    return d.existsSync() ? d.listSync() : const [];
  }

  /// What an earlier run could have left behind.
  void seedCollectedData() {
    void write(String path) => (File(
      '${dir.path}/$path',
    )..createSync(recursive: true)).writeAsStringSync('x');
    write('captures/c1.bugcapsule');
    write('outbox/1700000000000_c2.bugcapsule');
    write('envelopes/1700000000000_e1.envelope');
    write('journal/4242/header.json');
    write('remote_config.json');
    write('install_id');
    write('session.json');
    write('emergency/policies.json');
  }

  void expectCollectedDataGone() {
    expect(filesIn('captures'), isEmpty);
    expect(filesIn('outbox'), isEmpty);
    expect(filesIn('envelopes'), isEmpty);
    expect(filesIn('journal'), isEmpty);
    for (final f in ['remote_config.json', 'install_id', 'session.json']) {
      expect(File('${dir.path}/$f').existsSync(), isFalse, reason: f);
    }
    expect(
      File('${dir.path}/emergency/policies.json').existsSync(),
      isTrue,
      reason: "emergency policies are the app's safety config, not data",
    );
  }

  /// Queues a capsule that cannot be uploaded yet (the backend is offline).
  Future<void> queueCapsule() async {
    BugCapsule.fail('checkout.failed');
    final r = (await BugCapsule.capture())!;
    expect(r.upload!.status, UploadStatus.retryLater);
  }

  group('clearLocalData', () {
    test('before init deletes what an earlier run left', () async {
      seedCollectedData();
      await BugCapsule.setCollectionEnabled(true);
      await BugCapsule.clearLocalData();
      expectCollectedDataGone();
      expect(
        File('${dir.path}/collection_enabled').existsSync(),
        isTrue,
        reason: 'the collection choice is kept',
      );
    });

    test('before init without any storage never throws', () async {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: Directory('${dir.path}/missing'),
      );
      await BugCapsule.clearLocalData();
    });

    test(
      'after init deletes queued capsules and saved captures and restarts the buffer',
      () async {
        transport.offline = true;
        await start();
        BugCapsule.log('before-clear-marker');
        await queueCapsule();
        expect(filesIn('outbox'), hasLength(1));
        expect(await BugCapsule.savedCaptures(), hasLength(1));

        await BugCapsule.clearLocalData();

        expect(filesIn('outbox'), isEmpty);
        expect(await BugCapsule.savedCaptures(), isEmpty);
        expect(BugCapsule.isRecording, isTrue);
        for (final f in Directory(
          '${dir.path}/journal',
        ).listSync(recursive: true).whereType<File>()) {
          expect(f.readAsStringSync(), isNot(contains('before-clear-marker')));
        }

        BugCapsule.log('after-clear-marker');
        final capsule = CapsuleCodec.decode(
          await (await BugCapsule.capture())!.file.readAsBytes(),
        );
        final logged = capsule
            .eventsOfType(EventTypes.log)
            .map((e) => e.data['message']);
        expect(logged, ['after-clear-marker']);
        expect(
          capsule.manifest.failure,
          isNull,
          reason: 'the last failure was cleared too',
        );
      },
    );

    test('is safe while an upload is on the wire', () async {
      await start();
      transport.gate = Completer<void>();
      BugCapsule.fail('x');
      final pending = BugCapsule.capture();
      await settle();
      expect(filesIn('outbox'), hasLength(1));

      await BugCapsule.clearLocalData().timeout(const Duration(seconds: 2));
      expect(filesIn('outbox'), isEmpty);

      transport.gate!.complete();
      final result = (await pending)!;
      expect(result.upload!.status, UploadStatus.uploaded);
      expect(transport.uploads, hasLength(1));
      expect(filesIn('outbox'), isEmpty);
      expect(BugCapsule.isRecording, isTrue);
    });
  });

  group('collection switch', () {
    test(
      'off by config: no capture, no network, leftovers deleted, status says why',
      () async {
        seedCollectedData();
        await start(collectionEnabled: false);
        expect(BugCapsule.collectionEnabled, isFalse);
        expect(BugCapsule.isRecording, isFalse);
        expect(transport.fetches, 0, reason: 'no network contact at startup');
        expectCollectedDataGone();

        BugCapsule.fail('x');
        expect(await BugCapsule.capture(), isNull);
        await BugCapsule.flushUploads();
        await BugCapsule.refreshRemoteConfig();
        expect(transport.fetches, 0);
        expect(transport.uploads, isEmpty);

        final status = BugCapsule.status.connection;
        expect(status.state, BugCapsuleConnectionState.disabled);
        expect(status.reason, 'collection_disabled');
        expect(status.message, contains('setCollectionEnabled'));
      },
    );

    test(
      'switched off after init: capture stops and queued and saved data is deleted',
      () async {
        transport.offline = true;
        await start();
        await queueCapsule();
        expect(BugCapsule.isRecording, isTrue);

        await BugCapsule.setCollectionEnabled(false);

        expect(BugCapsule.collectionEnabled, isFalse);
        expect(BugCapsule.isRecording, isFalse);
        expect(filesIn('outbox'), isEmpty);
        expect(await BugCapsule.savedCaptures(), isEmpty);
        expect(filesIn('journal'), isEmpty);
        BugCapsule.fail('y');
        expect(await BugCapsule.capture(), isNull);
        expect(BugCapsule.captureMessage('hello'), isNull);

        transport.offline = false;
        final fetches = transport.fetches;
        await BugCapsule.flushUploads();
        expect(transport.uploads, isEmpty);
        expect(transport.fetches, fetches, reason: 'no network contact');
        expect(BugCapsule.status.connection.reason, 'collection_disabled');
      },
    );

    test(
      'the choice persists across a restart and wins over the config',
      () async {
        await start();
        await BugCapsule.setCollectionEnabled(false);

        await restart();
        expect(BugCapsule.collectionEnabled, isFalse);
        expect(BugCapsule.isRecording, isFalse);
        expect(transport.fetches, 1, reason: 'only the first launch fetched');

        // Switching on again resumes at the next launch.
        await BugCapsule.setCollectionEnabled(true);
        expect(BugCapsule.collectionEnabled, isTrue);
        expect(BugCapsule.isRecording, isFalse);
        expect(BugCapsule.status.connection.message, contains('next launch'));

        await restart(collectionEnabled: false);
        expect(BugCapsule.collectionEnabled, isTrue);
        expect(BugCapsule.isRecording, isTrue);
        expect(
          BugCapsule.status.connection.reason,
          isNot('collection_disabled'),
        );
      },
    );

    test('a choice made before init applies at init', () async {
      seedCollectedData();
      await BugCapsule.setCollectionEnabled(false);
      expect(BugCapsule.collectionEnabled, isFalse);
      expectCollectedDataGone();

      await start();
      expect(BugCapsule.isRecording, isFalse);
      expect(transport.fetches, 0);
    });
  });

  group('saved-capture TTL', () {
    test('expired captures are removed at startup and when listing', () async {
      final captures = Directory('${dir.path}/captures')
        ..createSync(recursive: true);
      final old = File('${captures.path}/old.bugcapsule')
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));
      await start();
      expect(old.existsSync(), isFalse, reason: 'removed at startup');

      BugCapsule.fail('x');
      final file = (await BugCapsule.capture())!.file;
      expect(await BugCapsule.savedCaptures(), hasLength(1));

      file.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 7, minutes: 1)),
      );
      expect(await BugCapsule.savedCaptures(), isEmpty);
      expect(file.existsSync(), isFalse, reason: 'removed when listing');
    });

    test('the TTL is configurable', () async {
      await start(savedCaptureMaxAge: const Duration(hours: 1));
      BugCapsule.fail('x');
      final file = (await BugCapsule.capture())!.file;
      file.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 30)),
      );
      expect(await BugCapsule.savedCaptures(), hasLength(1));
      file.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      expect(await BugCapsule.savedCaptures(), isEmpty);
    });
  });

  group('storage root', () {
    test("Android's no-backup directory sits next to files/", () {
      expect(
        androidNoBackupDirectory(
          Directory('/data/user/0/com.shop/files'),
        )?.path,
        '/data/user/0/com.shop/no_backup',
      );
      expect(androidNoBackupDirectory(Directory('/data/elsewhere')), isNull);
    });

    test(
      'a root left in files/ by an older SDK moves out of backups',
      () async {
        final legacy = Directory('${dir.path}/files/bugcapsule');
        final root = Directory('${dir.path}/no_backup/bugcapsule');
        File('${legacy.path}/outbox/1_a.bugcapsule')
          ..createSync(recursive: true)
          ..writeAsStringSync('q');
        await moveLegacyRoot(legacy, root);
        expect(legacy.existsSync(), isFalse);
        expect(
          File('${root.path}/outbox/1_a.bugcapsule').readAsStringSync(),
          'q',
        );

        // A leftover next to an existing root is deleted, not merged.
        File('${legacy.path}/install_id')
          ..createSync(recursive: true)
          ..writeAsStringSync('old');
        await moveLegacyRoot(legacy, root);
        expect(legacy.existsSync(), isFalse);
        expect(File('${root.path}/install_id').existsSync(), isFalse);
      },
    );
  });
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));
