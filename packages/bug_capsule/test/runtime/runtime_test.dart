import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule/bug_capsule.dart';

/// Synthetic secrets: none of these may appear in a capsule or in logs.
const secrets = [
  'synthAccessToken001',
  'synthBearer0123456789',
  'synthQueryToken002',
  'synthRefresh003',
  'hunter2-synthetic',
  'synthTextToken004',
  'synthPinValue005',
  'synthLogToken006',
  '4242424242424242',
  'synthFailToken007',
  'synthLabelKey008',
  'synthLabelBearer0123456',
  'synthNote009',
  'synthLoyalty010',
];

class FakeTransport implements BugCapsuleTransport {
  bool enabled = true;
  bool bodies = true;
  bool offline = false;
  double sampleRate = 1;
  List<String> redactKeys = const [];
  int fetches = 0;
  final List<List<int>> uploads = [];
  Completer<void>? gate;

  @override
  Future<ConfigFetchResult> fetchConfig() async {
    fetches++;
    if (offline) return const ConfigFetchFailed('offline');
    return ConfigFetched(
      RemoteCaptureConfig(
        enabled: enabled,
        sampleRate: sampleRate,
        maxCapsuleBytes: 5 * 1024 * 1024,
        captureNetworkBodies: bodies,
        redactKeys: redactKeys,
        configTtlSeconds: 300,
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<UploadResult> upload(List<int> bytes) async {
    await gate?.future;
    uploads.add(bytes);
    return UploadResult(
      UploadStatus.uploaded,
      serverId: 'srv-${uploads.length}',
    );
  }

  @override
  void close() {}
}

/// Records custom data and snapshots, like a third-party integration would.
class SecretIntegration extends BugCapsuleIntegration {
  BugCapsuleSession? session;

  @override
  String get name => 'custom';

  @override
  Future<void> setUp(BugCapsuleSession session) async => this.session = session;

  @override
  Object? snapshot(CheckpointKind kind) => {
    'session': {'accessToken': 'synthAccessToken001'},
    'header': 'Bearer synthBearer0123456789',
    'next': 'https://api.test/page?token=synthQueryToken002',
    'blob': jsonEncode({'refresh_token': 'synthRefresh003', 'theme': 'dark'}),
  };
}

class HangingIntegration extends BugCapsuleIntegration {
  @override
  String get name => 'hanging';

  @override
  Future<void> setUp(BugCapsuleSession session) => Completer<void>().future;
}

class ThrowingIntegration extends BugCapsuleIntegration {
  @override
  String get name => 'broken';

  @override
  Future<void> setUp(BugCapsuleSession session) async =>
      throw StateError('setup exploded');
}

/// Returns scripted values for sampling decisions.
class ScriptedRandom implements Random {
  ScriptedRandom(this.values);
  final List<double> values;
  @override
  double nextDouble() => values.removeAt(0);
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeTransport transport;
  late List<String> logs;
  final originalDebugPrint = debugPrint;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bugcapsule-runtime-');
    transport = FakeTransport();
    logs = [];
    debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
  });

  tearDown(() async {
    await BugCapsule.resetForTest();
    BugCapsule.debugOverrides = null;
    debugPrint = originalDebugPrint;
    await _deleteDir(dir);
  });

  Future<bool> start({
    CaptureMode mode = CaptureMode.qa,
    List<BugCapsuleIntegration> integrations = const [],
    Map<String, String> labels = const {},
    double productionSampleRate = 0.1,
    Random? random,
    Directory? storage,
    bool backend = true,
    Future<List<int>> Function(Capsule)? encodeCapsule,
  }) async {
    BugCapsule.debugOverrides = BugCapsuleTestOverrides(
      storageDirectory: storage ?? dir,
      transport: backend ? transport : null,
      random: random,
      encodeCapsule: encodeCapsule,
    );
    var ran = false;
    await BugCapsule.init(
      config: BugCapsuleConfig(
        appVersion: '1.0.0',
        appBuild: '1',
        mode: mode,
        gitSha: 'abc123',
        autoCaptureOnFailure: false,
        labels: labels,
        productionSampleRate: productionSampleRate,
        backend: backend
            ? const BugCapsuleBackendConfig(
                url: 'https://bugcapsule.test',
                ingestKey: 'bci_test',
              )
            : null,
      ),
      integrations: integrations,
      appRunner: () => ran = true,
    );
    await settle();
    return ran;
  }

  Future<Map<String, Object?>> capsuleJson(CaptureResult r) async =>
      (jsonDecode(utf8.decode(gzip.decode(await r.file.readAsBytes()))) as Map)
          .cast<String, Object?>();

  group('isolation', () {
    test('screenshot survives runtime redaction and capsule encoding', () async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAC0lEQVR4nGNgAAMAAAcAAbKGrPQAAAAASUVORK5CYII=',
      );
      final pictures = ScreenshotIntegration(
        enabled: true,
        captureRedactedPng: () => bytes,
      );
      await start(integrations: [pictures], backend: false);
      expect(await pictures.capture(), true);
      final result = (await BugCapsule.capture())!;
      final capsule = CapsuleCodec.decode(await result.file.readAsBytes());
      expect(
        capsule.events
            .singleWhere((e) => e.type == 'screenshot')
            .data['base64'],
        base64Encode(bytes),
      );
    });

    test('the app starts when storage cannot be opened', () async {
      final notADir = File('${dir.path}/file')..writeAsStringSync('x');
      expect(await start(storage: Directory(notADir.path)), isTrue);
      expect(BugCapsule.isRecording, isFalse);
      expect(logs.join('\n'), contains('capture setup failed'));
    });

    test(
      'the app starts and records when an integration fails to set up',
      () async {
        expect(await start(integrations: [ThrowingIntegration()]), isTrue);
        expect(BugCapsule.isRecording, isTrue);
        expect(logs.join('\n'), contains('broken setup failed'));
      },
    );

    test('the app starts when capture setup never finishes', () async {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: dir,
        transport: transport,
        setupTimeout: const Duration(milliseconds: 200),
      );
      var ran = false;
      await BugCapsule.init(
        config: const BugCapsuleConfig(
          appVersion: '1',
          appBuild: '1',
          mode: CaptureMode.qa,
        ),
        integrations: [HangingIntegration()],
        appRunner: () => ran = true,
      ).timeout(const Duration(seconds: 2));
      expect(ran, isTrue);
      expect(BugCapsule.isRecording, isFalse);
    });

