import 'package:flutter_test/flutter_test.dart';
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/connection_token.dart'
    show explicitBackendRefusal;
import 'package:bug_capsule/src/runtime/remote_config.dart';

/// Server settings can only narrow what the app configured (BC-ENT-018), and
/// the ingest key never travels over plain http to a remote host.
void main() {
  group('remote maxCapsuleBytes', () {
    test('is clamped to the backend maximum', () {
      final huge = RemoteCaptureConfig.fromJson({'maxCapsuleBytes': 1 << 62});
      expect(huge.maxCapsuleBytes, maxRemoteCapsuleBytes);
      expect(
        RemoteCaptureConfig.fromJson({'maxCapsuleBytes': -5}).maxCapsuleBytes,
        1,
      );
      expect(
        RemoteCaptureConfig.fromJson({'maxCapsuleBytes': 2048}).maxCapsuleBytes,
        2048,
      );
    });
  });

  group('trace propagation targets', () {
    test('a server list can remove destinations but not add them', () {
      final t = PropagationTargets(
        ['api.shop.test'],
        narrowedBy: ['api.shop.test/cart', 'evil.test'],
      );
      expect(t.matches('https://api.shop.test/cart/1'), isTrue);
      expect(
        t.matches('https://api.shop.test/profile'),
        isFalse,
        reason: 'narrowed away',
      );
      expect(
        t.matches('https://evil.test/x'),
        isFalse,
        reason: 'the app never listed it',
      );
    });

    test('server entries are plain text, never patterns', () {
      final t = PropagationTargets(['api.shop.test'], narrowedBy: [r'/.*/']);
      expect(t.matches('https://api.shop.test/cart'), isFalse);
    });

    test('without a server list the app list applies as before', () {
      final t = PropagationTargets([r'/^https:\/\/api\./']);
      expect(t.matches('https://api.shop.test/cart'), isTrue);
      expect(t.matches('https://cdn.shop.test/a.png'), isFalse);
    });
  });

  group('explicit backend config', () {
    String? refusal(
      String url, [
      String key = 'bct_abcdefghijklmnopqrstuvwx',
    ]) => explicitBackendRefusal(
      BugCapsuleBackendConfig(url: url, ingestKey: key),
    );

    test('accepts https and local development hosts', () {
      expect(refusal('https://bugs.example.com'), isNull);
      expect(refusal('http://127.0.0.1:8787'), isNull);
      expect(refusal('http://localhost:8787'), isNull);
      expect(refusal('http://10.0.2.2:8787'), isNull);
    });

    test('refuses plain http to a remote or LAN host', () {
      expect(refusal('http://bugs.example.com'), contains('https'));
      expect(refusal('http://192.168.1.20:8787'), contains('https'));
    });

    test('refuses a secret key', () {
      expect(
        refusal('https://bugs.example.com', 'bcs_abcdefghijklmnopqrstuvwx'),
        contains('secret'),
      );
    });
  });
}
