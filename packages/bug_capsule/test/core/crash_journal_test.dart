import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/src/core/core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

Checkpoint _launch() => const Checkpoint(
  kind: CheckpointKind.launch,
  t: 100,
  wallClockMs: 1792922390000,
  afterSeq: 0,
  data: {'route': '/'},
);

Map<String, Object?> _header({
  String? gitSha = 'abc123',
  List<Map<String, Object?>> dependencies = const [],
  Map<String, Object?> gaps = const {},
}) => {
  'journal': 1,
  'pid': 4242,
  'processId': '4242',
  'release': 'com.shop.app@1.0.0+1',
  'environment': 'qa',
  'writtenAt': '2026-10-26T10:00:00.000Z',
  'anchorMs': 100,
  'mode': 'qa',
  'app': {'id': 'com.shop.app', 'version': '1.0.0', 'build': '1'},
  'source': {'gitSha': gitSha, 'dirty': false},
  'sdk': {'name': 'bug_capsule_flutter', 'version': '0.5.0'},
  'stateSchemaVersion': 1,
  'platform': {
    'os': 'android',
    'osVersion': '16',
    'locale': 'en_US',
    'screen': {'width': 411.0, 'height': 914.0, 'pixelRatio': 2.625},
    'dartVersion': '3.11.0',
  },
  'session': {
    'id': 's-1',
    'startedAt': '2026-10-26T09:59:50.000Z',
    'wallClockAtAnchorMs': 1792922390000,
    'seed': 7,
  },
  'integrations': ['go_router'],
  'redaction': {'extraKeys': <String>[], 'extraHeaders': <String>[]},
  'labels': {'team': 'checkout'},
  'runtime': {
    'name': 'flutter',
    'version': '3.11.0',
    'language': 'dart',
    'frameworks': ['flutter'],
  },
  'capabilities': {'input.pointer.replay': 'supported'},
  'dependencies': dependencies,
  'eligibilityGaps': gaps,
  'rewriteDropped': 0,
};

CrashCapsuleRequest _request({
  int maxCapsuleBytes = 5 * 1024 * 1024,
  DateTime? crashedAt,
}) => CrashCapsuleRequest(
  capsuleId: 'c0ffee00-0000-4000-8000-000000000001',
  createdAt: DateTime.utc(2026, 10, 26, 10, 1),
  failure: CrashFailure.fromEvent(_crashEvent()),
  monitoring: const CapsuleMonitoring(
    eventId: '22222222-2222-4222-8222-222222222222',
    release: 'com.shop.app@1.0.0+1',
    environment: 'qa',
  ),
  maxCapsuleBytes: maxCapsuleBytes,
  crashedAt: crashedAt,
);

ErrorEvent _crashEvent({
  String type = 'SIGSEGV',
  String mechanism = 'signal',
  Map<String, Object?>? data = const {'signal': 11, 'code': 1},
}) => ErrorEvent.fromJson({
  'eventId': '22222222-2222-4222-8222-222222222222',
  'timestamp': '2026-10-26T10:00:05.000Z',
  'level': 'fatal',
  'exception': {
    'values': [
      {
        'type': type,
        'value': 'Segmentation violation (code 1) at 0x0',
        'mechanism': {'type': mechanism, 'handled': false, 'data': data},
        'stacktrace': {
          'frames': [
            {'function': 'main', 'package': '/x/libapp.so', 'inApp': true},
            {
              'function': 'checkout_native',
              'package': '/x/libshop.so',
              'inApp': true,
            },
            {'function': 'memcpy', 'package': '/x/libc.so', 'inApp': false},
          ],
        },
      },
    ],
  },
})!;