    test('the app starts with capture disabled locally', () async {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: dir,
        transport: transport,
      );
      var ran = false;
      await BugCapsule.init(
        config: const BugCapsuleConfig(
          appVersion: '1',
          appBuild: '1',
          enabled: false,
        ),
        appRunner: () => ran = true,
      );
      expect(ran, isTrue);
      expect(BugCapsule.isRecording, isFalse);
      expect(transport.fetches, 0);
    });
  });

  test('no synthetic secret reaches a capsule or the logs', () async {
    final custom = SecretIntegration();
    await start(
      integrations: [custom],
      labels: {
        'apiKey': 'synthLabelKey008',
        'ticket': 'Bearer synthLabelBearer0123456',
      },
    );
    custom.session!.record('custom.event', {
      'auth': {'refresh_token': 'synthRefresh003'},
      'msg': 'login failed {password: hunter2-synthetic}',
    });
    final notes = TextEditingController();
    BugCapsule.trackText('notes', notes);
    notes.text = 'pasted token=synthTextToken004';
    final pin = TextEditingController();
    BugCapsule.trackText('field7', pin, sensitive: true);
    pin.text = 'synthPinValue005';
    BugCapsule.log('calling https://api.test/x?access_token=synthLogToken006');
    BugCapsule.actionWithPayload('pay', (_) {})({
      'cardNumber': '4242424242424242',
      'amount': 5,
    });
    BugCapsule.session!.reportError(
      StateError('upload failed token=synthFailToken007'),
      StackTrace.current,
    );

    final result = (await BugCapsule.capture(note: 'password=synthNote009'))!;
    final raw = jsonEncode(await capsuleJson(result));
    for (final s in secrets) {
      expect(raw, isNot(contains(s)), reason: 'capsule leaks $s');
      expect(logs.join('\n'), isNot(contains(s)), reason: 'logs leak $s');
    }
    // Still a valid, decodable capsule with the failure and the evidence.
    final capsule = CapsuleCodec.decode(await result.file.readAsBytes());
    expect(capsule.manifest.failure!.message, contains('[REDACTED]'));
    // Runtime metadata (spec runtimes-v1 §2).
    expect(capsule.manifest.runtime?.name, 'flutter');
    expect(capsule.manifest.runtimeName, 'flutter');
    expect(capsule.manifest.capabilities['input.pointer.replay'], 'supported');
    expect(capsule.checkpoint.data['custom'], isNotNull);
    expect(capsule.eventsOfType('custom.event'), hasLength(1));
    expect(capsule.manifest.labels['apiKey'], '[REDACTED]');
  });

  test(
    'beforeRecord and beforeCheckpoint can drop or rewrite data; a throwing hook drops',
    () async {
      BugCapsule.debugOverrides = BugCapsuleTestOverrides(
        storageDirectory: dir,
      );
      await BugCapsule.init(
        config: BugCapsuleConfig(
          appVersion: '1',
          appBuild: '1',
          mode: CaptureMode.qa,
          beforeRecord: (type, data) => switch (type) {
            'drop.me' => null,
            'boom' => throw StateError('hook bug'),
            _ => {...data, 'tag': 'seen'},
          },
          beforeCheckpoint: (name, data) => name == 'custom' ? null : data,
        ),
        integrations: [SecretIntegration()],
        appRunner: () {},
      );
      BugCapsule.session!.record('keep', {'a': 1});
      BugCapsule.session!.record('drop.me', {'a': 2});
      BugCapsule.session!.record('boom', {'a': 3});
      BugCapsule.fail('x');
      final capsule = CapsuleCodec.decode(
        await (await BugCapsule.capture())!.file.readAsBytes(),
      );
      expect(
        capsule.events.map((e) => e.type),
        containsAllInOrder(['keep', 'failure']),
      );
      expect(
        capsule.events.where((e) => e.type == 'drop.me' || e.type == 'boom'),
        isEmpty,
      );
      expect(capsule.eventsOfType('keep').single.data['tag'], 'seen');
      expect(capsule.checkpoint.data.containsKey('custom'), isFalse);
    },
  );

  group('remote config', () {
    test(
      'kill switch during an upload: no new upload starts, queue and history are purged',
      () async {
        await start();
        expect(BugCapsule.isRecording, isTrue);
        transport.gate = Completer<void>();
        BugCapsule.fail('first');
        final a = BugCapsule.capture();
        await settle();
        BugCapsule.fail('second');
        final b = BugCapsule.capture();
        await settle();
        expect(
          transport.uploads,
          isEmpty,
          reason: 'first upload is on the wire',
        );

        transport.enabled = false;
        await BugCapsule.refreshRemoteConfig();
        await settle();
        expect(BugCapsule.isRecording, isFalse);
        expect(Directory('${dir.path}/outbox').listSync(), isEmpty);
        expect(await BugCapsule.savedCaptures(), isEmpty);

        transport.gate!.complete();
        await a;
        await b;
        expect(
          transport.uploads,
          hasLength(1),
          reason: 'only the upload already in flight finishes',
        );
        expect(await BugCapsule.capture(), isNull);
        await BugCapsule.flushUploads();
        expect(transport.uploads, hasLength(1));
      },
    );

    test(
      'a capture being encoded when the kill switch fires is discarded',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        await start(
          encodeCapsule: (capsule) async {
            entered.complete();
            await release.future;
            return CapsuleCodec.encode(capsule);
          },
        );
        BugCapsule.fail('x');
        final pending = BugCapsule.capture();
        await entered.future;
        transport.enabled = false;
        await BugCapsule.refreshRemoteConfig();
        release.complete();
        expect(await pending, isNull);
        await settle();
        expect(transport.uploads, isEmpty);
        expect(Directory('${dir.path}/outbox').listSync(), isEmpty);
        expect(await BugCapsule.savedCaptures(), isEmpty);
      },
    );

    test('turning bodies off strips bodies already buffered', () async {
      await start();
      BugCapsule.session!.record(EventTypes.http, {
        'key': 'GET api.test/me',
        'status': 200,
        'responseBody': {'name': 'synthetic-user'},
        'bodyEncoding': 'json',
      });
      transport.bodies = false;
      await BugCapsule.refreshRemoteConfig();
      expect(BugCapsule.session!.captureNetworkBodies, isFalse);
      BugCapsule.fail('x');
      final capsule = CapsuleCodec.decode(
        await (await BugCapsule.capture())!.file.readAsBytes(),
      );
      final http = capsule.eventsOfType(EventTypes.http).single.data;
      expect(http['responseBody'], isNull);
      expect(http['bodyEncoding'], 'omitted');
    });

    test(
      'an exchange that finishes after bodies were turned off is kept without its body',
      () async {
        await start();
        transport.bodies = false;
        await BugCapsule.refreshRemoteConfig();
        // Dio recorded this request with bodies on when it started.
        BugCapsule.session!.record(EventTypes.http, {
          'key': 'GET api.test/me',
          'status': 200,
          'responseBody': {'name': 'synthetic-late-body'},
          'bodyEncoding': 'json',
        });
        BugCapsule.fail('x');
        final result = (await BugCapsule.capture())!;
        expect(
          jsonEncode(await capsuleJson(result)),
          isNot(contains('synthetic-late-body')),
        );
      },
    );

    test(
      'new redaction keys drop buffered exchanges (their keys used the old rules)',
      () async {
        await start();
        BugCapsule.session!.record(EventTypes.http, {
          'key': 'GET api.test/me?member=synthMember11',
          'url': 'https://api.test/me?member=synthMember11',
          'status': 200,
          'bodyEncoding': 'omitted',
        });
        transport.redactKeys = ['member'];
        await BugCapsule.refreshRemoteConfig();
        BugCapsule.fail('x');
        final result = (await BugCapsule.capture())!;
        expect(
          jsonEncode(await capsuleJson(result)),
          isNot(contains('synthMember11')),
        );
        final capsule = CapsuleCodec.decode(await result.file.readAsBytes());
        expect(capsule.eventsOfType(EventTypes.http), isEmpty);
        expect(
          capsule.manifest.eligibility.missing.map((m) => m.dependency),
          contains('events.redaction'),
        );
      },
    );

    test('an oversized QA note cannot make the capsule unreadable', () async {
      await start();
      BugCapsule.fail('x');
      final result = (await BugCapsule.capture(note: 'n' * 5000))!;
      final capsule = CapsuleCodec.decode(await result.file.readAsBytes());
      expect(capsule.manifest.labels['note']!.length, 2000);
      expect(result.upload!.status, isNot(UploadStatus.rejected));
    });

    test(
      'new remote redaction keys apply to buffered events and travel in the manifest',
      () async {
        await start();
        BugCapsule.session!.record('custom', {'loyaltyId': 'synthLoyalty010'});
        transport.redactKeys = ['loyaltyId'];
        await BugCapsule.refreshRemoteConfig();
        BugCapsule.fail('x');
        final result = (await BugCapsule.capture())!;
        expect(
          jsonEncode(await capsuleJson(result)),
          isNot(contains('synthLoyalty010')),
        );
        final capsule = CapsuleCodec.decode(await result.file.readAsBytes());
        expect(capsule.manifest.redactionKeys, contains('loyaltyId'));
      },
    );

    test(
      'with no config yet, captures wait offline and upload once a fetch succeeds',
      () async {
        transport.offline = true;
        await start();
        expect(BugCapsule.isRecording, isTrue);
        BugCapsule.fail('x');
        final r = (await BugCapsule.capture())!;
        expect(r.upload!.status, UploadStatus.retryLater);
        expect(transport.uploads, isEmpty);
        transport.offline = false;
        await BugCapsule.flushUploads();
        expect(transport.uploads, hasLength(1));
      },
    );

    test(
      'production sampling uses the lower of the app cap and the remote rate',
      () async {
        transport.sampleRate = 0.9;
        // Cap 0.5: 0.6 is above it, so this session does not record.
        await start(
          mode: CaptureMode.production,
          productionSampleRate: 0.5,
          random: ScriptedRandom([0.6]),
        );
        expect(BugCapsule.isRecording, isFalse);
      },
    );

    test(
      'lowering the sample rate keeps a session with probability new/old',
      () async {
        // Cached rate 1.0 → effective 0.5 (cap). 0.3 < 0.5: recording.
        await start(
          mode: CaptureMode.production,
          productionSampleRate: 0.5,
          random: ScriptedRandom([0.3, 0.7]),
        );
        expect(BugCapsule.isRecording, isTrue);
        // 0.5 → 0.1 keeps with probability 0.2; the next draw (0.7) drops it.
        transport.sampleRate = 0.1;
        await BugCapsule.refreshRemoteConfig();
        expect(BugCapsule.isRecording, isFalse);
      },
    );

    test(
      'a cached kill switch applies at the next launch even offline',
      () async {
        transport.enabled = false;
        await start();
        await BugCapsule.resetForTest();
        transport
          ..enabled = true
          ..offline = true;
        await start();
        expect(BugCapsule.isRecording, isFalse);
      },
    );
  });
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

/// A setup abandoned after its timeout keeps running in the background and
/// can still write into [dir] (store, outbox, config cache) while it is
/// deleted; retry instead of failing the test on that race.
Future<void> _deleteDir(Directory dir) async {
  for (var attempt = 0; ; attempt++) {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= 10) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
