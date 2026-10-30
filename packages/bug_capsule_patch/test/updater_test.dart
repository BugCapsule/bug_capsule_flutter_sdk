import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter_test/flutter_test.dart';

/// Uses the shared vectors through the real runtime, with a fake network.
final class FakeTransport implements PatchTransport {
  FakeTransport(this.channel, this.bundle);

  SignedChannel? channel;
  Uint8List bundle;
  int downloads = 0;
  bool offline = false;
  final posted = <Map<String, Object?>>[];

  @override
  Future<SignedChannel?> fetchChannel({String? etag}) async {
    if (offline) throw const SocketException('offline');
    return etag != null && etag == channel?.etag ? null : channel;
  }

  @override
  Future<Uint8List> fetchArtifact(String digest) async {
    downloads++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return bundle;
  }

  @override
  Future<void> postReceipts(Map<String, Object?> batch) async {
    if (offline) throw const SocketException('offline');
    posted.add(batch);
  }
}

void main() {
  final path = Platform.environment['BCPATCH_HOST_LIB'];
  final skip = path == null ? 'set BCPATCH_HOST_LIB' : null;
  final wire = jsonDecode(File('test/fixtures/wire.json').readAsStringSync()) as Map<String, Object?>;
  final t = wire['target']! as Map<String, Object?>;
  final m = (t['modules']! as List<Object?>).first! as Map<String, Object?>;

  Map<String, Object?> named(String list, String name) => (wire[list]! as List<Object?>).cast<Map<String, Object?>>().firstWhere((e) => e['name'] == name);

  BugCapsulePatch open(String dir) => BugCapsulePatch.open(
    PatchConfig(
      storeDir: dir,
      projectId: t['projectId']! as String,
      applicationId: t['applicationId']! as String,
      environment: t['environment']! as String,
      platform: t['platform']! as String,
      distributionProfile: t['distributionProfile']! as String,
      baseBuildId: t['baseBuildId']! as String,
      installationId: 'i',
      trustRoots: [wire['trustRoot']! as String],
    ),
    modules: [
      PatchModule<int, int>(id: m['id']! as String, inputSchema: m['input']! as String, outputSchema: m['output']! as String, encode: (i) => i, decode: (o) => o! as int, fallback: (i) => i),
    ],
    libraryPath: path,
  );

  SignedChannel channel(String name) {
    final c = named('channels', name);
    return SignedChannel(base64Decode(c['document']! as String), base64Decode(c['signature']! as String), etag: name);
  }

  Uint8List bundle(String name) => base64Decode(named('artifacts', name)['bundle']! as String);

  test('downloads, stages, and leaves the running generation alone', () async {
    final dir = Directory.systemTemp.createTempSync('bcu').path;
    final patch = open(dir);
    final net = FakeTransport(channel('valid'), bundle('valid'));
    final updater = PatchUpdater(patch, net);
    final r = await updater.checkForUpdate();
    expect(r.state, PatchUpdateState.restartRequired);
    expect(r.artifactDigest, wire['artifactDigest']);
    expect(patch.status()['state'], 'BASE');
    patch.close();

    final next = open(dir);
    expect(next.status()['state'], 'PROBATION');
    next.close();
  }, skip: skip);

  test('concurrent checks join one download', () async {
    final patch = open(Directory.systemTemp.createTempSync('bcu').path);
    final net = FakeTransport(channel('valid'), bundle('valid'));
    final updater = PatchUpdater(patch, net);
    await Future.wait([updater.checkForUpdate(), updater.checkForUpdate(), updater.checkForUpdate()]);
    expect(net.downloads, 1);
    patch.close();
  }, skip: skip);

  test('a corrupted download leaves the next launch unchanged', () async {
    final dir = Directory.systemTemp.createTempSync('bcu').path;
    final patch = open(dir);
    final net = FakeTransport(channel('valid'), bundle('payload bit flip'));
    final r = await PatchUpdater(patch, net).checkForUpdate();
    expect(r.state, PatchUpdateState.failed);
    expect(r.reason, 'verify_failed');
    patch.close();
    final next = open(dir);
    expect(next.status()['state'], 'BASE');
    next.close();
  }, skip: skip);

  test('a failed download is retried even though the channel did not change', () async {
    final patch = open(Directory.systemTemp.createTempSync('bcu').path);
    final net = FakeTransport(channel('valid'), bundle('payload bit flip'));
    final updater = PatchUpdater(patch, net);
    expect((await updater.checkForUpdate()).state, PatchUpdateState.failed);
    net.bundle = bundle('valid');
    expect((await updater.checkForUpdate()).state, PatchUpdateState.restartRequired);
    expect(net.downloads, 2);
    patch.close();
  }, skip: skip);

  test('network failure is a result, and the next check retries', () async {
    final patch = open(Directory.systemTemp.createTempSync('bcu').path);
    final net = FakeTransport(channel('valid'), bundle('valid'))..offline = true;
    final updater = PatchUpdater(patch, net);
    expect((await updater.checkForUpdate()).state, PatchUpdateState.failed);
    net.offline = false;
    expect((await updater.checkForUpdate()).state, PatchUpdateState.restartRequired);
    patch.close();
  }, skip: skip);

  test('forged channel metadata is refused', () async {
    final patch = open(Directory.systemTemp.createTempSync('bcu').path);
    final r = await PatchUpdater(patch, FakeTransport(channel('bad signer'), bundle('valid'))).checkForUpdate();
    expect(r.reason, 'bad_signature');
    patch.close();
  }, skip: skip);

  test('an unchanged ETag downloads nothing', () async {
    final patch = open(Directory.systemTemp.createTempSync('bcu').path);
    final net = FakeTransport(channel('valid'), bundle('valid'));
    final updater = PatchUpdater(patch, net);
    await updater.checkForUpdate();
    expect((await updater.checkForUpdate()).state, PatchUpdateState.upToDate);
    expect(net.downloads, 1);
    patch.close();
  }, skip: skip);

  test('receipts are only acknowledged once uploaded', () async {
    final patch = open(Directory.systemTemp.createTempSync('bcu').path);
    final net = FakeTransport(channel('valid'), bundle('valid'));
    final updater = PatchUpdater(patch, net);
    await updater.checkForUpdate();
    net.offline = true;
    await expectLater(updater.flushReceipts(), throwsA(isA<SocketException>()));
    expect((patch.receipts()['receipts']! as List<Object?>), isNotEmpty);
    net.offline = false;
    expect(await updater.flushReceipts(), greaterThan(0));
    expect((patch.receipts()['receipts']! as List<Object?>), isEmpty);
    expect(net.posted, hasLength(1));
    patch.close();
  }, skip: skip);
}
