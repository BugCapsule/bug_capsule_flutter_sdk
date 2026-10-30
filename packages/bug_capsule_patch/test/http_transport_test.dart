import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bug_capsule_patch/bug_capsule_patch.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real loopback HTTP server, so sockets, headers and limits are exercised.
final digest = 'sha256:${'a' * 64}';

void main() {
  late HttpServer server;
  late HttpPatchTransport t;
  late void Function(HttpRequest) handle;
  final seen = <HttpRequest>[];
  final bodies = <String>[];

  setUp(() async {
    seen.clear();
    bodies.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      seen.add(r);
      bodies.add(await utf8.decodeStream(r));
      handle(r);
    });
    t = HttpPatchTransport(
      baseUrl: 'http://127.0.0.1:${server.port}',
      deliveryToken: 'bcpd_secret',
      applicationId: 'com.shop',
      platform: 'flutter_android',
      distributionProfile: 'internal',
      baseBuildId: 'build-1',
      installationId: 'install-1',
      timeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    t.close();
    await server.close(force: true);
  });

  void reply(int status, [List<int> body = const [], Map<String, String> headers = const {}]) {
    handle = (r) {
      r.response.statusCode = status;
      headers.forEach(r.response.headers.set);
      r.response.add(body);
      r.response.close();
    };
  }

  List<int> channelBody({bool keyring = false}) => utf8.encode(jsonEncode({
    'channel': {'document': base64Encode([1, 2]), 'signature': base64Encode([3])},
    'keyring': keyring ? {'version': 2, 'document': base64Encode([4]), 'signature': base64Encode([5])} : null,
  }));

  test('fetches the channel with scope, token and exact bytes', () async {
    reply(200, channelBody(keyring: true), {'etag': '"abc"'});
    final c = (await t.fetchChannel())!;
    expect(c.document, [1, 2]);
    expect(c.signature, [3]);
    expect(c.keyringDocument, [4]);
    expect(c.keyringSignature, [5]);
    expect(c.etag, '"abc"');
    final r = seen.single;
    expect(r.uri.path, '/v1/apps/com.shop/patches/channel');
    expect(r.uri.queryParameters, {'platform': 'flutter_android', 'distributionProfile': 'internal', 'baseBuildId': 'build-1'});
    expect(r.headers.value('authorization'), 'Bearer bcpd_secret');
  });

  test('304 and 204 mean nothing to do; the ETag is sent', () async {
    reply(304);
    expect(await t.fetchChannel(etag: '"abc"'), isNull);
    expect(seen.single.headers.value('if-none-match'), '"abc"');
    reply(204);
    expect(await t.fetchChannel(), isNull);
  });

  test('an oversized channel is refused while reading', () async {
    reply(200, Uint8List(HttpPatchTransport.maxChannelBytes + 1));
    await expectLater(t.fetchChannel(), throwsA(isA<PatchHttpException>().having((e) => e.reason, 'reason', 'response_too_large')));
  });

  test('an undeclared oversized artifact stops at the limit', () async {
    handle = (r) async {
      r.response.bufferOutput = false;
      final chunk = Uint8List(1 << 20);
      try {
        for (var i = 0; i < 12; i++) {
          r.response.add(chunk);
          await r.response.flush();
        }
        await r.response.close();
      } on Object catch (_) {}
    };
    await expectLater(t.fetchArtifact(digest), throwsA(isA<PatchHttpException>().having((e) => e.reason, 'reason', 'response_too_large')));
  });

  test('a declared oversized artifact is refused before reading it', () async {
    handle = (r) {
      r.response.headers.contentLength = HttpPatchTransport.maxArtifactBytes + 1;
      r.response.add(Uint8List(16));
      r.response.close().catchError((Object _) {});
    };
    await expectLater(t.fetchArtifact(digest), throwsA(isA<PatchHttpException>().having((e) => e.reason, 'reason', 'response_too_large')));
  });

  test('a redirect is not followed, so the token stays here', () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var leaked = false;
    other.listen((r) {
      leaked = true;
      r.response.close();
    });
    reply(302, const [], {'location': 'http://127.0.0.1:${other.port}/steal'});
    await expectLater(t.fetchArtifact(digest), throwsA(isA<PatchHttpException>().having((e) => e.reason, 'reason', 'redirect_refused')));
    expect(leaked, isFalse);
    await other.close(force: true);
  });

  test('errors are typed', () async {
    for (final (status, reason) in [(401, 'unauthorized'), (404, 'not_found'), (410, 'gone'), (429, 'rate_limited'), (500, 'http_error')]) {
      reply(status);
      await expectLater(t.fetchArtifact(digest), throwsA(isA<PatchHttpException>().having((e) => e.reason, 'reason', reason)));
    }
  });

  test('malformed channel JSON fails, never reaching the runtime', () async {
    reply(200, utf8.encode('{"channel":'));
    await expectLater(t.fetchChannel(), throwsA(isA<FormatException>()));
  });

  test('digest colons survive in the artifact path', () async {
    reply(200, [9, 9]);
    expect(await t.fetchArtifact(digest), [9, 9]);
    expect(seen.single.uri.path, '/v1/apps/com.shop/patches/artifacts/$digest');
    await expectLater(t.fetchArtifact('../secrets'), throwsA(isA<PatchHttpException>().having((e) => e.reason, 'reason', 'bad_digest')));
  });

  test('receipts map to the API, dropping events it does not record', () async {
    reply(202, utf8.encode('{}'));
    await t.postReceipts({
      'receipts': [
        {'seq': 1, 'event': 'staged', 'digest': 'sha256:a', 'reason': null, 'at': 5},
        {'seq': 2, 'event': 'something_new', 'digest': null, 'reason': null, 'at': 6},
      ],
      'status': {'activeDigest': null, 'pending': 'sha256:a', 'channelRevision': 4},
    });
    final b = jsonDecode(bodies.single) as Map<String, Object?>;
    expect(b['installationId'], 'install-1');
    expect(b['stagedDigest'], 'sha256:a');
    expect(b['channelRevision'], 4);
    expect((b['receipts']! as List).map((r) => (r as Map)['event']), ['staged']);
  });

  test('a refused receipt upload throws, so nothing is acknowledged', () async {
    reply(503);
    await expectLater(t.postReceipts({'receipts': <Object?>[], 'status': <String, Object?>{}}), throwsA(isA<PatchHttpException>()));
  });

  test('plain http is refused outside loopback', () {
    expect(
      () => HttpPatchTransport(baseUrl: 'http://example.com', deliveryToken: 'x', applicationId: 'a', platform: 'p', distributionProfile: 'd', baseBuildId: 'b', installationId: 'i'),
      throwsArgumentError,
    );
  });
}
