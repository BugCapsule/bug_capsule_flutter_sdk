import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bug_capsule/src/runtime/emergency/contract.dart';
import 'package:bug_capsule/src/runtime/emergency/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'signing.dart';

/// The shared vectors of spec/emergency-client-v1.md §9: every case of every
/// file, plus the verification and parsing edges they do not pin down.

const _root = '../../spec/fixtures/emergency-v1';

Map<String, Object?> _load(String name) =>
    (jsonDecode(File('$_root/$name').readAsStringSync()) as Map)
        .cast<String, Object?>();

List<Map<String, Object?>> _cases(Map<String, Object?> file, String key) => [
  for (final c in file[key]! as List<Object?>)
    (c! as Map).cast<String, Object?>(),
];

void main() {
  group('versions.json', () {
    final file = _load('versions.json');

    test('compare', () {
      final cases = _cases(file, 'compare');
      expect(cases, isNotEmpty);
      for (final c in cases) {
        final a = c['a']! as String;
        final b = c['b']! as String;
        expect(compareEmergencyVersions(a, b), c['result'], reason: '$a vs $b');
        // Antisymmetric.
        final reverse = c['result']! as int;
        expect(compareEmergencyVersions(b, a), -reverse, reason: '$b vs $a');
      }
    });

    test('invalid', () {
      final cases = _cases(file, 'invalid');
      expect(cases, isNotEmpty);
      for (final c in cases) {
        final v = c['version']! as String;
        expect(parseEmergencyVersion(v), isNull, reason: '"$v"');
        expect(compareEmergencyVersions(v, '1.0.0'), c['result'], reason: v);
      }
    });

    test('targeted', () {
      final cases = _cases(file, 'targeted');
      expect(cases, isNotEmpty);
      for (final c in cases) {
        final ranges = [
          for (final r
              in (c['ranges']! as List<Object?>).cast<Map<Object?, Object?>>())
            EmergencyVersionRange(
              min: r['min'] as String?,
              max: r['max'] as String?,
            ),
        ];
        expect(
          emergencyVersionTargeted(c['version'] as String?, ranges),
          c['expected'],
          reason: '${c['version']} in ${c['ranges']}',
        );
      }
    });
  });

  test('rollout.json buckets', () {
    final cases = _cases(_load('rollout.json'), 'cases');
    expect(cases, isNotEmpty);
    for (final c in cases) {
      expect(
        emergencyRolloutBucket(c['seed']! as String, c['subject']! as String),
        c['bucket'],
        reason: '${c['seed']}:${c['subject']}',
      );
    }
  });

  test('evaluation.json decisions', () {
    final file = _load('evaluation.json');
    final docs = (file['documents']! as Map).cast<String, Object?>();
    final cases = _cases(file, 'cases');
    expect(cases, isNotEmpty);
    for (final c in cases) {
      final doc = (docs[c['document']]! as Map).cast<String, Object?>();
      final ctx = (c['context']! as Map).cast<String, Object?>();
      final decision = evaluateEmergencyPolicies(
        policies: [
          for (final p in doc['policies']! as List<Object?>)
            EmergencyPolicy.fromJson(p),
        ],
        documentRevision: doc['revision']! as int,
        featureKey: c['feature_key']! as String,
        platform: ctx['platform']! as String,
        appVersion: ctx['app_version'] as String?,
        subject: ctx['subject'] as String?,
        now: DateTime.parse(ctx['now']! as String),
      );
      expect(
        decision.toJson()..remove('source'),
        c['expected'],
        reason: '${c['document']} / ${c['feature_key']} / $ctx',
      );
      expect(decision.source, EmergencyDecisionSource.policy);
    }
  });

  group('envelopes.json', () {
    final file = _load('envelopes.json');
    final anchor = EmergencyTrustAnchor.parse(file['anchor']! as String);
    final rotated = EmergencyTrustAnchor.parse(
      file['anchor_rotated']! as String,
    );
    final env = file['environment']! as String;
    final cases = _cases(file, 'cases');

    test('anchors name the application', () {
      expect(anchor.applicationId, file['application_id']);
      expect(rotated.applicationId, file['application_id']);
      expect(rotated.keyIds, hasLength(2));
    });

    String outcome(EnvelopeVerification v) => switch (v) {
      EnvelopeVerified() => 'ok',
      EnvelopeRejected(:final reason) => reason.wire,
    };

    test('every case with anchor', () {
      expect(cases, isNotEmpty);
      for (final c in cases) {
        final v = verifyEmergencyEnvelope(c['envelope'], anchor, env);
        expect(outcome(v), c['expected'], reason: c['name'] as String);
        if (v is EnvelopeVerified && c['revision'] != null) {
          expect(v.document.revision, c['revision']);
        }
      }
    });

    test('every case with anchor_rotated', () {
      for (final c in cases) {
        final name = c['name']! as String;
        final v = verifyEmergencyEnvelope(c['envelope'], rotated, env);
        final expected = name == 'valid_second_key'
            ? 'ok'
            : c['expected']! as String;
        expect(outcome(v), expected, reason: name);
      }
    });

    test('the valid document parses completely', () {
      final valid = cases.firstWhere((c) => c['name'] == 'valid');
      final v = verifyEmergencyEnvelope(valid['envelope'], anchor, env);
      final doc = (v as EnvelopeVerified).document;
      expect(doc.applicationId, file['application_id']);
      expect(doc.environment, 'production');
      expect(doc.issuedAt, DateTime.utc(2026, 10, 29, 8));
      expect(doc.expiresAt, DateTime.utc(2026, 10, 29, 9));
      final p = doc.policies.single;
      expect(p.key, 'checkout.confirm_order');
      expect(p.action, EmergencyAction.block);
      expect(p.reasonCode, 'PRICING_SAFETY');
      expect(p.rolloutBp, 10000);
    });

    test('a non-object body or envelope is malformed', () {
      for (final raw in [null, 'x', 1, <Object?>[]]) {
        expect(outcome(verifyEmergencyEnvelope(raw, anchor, env)), 'malformed');
      }
    });

    test('the wrong environment is rejected', () {
      final valid = cases.firstWhere((c) => c['name'] == 'valid');
      expect(
        outcome(verifyEmergencyEnvelope(valid['envelope'], anchor, 'staging')),
        'wrong_environment',
      );
    });
  });

  group('signed documents', () {
    final signer = TestSigner.generate();
    final anchor = EmergencyTrustAnchor.parse(signer.anchor());

    String verify(Map<String, Object?> envelope) =>
        switch (verifyEmergencyEnvelope(envelope, anchor, 'production')) {
          EnvelopeVerified() => 'ok',
          EnvelopeRejected(:final reason) => reason.wire,
        };

    test('a freshly signed document verifies', () {
      expect(verify(signer.envelope(signer.document())), 'ok');
    });

    test('unknown actions are kept and evaluated as BLOCK', () {
      final doc = signer.document(
        policies: [signer.policy(action: 'THROTTLE')],
      );
      final v = verifyEmergencyEnvelope(
        signer.envelope(doc),
        anchor,
        'production',
      );
      final policy = (v as EnvelopeVerified).document.policies.single;
      expect(policy.action, EmergencyAction.block);
      expect(policy.actionName, 'THROTTLE');
      final d = evaluateEmergencyPolicies(
        policies: v.document.policies,
        documentRevision: 1,
        featureKey: 'checkout.confirm_order',
        platform: 'FLUTTER_IOS',
        appVersion: null,
        subject: null,
        now: DateTime.utc(2026, 10, 29, 8),
      );
      expect(d.action, EmergencyAction.block);
      expect(d.allowed, isFalse);
    });

    test('a malformed policy field makes the document malformed', () {
      final bad = <String, Object?>{
        'priority': '0',
        'revision': 1.5,
        'key': 'Checkout',
        'target_platforms': [1],
        'version_ranges': [
          {'min': '1.x', 'max': null},
        ],
        'expires_at': 'tomorrow',
        'rollout_bp': null,
        'reason_code': 7,
        'fallback': 3,
      };
      for (final e in bad.entries) {
        final doc = signer.document(
          policies: [signer.policy()..[e.key] = e.value],
        );
        expect(verify(signer.envelope(doc)), 'malformed', reason: e.key);
      }
      for (final e in <String, Object?>{
        'revision': '7',
        'issued_at': 'now',
        'expires_at': null,
        'policies': {'a': 1},
      }.entries) {
        final doc = signer.document()..[e.key] = e.value;
        expect(verify(signer.envelope(doc)), 'malformed', reason: e.key);
      }
    });

    test('a payload that is not a JSON object is malformed', () {
      expect(verify(signer.envelopeOfBytes(utf8.encode('[1,2]'))), 'malformed');
      expect(verify(signer.envelopeOfBytes(utf8.encode('{nope'))), 'malformed');
      expect(verify(signer.envelopeOfBytes([0xff, 0xfe])), 'malformed');
    });

    test('bad base64 or DER is a bad signature', () {
      final good = signer.envelope(signer.document());
      expect(verify({...good, 'payload': '***'}), 'bad_signature');
      expect(verify({...good, 'signature': 'A'}), 'bad_signature');
      expect(verify({...good, 'signature': ''}), 'bad_signature');
      final sig = decodeBase64Url(good['signature']! as String)!;
      // Trailing garbage after the DER sequence.
      expect(
        verify({
          ...good,
          'signature': encodeBase64Url([...sig, 0]),
        }),
        'bad_signature',
      );
      // Wrong outer tag.
      expect(
        verify({
          ...good,
          'signature': encodeBase64Url([0x31, ...sig.skip(1)]),
        }),
        'bad_signature',
      );
      // A raw (r||s) signature instead of DER.
      expect(
        verify({
          ...good,
          'signature': encodeBase64Url(Uint8List(64)..fillRange(0, 64, 1)),
        }),
        'bad_signature',
      );
    });

    test('a padded payload and signature are accepted', () {
      final good = signer.envelope(signer.document());
      String pad(String s) => s + '=' * ((4 - s.length % 4) % 4);
      expect(
        verify({
          ...good,
          'payload': pad(good['payload']! as String),
          'signature': pad(good['signature']! as String),
        }),
        'ok',
      );
    });

    test('missing kid or payload is malformed before format checks', () {
      final good = signer.envelope(signer.document());
      expect(verify({...good}..remove('kid')), 'malformed');
      expect(verify({...good, 'payload': 5}), 'malformed');
      expect(verify({...good, 'format': 'x'}..remove('kid')), 'malformed');
    });
  });

  group('trust anchor', () {
    test('rejects anything that is not a valid ES256 anchor', () {
      final signer = TestSigner.generate();
      final spki = encodeBase64Url(signer.spki);
      String anchorOf(Object body) =>
          'bcek.v1.${encodeBase64Url(utf8.encode(jsonEncode(body)))}';
      final invalid = [
        '',
        'bcek.v2.abc',
        'bcek.v1.***',
        'bcek.v1.${encodeBase64Url(utf8.encode('nope'))}',
        anchorOf([]),
        anchorOf({'app': 'a', 'keys': <Object?>[]}),
        anchorOf({
          'app': 'a',
          'keys': [
            {'kid': 'k', 'alg': 'RS256', 'spki': spki},
          ],
        }),
        anchorOf({
          'app': 'a',
          'keys': [
            {'kid': 'k', 'alg': 'ES256', 'spki': 'AAAA'},
          ],
        }),
        // A point that is not on the curve.
        anchorOf({
          'app': 'a',
          'keys': [
            {
              'kid': 'k',
              'alg': 'ES256',
              'spki': encodeBase64Url([
                ...p256SpkiPrefix,
                0x04,
                ...List.filled(64, 1),
              ]),
            },
          ],
        }),
        // A key with another algorithm next to a good one.
        anchorOf({
          'app': 'a',
          'keys': [
            {'kid': 'k', 'alg': 'ES256', 'spki': spki},
            {'kid': 'k2', 'alg': 'none', 'spki': spki},
          ],
        }),
      ];
      for (final a in invalid) {
        expect(
          () => EmergencyTrustAnchor.parse(a),
          throwsFormatException,
          reason: a,
        );
      }
      expect(
        EmergencyTrustAnchor.parse(
          anchorOf({
            'app': 'a',
            'keys': [
              {'kid': 'k', 'alg': 'ES256', 'spki': spki},
            ],
          }),
        ).applicationId,
        'a',
      );
    });
  });

  group('base64url', () {
    test('accepts missing padding and rejects other alphabets', () {
      expect(decodeBase64Url('AQ'), [1]);
      expect(decodeBase64Url('AQ=='), [1]);
      expect(decodeBase64Url('AQI'), [1, 2]);
      expect(decodeBase64Url('-_8'), [0xfb, 0xff]);
      expect(decodeBase64Url(''), isEmpty);
      expect(decodeBase64Url('A'), isNull);
      expect(decodeBase64Url('AQ='), isNull);
      expect(decodeBase64Url('+/8'), isNull);
      expect(decodeBase64Url('AQ I'), isNull);
    });
  });

  test('key patterns', () {
    expect(emergencyKeyMatches('checkout.*', 'checkout.pay'), isTrue);
    expect(emergencyKeyMatches('checkout.*', 'checkout'), isFalse);
    expect(emergencyKeyMatches('checkout.*', 'checkout.pay.card'), isTrue);
    expect(emergencyKeyMatches('checkout', 'checkout.pay'), isFalse);
    expect(isEmergencyKeyPattern('checkout.*'), isTrue);
    expect(isEmergencyKeyPattern('*'), isFalse);
    expect(isEmergencyFeatureKey('checkout.*'), isFalse);
  });
}