void main() {
  late Directory root;
  late Directory dir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bugcapsule-journal-');
    dir = Directory('${root.path}/journal/4242');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  (FlightRecorder, CrashJournal, JournalWriter) startJournal({
    int maxBytes = 1 << 20,
    int maxEvents = 20000,
    Map<String, Object?>? header,
  }) {
    final recorder = FlightRecorder(launch: _launch(), maxEvents: maxEvents);
    final writer = JournalWriter(dir, maxBytes: maxBytes);
    final journal = CrashJournal.start(
      directory: dir,
      recorder: recorder,
      header: header ?? _header(),
      sink: InlineJournalSink(writer),
    );
    return (recorder, journal, writer);
  }

  List<String> files(String sub) {
    final d = Directory('${dir.path}/$sub');
    if (!d.existsSync()) return const [];
    return [
      for (final f in d.listSync().whereType<File>()) f.uri.pathSegments.last,
    ]..sort();
  }

  group('journal', () {
    test('writes the header and launch checkpoint at once', () {
      startJournal();
      final header =
          jsonDecode(File('${dir.path}/header.json').readAsStringSync()) as Map;
      expect(header['pid'], 4242);
      expect(files('checkpoints'), ['0.json']);
      expect(files('events'), isEmpty);
    });

    test('hands events over in one batch per flush, at most every 250 ms', () {
      FakeAsync().run((async) {
        final (recorder, _, _) = startJournal();
        recorder.add(150, 'pointer', {'phase': 'down', 'x': 1.0, 'y': 2.0});
        recorder.add(160, 'pointer', {'phase': 'up', 'x': 1.0, 'y': 2.0});
        expect(files('events'), isEmpty, reason: 'nothing written yet');
        async.elapse(const Duration(milliseconds: 249));
        expect(files('events'), isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(files('events'), ['1.jsonl']);
        final lines = File(
          '${dir.path}/events/1.jsonl',
        ).readAsLinesSync().map(jsonDecode).toList();
        expect(lines, hasLength(2));
        expect((lines.last as Map)['seq'], 2);
      });
    });

    test('a checkpoint flushes at once and starts a new events file', () {
      FakeAsync().run((async) {
        final (recorder, journal, _) = startJournal();
        recorder.add(150, 'action', {'id': 'pay'});
        recorder.addCheckpoint(
          recorder.checkpointNow(
            kind: CheckpointKind.periodic,
            t: 200,
            wallClockMs: 1792922390100,
            data: const {},
          ),
        );
        expect(files('checkpoints'), ['0.json', '1.json']);
        recorder.add(250, 'action', {'id': 'confirm'});
        journal.flush();
        expect(files('events'), ['1.jsonl', '2.jsonl']);
      });
    });

    test('flush() writes what is pending right away (failure, background)', () {
      final (recorder, journal, _) = startJournal();
      recorder.add(150, 'failure', {'signature': 'exception:X:y'});
      journal.flush();
      expect(files('events'), ['1.jsonl']);
      journal.discard();
    });

    test('mirrors eviction: the launch checkpoint and older files go', () {
      final (recorder, journal, _) = startJournal(maxEvents: 3);
      for (var i = 0; i < 3; i++) {
        recorder.add(110 + i, 'action', {'id': 'a$i'});
      }
      recorder.addCheckpoint(
        recorder.checkpointNow(
          kind: CheckpointKind.periodic,
          t: 200,
          wallClockMs: 1792922390100,
          data: const {},
        ),
      );
      recorder.add(210, 'action', {'id': 'b'});
      journal.flush();
      expect(recorder.launchCoversWindow, isFalse);
      expect(files('checkpoints'), ['3.json']);
      expect(files('events'), ['4.jsonl']);

      // A newer periodic checkpoint replaces the older one.
      recorder.add(220, 'action', {'id': 'c'});
      recorder.addCheckpoint(
        recorder.checkpointNow(
          kind: CheckpointKind.periodic,
          t: 300,
          wallClockMs: 1792922390200,
          data: const {},
        ),
      );
      recorder.add(310, 'action', {'id': 'd'});
      journal.flush();
      expect(files('checkpoints'), ['5.json']);
      expect(files('events'), ['6.jsonl']);
    });

    test('stays under its size cap by dropping the oldest events file', () {
      final (recorder, journal, writer) = startJournal(maxBytes: 3000);
      for (var i = 0; i < 10; i++) {
        recorder.add(110 + i, 'log', {'message': 'x' * 100});
      }
      recorder.addCheckpoint(
        recorder.checkpointNow(
          kind: CheckpointKind.periodic,
          t: 200,
          wallClockMs: 1792922390100,
          data: const {},
        ),
      );
      for (var i = 0; i < 20; i++) {
        recorder.add(210 + i, 'log', {'message': 'y' * 100});
        journal.flush();
      }
      expect(writer.totalBytes, lessThanOrEqualTo(3000));
      expect(files('checkpoints'), ['10.json'], reason: 'launch is gone');
      expect(File('${dir.path}/truncated').existsSync(), isTrue);
      expect(files('events'), isNot(contains('1.jsonl')));
    });

    test('a rewrite (new redaction rules) replaces what was written', () {
      final (recorder, journal, _) = startJournal();
      recorder.add(150, 'log', {'message': 'token=secret'});
      journal.flush();
      recorder.rewrite(
        event: (e) => BugCapsuleEvent(
          seq: e.seq,
          t: e.t,
          type: e.type,
          data: {'message': '[REDACTED]'},
        ),
      );
      journal.flush();
      final text = Directory(
        '${dir.path}/events',
      ).listSync().whereType<File>().map((f) => f.readAsStringSync()).join();
      expect(text, isNot(contains('secret')));
      expect(text, contains('[REDACTED]'));
    });

    test('discard deletes the journal; close keeps it', () async {
      final (recorder, journal, _) = startJournal();
      recorder.add(150, 'action', {'id': 'a'});
      await journal.close();
      expect(dir.existsSync(), isTrue);
      expect(recorder.listener, isNull);

      final (_, other, _) = startJournal();
      await other.discard();
      expect(dir.existsSync(), isFalse);
    });

    test('the isolate writer writes what it was sent', () async {
      final recorder = FlightRecorder(launch: _launch());
      final journal = CrashJournal.start(
        directory: dir,
        recorder: recorder,
        header: _header(),
        sink: IsolateJournalSink.start(dir, maxBytes: 1 << 20),
      );
      recorder.add(150, 'action', {'id': 'a'});
      await journal.close();
      final contents = JournalContents.read(dir)!;
      expect(contents.launch, isNotNull);
      expect(contents.events.single.data, {'id': 'a'});
    });

    test('reading skips a last line the crash cut short', () {
      final (recorder, journal, _) = startJournal();
      recorder.add(150, 'action', {'id': 'a'});
      journal.flush();
      File(
        '${dir.path}/events/1.jsonl',
      ).writeAsStringSync('{"seq":2,"t":1', mode: FileMode.append);
      final contents = JournalContents.read(dir)!;
      expect(contents.events.map((e) => e.seq), [1]);
    });
  });

  group('crash capsule', () {
    JournalContents journalWith(
      void Function(FlightRecorder r) record, {
      Map<String, Object?>? header,
      int maxEvents = 20000,
    }) {
      final (recorder, journal, _) = startJournal(
        header: header,
        maxEvents: maxEvents,
      );
      record(recorder);
      journal.flush();
      return JournalContents.read(dir)!;
    }

    test('from the launch checkpoint: failure crash, gap, labels, v2', () {
      final journal = journalWith((r) {
        r.add(1100, 'action', {'id': 'pay'});
        r.add(1200, 'action', {'id': 'confirm'});
      });
      final build = buildCrashCapsule(
        journal,
        _request(crashedAt: DateTime.fromMillisecondsSinceEpoch(1792922391300)),
      )!;
      final doc = CapsuleCodec.toJson(CapsuleCodec.decode(build.bytes));
      expect(doc['specVersion'], 2);
      final capsule = CapsuleCodec.decode(build.bytes);
      final m = capsule.manifest;
      expect(m.failure!.kind, FailureKind.crash);
      expect(m.failure!.signature, 'crash:SIGSEGV');
      expect(m.failure!.type, 'SIGSEGV');
      expect(m.failure!.crash!.mechanism, 'signal');
      expect(m.failure!.crash!.signal, 11);
      expect(m.failure!.crash!.inAppFrame, 'checkout_native');
      expect(m.failure!.stack, startsWith('#0 memcpy (libc.so)'));
      expect(m.failure!.t, 1300, reason: 'crash time minus the anchor');
      expect(m.journalGapMs, 200);
      expect(m.checkpointKind, CheckpointKind.launch);
      expect(capsule.events.map((e) => e.t), [1000, 1100]);
      expect(m.labels, {
        'team': 'checkout',
        'source': 'crash_journal',
        'crash.mechanism': 'signal',
      });
      expect(m.monitoring!.eventId, '22222222-2222-4222-8222-222222222222');
      expect(m.eligibility.status, EligibilityStatus.partial);
      expect(m.eligibility.missing.map((g) => g.dependency), ['crash.native']);
      expect(m.app.version, '1.0.0');
      expect(m.session.id, 's-1');
      expect(m.runtimeName, 'flutter');
    });

    test('a full set of app labels leaves room for the crash labels', () {
      final journal = journalWith(
        (r) => r.add(1100, 'action', {'id': 'pay'}),
        header: {
          ..._header(),
          'labels': {
            for (var i = 0; i < CapsuleLimits.maxLabels; i++) 'k$i': 'v$i',
          },
        },
      );
      final build = buildCrashCapsule(
        journal,
        _request(crashedAt: DateTime.fromMillisecondsSinceEpoch(1792922391300)),
      );
      expect(build, isNotNull);
      final labels = CapsuleCodec.decode(build!.bytes).manifest.labels;
      expect(labels.length, CapsuleLimits.maxLabels);
      expect(labels['source'], 'crash_journal');
      expect(labels['crash.mechanism'], 'signal');
      expect(labels['k97'], 'v97');
      expect(labels.containsKey('k98'), isFalse);
    });

    test('uses the newest periodic checkpoint once the launch one is gone', () {
      final journal = journalWith((r) {
        for (var i = 0; i < 3; i++) {
          r.add(110 + i, 'action', {'id': 'a$i'});
        }
        r.addCheckpoint(
          r.checkpointNow(
            kind: CheckpointKind.periodic,
            t: 200,
            wallClockMs: 1792922390100,
            data: const {},
          ),
        );
        r.add(210, 'action', {'id': 'b'});
      }, maxEvents: 3);
      expect(journal.launch, isNull);
      final capsule = CapsuleCodec.decode(
        buildCrashCapsule(journal, _request())!.bytes,
      );
      expect(capsule.manifest.checkpointKind, CheckpointKind.periodic);
      expect(capsule.events.map((e) => e.seq), [4]);
      expect(capsule.manifest.failure!.t, 110, reason: 'last event time');
    });

    test('falls back to the periodic checkpoint when too big; else none', () {
      final journal = journalWith((r) {
        for (var i = 0; i < 200; i++) {
          r.add(110 + i, 'log', {'message': 'z$i' * 40});
        }
        r.addCheckpoint(
          r.checkpointNow(
            kind: CheckpointKind.periodic,
            t: 400,
            wallClockMs: 1792922390300,
            data: const {},
          ),
        );
        r.add(410, 'action', {'id': 'late'});
      });
      final launch = buildCrashCapsule(journal, _request())!;
      expect(launch.checkpointKind, CheckpointKind.launch);
      final smaller = buildCrashCapsule(
        journal,
        _request(maxCapsuleBytes: launch.bytes.length - 1),
      )!;
      expect(smaller.checkpointKind, CheckpointKind.periodic);
      expect(
        buildCrashCapsule(journal, _request(maxCapsuleBytes: 200)),
        isNull,
      );
    });

    test('carries the build and integration gaps of the crashed process', () {
      final journal = journalWith(
        (r) => r.add(150, 'action', {'id': 'a'}),
        header: _header(
          gitSha: null,
          gaps: {
            'launch': [
              {'dependency': 'storage.token', 'reason': 'redacted'},
            ],
          },
        ),
      );
      final m = CapsuleCodec.decode(
        buildCrashCapsule(journal, _request())!.bytes,
      ).manifest;
      expect(m.eligibility.missing.map((g) => g.dependency), [
        'build.gitSha',
        'storage.token',
        'crash.native',
      ]);
    });

    test(
      'preserves patch identity and required runtime without interactions',
      () {
        final identity = CapsulePatchIdentity(
          baseBuildId: 'base-release-1',
          engineAbi: 1,
          hostAbiHash: 'sha256:${'a' * 64}',
          patchSetDigest: 'sha256:${'b' * 64}',
          artifactDigest: 'sha256:${'c' * 64}',
        );
        final header = _header(dependencies: [identity.dependency.toJson()]);
        header['patch'] = identity.toJson();
        final journal = journalWith(
          (r) => r.add(150, 'action', {'id': 'crash-screen'}),
          header: header,
        );
        final manifest = CapsuleCodec.decode(
          buildCrashCapsule(journal, _request())!.bytes,
        ).manifest;
        expect(manifest.patch?.toJson(), identity.toJson());
        expect(manifest.dependencies, hasLength(1));
        expect(
          manifest.dependencies.single.toJson(),
          identity.dependency.toJson(),
        );
        expect(manifest.dependencies.single.required, isTrue);
      },
    );

    test(
      'does not erase an unsupported runtime dependency during recovery',
      () {
        final dependency = {
          'id': patchRuntimeDependencyKind,
          'kind': patchRuntimeDependencyKind,
          'adapter': 'future.patch_runtime',
          'adapterVersion': '2',
          'schema': 2,
          'required': true,
          'coverage': 'complete',
        };
        final journal = journalWith(
          (r) => r.add(150, 'action', {'id': 'a'}),
          header: _header(dependencies: [dependency]),
        );
        final manifest = CapsuleCodec.decode(
          buildCrashCapsule(journal, _request())!.bytes,
        ).manifest;
        expect(manifest.dependencies.single.adapter, 'future.patch_runtime');
        expect(manifest.dependencies.single.schema, 2);
        expect(manifest.dependencies.single.required, isTrue);
      },
    );

    test('keeps only the dependencies whose events are in the window', () {
      final dependency = {
        'id': 'ws',
        'kind': 'websocket',
        'adapter': 'bug_capsule.web_socket_channel',
        'adapterVersion': '0.5.0',
        'schema': 1,
        'required': true,
        'coverage': 'complete',
        'stats': {'events': 1},
      };
      final journal = journalWith(
        (r) => r.add(150, 'action', {'id': 'a'}),
        header: _header(dependencies: [dependency]),
      );
      final m = CapsuleCodec.decode(
        buildCrashCapsule(journal, _request())!.bytes,
      ).manifest;
      expect(m.dependencies, isEmpty);
      expect(
        m.capabilities.keys,
        isNot(contains('interaction.bug_capsule.web_socket_channel')),
      );
    });
  });

  group('crash failure from a native event', () {
    test('an ANR and an OOM get the contract types', () {
      final anr = CrashFailure.fromEvent(
        _crashEvent(type: 'ApplicationNotResponding', mechanism: 'anr'),
      );
      expect(anr.record.signature, 'crash:ApplicationNotResponding');
      expect(anr.mechanism, 'anr');
      final oom = CrashFailure.fromEvent(
        _crashEvent(type: 'Whatever', mechanism: 'oom', data: null),
      );
      expect(oom.record.signature, 'crash:OutOfMemory');
      expect(oom.record.crash!.signal, isNull);
    });

    test('a Mach exception keeps its type', () {
      final mach = CrashFailure.fromEvent(
        _crashEvent(type: 'EXC_BAD_ACCESS', mechanism: 'mach_exception'),
      );
      expect(mach.record.signature, 'crash:EXC_BAD_ACCESS');
      expect(mach.record.crash!.mechanism, 'mach_exception');
    });
  });

  group('which journal a crash claims', () {
    JournalInfo info(String id, DateTime started, DateTime lastWrite) =>
        JournalInfo(
          dir: Directory('/j/$id'),
          processId: id,
          startedAt: started,
          lastWrite: lastWrite,
        );
    final older = info(
      '100',
      DateTime.utc(2026, 10, 26, 8),
      DateTime.utc(2026, 10, 26, 8, 30),
    );
    final previous = info(
      '200',
      DateTime.utc(2026, 10, 26, 9),
      DateTime.utc(2026, 10, 26, 9, 10),
    );

    test('the journal the event names, else the previous process', () {
      expect(
        CrashJournals.forCrash(
          [older, previous],
          crashedAt: DateTime.utc(2026, 10, 26, 8, 30),
          lastRunCrashed: true,
          journalId: '100',
        ),
        same(older),
      );
      expect(
        CrashJournals.forCrash(
          [older, previous],
          crashedAt: DateTime.utc(2026, 10, 26, 9, 10, 1),
          lastRunCrashed: true,
        ),
        same(previous),
      );
    });

    test('nothing without a name or a crashed last run, or out of time', () {
      expect(
        CrashJournals.forCrash(
          [previous],
          crashedAt: DateTime.utc(2026, 10, 26, 9, 10),
          lastRunCrashed: false,
        ),
        isNull,
      );
      expect(
        CrashJournals.forCrash(
          [previous],
          crashedAt: DateTime.utc(2026, 10, 26, 11),
          lastRunCrashed: true,
        ),
        isNull,
        reason: 'long after its last write',
      );
      expect(
        CrashJournals.forCrash(
          [older],
          crashedAt: DateTime.utc(2026, 10, 26, 8, 30),
          lastRunCrashed: true,
          journalId: '999',
        ),
        isNull,
      );
    });

    test('reserve moves an earlier process with the same pid aside', () {
      final mine = CrashJournals.dirFor(root, '4242')
        ..createSync(recursive: true);
      File(
        '${mine.path}/header.json',
      ).writeAsStringSync(jsonEncode({'processId': '4242', 'pid': 4242}));
      CrashJournals.reserve(root, '4242');
      expect(mine.existsSync(), isFalse);
      final listed = CrashJournals.list(root);
      expect(listed.single.processId, '4242');
      CrashJournals.sweep(root);
      expect(CrashJournals.list(root), isEmpty);
    });
  });

  group('capsule format', () {
    Map<String, Object?> doc(int specVersion) => {
      'format': 'bugcapsule.capsule',
      'specVersion': specVersion,
      'manifest': {
        'capsuleId': 'c1',
        'createdAt': '2026-10-26T10:00:00.000Z',
        'mode': 'qa',
        'app': {'version': '1', 'build': '1'},
        'platform': {'os': 'android'},
        'session': {
          'id': 's',
          'startedAt': '2026-10-26T10:00:00.000Z',
          'wallClockAtAnchorMs': 0,
          'seed': 1,
          'durationMs': 0,
        },
        'failure': {
          'kind': 'crash',
          'signature': 'crash:SIGSEGV',
          'type': 'SIGSEGV',
          'crash': {'mechanism': 'signal', 'signal': 11},
          't': 0,
        },
        'eligibility': {'status': 'partial', 'missing': <Object>[]},
        if (specVersion >= 2) 'dependencies': <Object>[],
      },
      'checkpoint': {
        'kind': 'launch',
        't': 0,
        'wallClockMs': 0,
        'afterSeq': 0,
        'data': <String, Object?>{},
      },
      'events': <Object>[],
    };

    test('failure kind crash is valid in v2 only', () {
      expect(validateCapsuleDocument(doc(2)), isNull);
      expect(validateCapsuleDocument(doc(1)), contains('failure.kind'));
      final capsule = CapsuleCodec.fromJson(doc(2));
      expect(capsule.specVersion, 2, reason: 'crash capsules are always v2');
      expect(capsule.manifest.failure!.crash!.signal, 11);
    });
  });
}
