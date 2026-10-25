import 'package:bug_capsule/src/cli/backend_client.dart';
import 'package:test/test.dart';

void main() {
  group('Credentials', () {
    test(
      'a personal or service token is preferred over a legacy secret key',
      () {
        const both = Credentials(
          url: 'http://b',
          secretKey: 'bcs_legacy',
          token: 'bcp_mine',
        );
        expect(both.projectCredential, 'bcp_mine');
        const legacy = Credentials(url: 'http://b', secretKey: 'bcs_legacy');
        expect(legacy.projectCredential, 'bcs_legacy');
        const none = Credentials(url: 'http://b', ingestKey: 'bci_x');
        expect(none.projectCredential, isNull);
      },
    );

    test(
      'round-trips through config.json, and files from 0.4.0 still load',
      () {
        const c = Credentials(
          url: 'http://b',
          token: 'bcv_ci',
          ingestKey: 'bci_x',
        );
        final back = Credentials.fromJson(c.toJson());
        expect(back.token, 'bcv_ci');
        expect(back.secretKey, isNull);
        expect(c.toJson().containsKey('secretKey'), isFalse);
        final old = Credentials.fromJson({
          'url': 'http://b',
          'secretKey': 'bcs_old',
          'ingestKey': null,
        });
        expect(old.projectCredential, 'bcs_old');
      },
    );

    test('recognises tokens by prefix', () {
      expect(Credentials.isToken('bcp_abc'), isTrue);
      expect(Credentials.isToken('bcv_abc'), isTrue);
      expect(Credentials.isToken('bcs_abc'), isFalse);
      expect(Credentials.isToken('bci_abc'), isFalse);
    });
  });

  test('refused credentials explain how to get a new token', () {
    expect(
      ApiException(
        401,
        'unauthorized',
        'invalid, expired or revoked token',
      ).toString(),
      contains('bugcapsule login --url <backend> --token <token>'),
    );
    expect(
      ApiException(
        403,
        'forbidden',
        'this action needs the replay.submit permission in this project',
      ).toString(),
      contains('ask a project admin'),
    );
  });
}
