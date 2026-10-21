import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/src/core/core.dart';
import 'package:bug_capsule/src/runtime/backend.dart';
import 'package:bug_capsule/src/runtime/config.dart';
import 'package:bug_capsule/src/runtime/remote_config.dart';
import 'package:test/test.dart';

/// Plain `package:test` (no Flutter binding), so real sockets work.
void main() {
  group('POST /v1/envelope', () {
    late HttpServer server;
    late List<(HttpHeaders, String, List<int>)> requests;
    var status = 200;
    var reply = '{"accepted":1,"rejected":[]}';
    Map<String, String> replyHeaders = {};

    setUp(() async {
      requests = [];
      status = 200;
      reply = '{"accepted":1,"rejected":[]}';
      replyHeaders = {};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        requests.add((req.headers, req.uri.path, body));
        req.response.statusCode = status;
        replyHeaders.forEach(req.response.headers.set);
        req.response.write(reply);
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    BugCapsuleBackendClient client() => BugCapsuleBackendClient(
        BugCapsuleBackendConfig(url: 'http://127.0.0.1:${server.port}/', ingestKey: 'bci_test'));

    final envelope = EnvelopeCodec.encode([const EnvelopeItem('event', {'eventId': 'e'})], sdkVersion: 't');

    test('sends gzip JSON with the ingest key', () async {
      final r = await client().sendEnvelope(envelope);
      expect(r.status, UploadStatus.uploaded);
      final (headers, path, body) = requests.single;
      expect(path, '/v1/envelope');
      expect(headers.value('authorization'), 'Bearer bci_test');
      expect(headers.value('content-encoding'), 'gzip');
      expect(headers.contentType?.mimeType, 'application/json');
      expect(jsonDecode(utf8.decode(gzip.decode(body))), containsPair('items', isNotEmpty));
    });

    test('rejected items are not retried', () async {
      reply = '{"accepted":0,"rejected":[{"index":0,"reason":"bad"}]}';
      expect((await client().sendEnvelope(envelope)).status, UploadStatus.uploaded);
    });

    test('429 and 503 retry later with Retry-After; 400 and capture_disabled are dropped', () async {
      status = 429;
      replyHeaders = {'retry-after': '7'};
      reply = '{"code":"rate_limited"}';
      final limited = await client().sendEnvelope(envelope);
      expect(limited.status, UploadStatus.retryLater);
      expect(limited.retryAfter, const Duration(seconds: 7));

      status = 503;
      expect((await client().sendEnvelope(envelope)).status, UploadStatus.retryLater);

      status = 400;
      replyHeaders = {};
      reply = '{"code":"invalid_envelope"}';
      expect((await client().sendEnvelope(envelope)).status, UploadStatus.rejected);

      status = 403;
      reply = '{"code":"capture_disabled"}';
      final disabled = await client().sendEnvelope(envelope);
      expect(disabled.status, UploadStatus.rejected);
      expect(disabled.message, 'capture_disabled');
    });
  });

  test('the envelope outbox is a separate queue with its own file extension', () async {
    final dir = await Directory.systemTemp.createTemp('bugcapsule-envelopes-');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/1_capsule.bugcapsule').writeAsBytesSync(gzip.encode([1]));
    var clock = DateTime.now();
    final outbox = await UploadOutbox.open(dir,
        limits: const OutboxLimits(maxCount: 2, maxBytes: 5 * 1024 * 1024),
        extension: '.envelope',
        now: () => clock = clock.add(const Duration(milliseconds: 1)));
    for (var i = 0; i < 3; i++) {
      expect(await outbox.enqueue('env-$i', gzip.encode([i])), isTrue);
    }
    final entries = await outbox.entries();
    expect([for (final e in entries) e.capsuleId], ['env-1', 'env-2'], reason: 'oldest evicted beyond maxCount');
    final sent = <List<int>>[];
    await outbox.flush(
        upload: (b) async {
          sent.add(gzip.decode(b));
          return const UploadResult(UploadStatus.uploaded);
        },
        allowed: () => true);
    expect(sent, [
      [1],
      [2],
    ]);
    expect(File('${dir.path}/1_capsule.bugcapsule').existsSync(), isTrue, reason: 'capsule files are not touched');
  });

  test('remote config: monitoring fields, defaults and cache round trip', () {
    final defaults = RemoteCaptureConfig.fromJson(const {});
    expect(defaults.monitoringEnabled, isTrue);
    expect(defaults.errorSampleRate, 1.0);
    expect(defaults.tracesSampleRate, isNull, reason: 'absent: the app rate applies');
    expect(defaults.sessionTracking, isTrue);
    expect(defaults.maxBreadcrumbs, 100);
    expect(defaults.tracePropagationTargets, isNull);

    final c = RemoteCaptureConfig.fromJson(const {
      'monitoringEnabled': false,
      'errorSampleRate': 0.25,
      'tracesSampleRate': 2,
      'sessionTracking': false,
      'maxBreadcrumbs': 500,
      'tracePropagationTargets': ['api.shop.com'],
      'storeIpAddresses': true,
      'apdexThresholdMs': 300,
    });
    expect(c.monitoringEnabled, isFalse);
    expect(c.errorSampleRate, 0.25);
    expect(c.tracesSampleRate, 1.0, reason: 'clamped');
    expect(c.sessionTracking, isFalse);
    expect(c.maxBreadcrumbs, 100, reason: 'clamped');
    expect(c.tracePropagationTargets, ['api.shop.com']);
    final again = RemoteCaptureConfig.fromJson(c.toJson());
    expect(again.toJson(), c.toJson());
    expect(() => RemoteCaptureConfig.fromJson(const {'monitoringEnabled': 'yes'}), throwsFormatException);
  });
}
