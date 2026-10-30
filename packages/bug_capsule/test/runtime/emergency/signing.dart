import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bug_capsule/src/runtime/emergency/crypto.dart';
import 'package:pointycastle/api.dart' show PrivateKeyParameter;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

/// A throwaway ES256 signer for tests: generates a key, builds the trust
/// anchor for it and signs policy documents the way the backend does.
class TestSigner {
  TestSigner._(this._d, this.spki, this.kid);

  static final _domain = ECCurve_secp256r1();
  static const appId = '7c9e6679-7425-40de-944b-e07fc1f90ae7';

  factory TestSigner.generate({String kid = 'ek_test01'}) {
    final rnd = Random.secure();
    BigInt d;
    do {
      var v = BigInt.zero;
      for (var i = 0; i < 32; i++) {
        v = (v << 8) | BigInt.from(rnd.nextInt(256));
      }
      d = v;
    } while (d == BigInt.zero || d >= _domain.n);
    final q = (_domain.G * d)!;
    return TestSigner._(
      d,
      Uint8List.fromList([...p256SpkiPrefix, ...q.getEncoded(false)]),
      kid,
    );
  }

  final BigInt _d;
  final Uint8List spki;
  final String kid;

  /// An anchor trusting this key (and [others]) for [app].
  String anchor({String app = appId, List<TestSigner> others = const []}) {
    final body = {
      'app': app,
      'keys': [
        for (final s in [this, ...others])
          {'kid': s.kid, 'alg': 'ES256', 'spki': encodeBase64Url(s.spki)},
      ],
    };
    return 'bcek.v1.${encodeBase64Url(utf8.encode(jsonEncode(body)))}';
  }

  Map<String, Object?> policy({
    String key = 'checkout.confirm_order',
    String action = 'BLOCK',
    String id = 'p-1',
    int priority = 0,
    int rolloutBp = 10000,
    String reason = 'PRICING_SAFETY',
    String? expiresAt,
    String? fallback,
  }) => {
    'policy_id': id,
    'key': key,
    'revision': 1,
    'action': action,
    'priority': priority,
    'severity': 'P0',
    'incident_id': 'inc_1',
    'target_platforms': <String>[],
    'version_ranges': <Object?>[],
    'rollout_bp': rolloutBp,
    'rollout_seed': 'seed-$key',
    'reason_code': reason,
    'public_user_message': 'Temporarily unavailable.',
    'required_version': null,
    'fallback': fallback,
    'expires_at': expiresAt,
  };

  Map<String, Object?> document({
    int revision = 1,
    DateTime? issuedAt,
    DateTime? expiresAt,
    List<Map<String, Object?>>? policies,
    String app = appId,
    String environment = 'production',
  }) {
    final issued = issuedAt ?? DateTime.utc(2026, 10, 29, 8);
    return {
      'type': 'bugcapsule.emergency.policy-document',
      'schema_version': 1,
      'application_id': app,
      'environment': environment,
      'revision': revision,
      'issued_at': issued.toUtc().toIso8601String(),
      'expires_at': (expiresAt ?? issued.add(const Duration(hours: 1)))
          .toUtc()
          .toIso8601String(),
      'policies': policies ?? [policy()],
    };
  }

  Map<String, Object?> envelope(Map<String, Object?> document) =>
      envelopeOfBytes(utf8.encode(jsonEncode(document)));

  Map<String, Object?> envelopeOfBytes(List<int> payload) => {
    'format': 'bugcapsule.emergency.v1',
    'alg': 'ES256',
    'kid': kid,
    'payload': encodeBase64Url(payload),
    'signature': encodeBase64Url(_sign(Uint8List.fromList(payload))),
  };

  List<int> _sign(Uint8List message) {
    final signer = ECDSASigner(
      SHA256Digest(),
      HMac(SHA256Digest(), 64),
    )..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(_d, _domain)));
    final sig = signer.generateSignature(message) as ECSignature;
    List<int> integer(BigInt v) {
      var bytes = <int>[];
      var x = v;
      while (x > BigInt.zero) {
        bytes.insert(0, (x & BigInt.from(0xff)).toInt());
        x >>= 8;
      }
      if (bytes.isEmpty) bytes = [0];
      if (bytes[0] & 0x80 != 0) bytes.insert(0, 0);
      return [0x02, bytes.length, ...bytes];
    }

    final body = [...integer(sig.r), ...integer(sig.s)];
    return [0x30, body.length, ...body];
  }
}
