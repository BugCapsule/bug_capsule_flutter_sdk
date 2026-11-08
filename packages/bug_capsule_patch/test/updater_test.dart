import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:bug_capsule_patch/src/native.dart' show NativeError;
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

/// Returns [next], or throws [error] like the HTTP transport on a 503.
final class Throwing503 implements PatchTransport {
  Throwing503(this.bundle);
  final Uint8List bundle;
  SignedChannel? next;
  PatchHttpException? error;
  int downloads = 0;
  final etags = <String?>[];

  @override
  Future<SignedChannel?> fetchChannel({String? etag}) async {
    etags.add(etag);
    if (error != null) throw error!;
    return next;
  }

  @override
  Future<Uint8List> fetchArtifact(String digest) async {
    downloads++;
    return bundle;
  }

  @override
  Future<void> postReceipts(Map<String, Object?> batch) async {}
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

  group('503 channel_invalidated with a keyring (P0-3)', () {
    final rings = jsonDecode(File('test/fixtures/keyrings.json').readAsStringSync()) as Map<String, Object?>;
    Map<String, Object?> ring(String name) => (rings['keyrings']! as List<Object?>).cast<Map<String, Object?>>().firstWhere((e) => e['name'] == name);
    PatchHttpException invalidated(String? name) => PatchHttpException(
      'channel_invalidated',
      503,
      const Duration(seconds: 30),
      name == null ? null : base64Decode(ring(name)['document']! as String),
      name == null ? null : base64Decode(ring(name)['signature']! as String),
    );
    final signer = rings['signerChannel']! as Map<String, Object?>;
    final signerChannel = SignedChannel(base64Decode(signer['document']! as String), base64Decode(signer['signature']! as String), etag: 'signer');

    test('applies only a root-verified keyring, never stages, and the revocation survives a restart', () async {
      final dir = Directory.systemTemp.createTempSync('bcu503').path;
      var patch = open(dir);
      final net = Throwing503(bundle('valid'));
      final updater = PatchUpdater(patch, net);
      // authorize arrives in a normal 200 with the signer's channel.
      net.next = SignedChannel(signerChannel.document, signerChannel.signature, etag: 'a',
          keyringDocument: base64Decode(ring('authorize')['document']! as String), keyringSignature: base64Decode(ring('authorize')['signature']! as String));
      expect((await updater.checkForUpdate()).state, PatchUpdateState.restartRequired);
      final staged = patch.status()['pending'];
      for (final (name, code) in [('forged', 'bad_signature'), ('other project', 'wrong_target')]) {
        net.error = invalidated(name);
        final r = await updater.checkForUpdate();
        expect(r.state, PatchUpdateState.failed);
        expect(r.reason, 'channel_invalidated; keyring_rejected:$code', reason: name);
        expect(r.retryAfter, const Duration(seconds: 30));
      }
      net.error = invalidated('revoke');
      final r = await updater.checkForUpdate();
      expect([r.state, r.reason], [PatchUpdateState.failed, 'channel_invalidated']);
      expect(net.downloads, 1, reason: 'a 503 never downloads');
      expect(patch.status()['pending'], staged, reason: 'a 503 never changes what is staged');
      net.error = invalidated('stale');
      expect((await updater.checkForUpdate()).reason, 'channel_invalidated; keyring_rejected:stale');
      net.error = invalidated(null);
      expect((await updater.checkForUpdate()).reason, 'channel_invalidated');
      patch.close();

      patch = open(dir);
      // The revoked signer is refused after restart; a stale keyring still is too.
      expect(() => patch.applyChannel(signerChannel.document, signerChannel.signature), throwsA(isA<NativeError>().having((e) => e.code, 'code', anyOf('untrusted_key', 'stale'))));
      expect(() => patch.applyKeyring(base64Decode(ring('stale')['document']! as String), base64Decode(ring('stale')['signature']! as String)),
          throwsA(isA<NativeError>().having((e) => e.code, 'code', 'stale')));
      patch.close();
      final fresh = Directory.systemTemp.createTempSync('bcu503b').path;
      patch = open(fresh);
      final u2 = PatchUpdater(patch, Throwing503(bundle('valid'))..error = invalidated('authorize'));
      expect((await u2.checkForUpdate()).reason, 'channel_invalidated');
      (u2.transport as Throwing503).error = invalidated('revoke');
      expect((await u2.checkForUpdate()).reason, 'channel_invalidated');
      patch.close();
      patch = open(fresh);
      expect(() => patch.applyChannel(signerChannel.document, signerChannel.signature), throwsA(isA<NativeError>().having((e) => e.code, 'code', 'untrusted_key').having((e) => e.message, 'message', contains('revoked'))));
      patch.close();
    }, skip: skip);

    test('the runtime carries E1: status reports degraded', () {
      final patch = open(Directory.systemTemp.createTempSync('bcu-e1').path);
      expect(patch.status()['degraded'], isFalse);
      patch.close();
    }, skip: skip);

    test('the next check after a 503 retries the channel (the ETag is not advanced)', () async {
      final patch = open(Directory.systemTemp.createTempSync('bcu503c').path);
      final net = Throwing503(bundle('valid'))..error = invalidated(null);
      final updater = PatchUpdater(patch, net);
      expect((await updater.checkForUpdate()).state, PatchUpdateState.failed);
      net.error = null;
      net.next = channel('valid');
      expect((await updater.checkForUpdate()).state, PatchUpdateState.restartRequired);
      expect(net.etags, [null, null], reason: 'no ETag recorded from a 503');
      patch.close();
    }, skip: skip);
  });

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
