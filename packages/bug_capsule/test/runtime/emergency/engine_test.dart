import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/src/runtime/emergency/contract.dart';
import 'package:bug_capsule/src/runtime/emergency/engine.dart';
import 'package:bug_capsule/src/runtime/emergency/transport.dart';
import 'package:bug_capsule/src/runtime/emergency/types.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'signing.dart';

/// The runtime of §5 and §7 on a fake clock: acceptance, refresh, backoff,
/// failure modes, receipts and snapshots.

final _start = DateTime.utc(2026, 10, 29, 8, 30);
const _backend = BugCapsuleBackendConfig(
  url: 'http://backend.test',
  ingestKey: 'bct_test',
);
const _key = 'checkout.confirm_order';

void main() {
  late TestSigner signer;
  late FakeTransport transport;
  late List<EmergencySnapshot> snapshots;
  void Function(EmergencySnapshot)? observer;
  late bool replaying;
  late BugCapsuleBackendConfig? connection;

  setUp(() {
    signer = TestSigner.generate();
    transport = FakeTransport();
    snapshots = [];
    observer = null;
    replaying = false;
    connection = _backend;
  });

  EmergencyEngine engine(
    FakeAsync async, {
    Map<String, EmergencyFailureMode> modes = const {},
    EmergencyTrustAnchor? anchor,
    Duration interval = const Duration(seconds: 60),
  }) => EmergencyEngine(
    anchor: anchor ?? EmergencyTrustAnchor.parse(signer.anchor()),
    environment: 'production',
    platform: EmergencyPlatform.flutterAndroid,
    refreshInterval: interval,
    failureModes: EmergencyFailureModes(modes),
    store: null,
    transport: transport,
    connection: () => connection,
    appVersion: () => '2.4.1',
    sdkVersion: '0.0.0-test',
    installationId: 'AAAAAAAAAAAAAAAAAAAAAA',
    isReplaying: () => replaying,
    onSnapshot: (s) {
      snapshots.add(s);
      observer?.call(s);
    },
    now: () => async.getClock(_start).now(),
    random: MidRandom(),
  );

  DateTime now(FakeAsync async) => async.getClock(_start).now();

  EmergencyFetched served(Map<String, Object?> doc, [String etag = '"e1"']) =>
      EmergencyFetched(signer.envelope(doc), etag);

  Map<String, Object?> doc({
    int revision = 1,
    DateTime? issuedAt,
    DateTime? expiresAt,
    List<Map<String, Object?>>? policies,
  }) => signer.document(
    revision: revision,
    issuedAt: issuedAt ?? _start.subtract(const Duration(minutes: 30)),
    expiresAt: expiresAt ?? _start.add(const Duration(days: 1)),
    policies: policies,
  );

  group('acceptance', () {
    test('a verified document decides, and one APPLIED receipt is sent', () {
      fakeAsync((async) {
        transport.answer(served(doc(revision: 3)));
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();

        final d = e.evaluate(_key);
        expect(d.action, EmergencyAction.block);
        expect(d.allowed, isFalse);
        expect(d.source, EmergencyDecisionSource.policy);
        expect(d.documentRevision, 3);
        expect(d.policyId, 'p-1');
        expect(e.evaluate('search.query').action, EmergencyAction.allow);
        expect(e.status().state, EmergencyDocumentState.usable);
        expect(e.status().revision, 3);
        expect(e.status().lastFetchAt, isNotNull);
        expect(e.status().lastError, isNull);
        expect(transport.receipts, [
          {
            'environment': 'production',
            'platform': 'FLUTTER_ANDROID',
            'installationId': 'AAAAAAAAAAAAAAAAAAAAAA',
            'appVersion': '2.4.1',
            'sdkVersion': '0.0.0-test',
            'revision': 3,
            'status': 'APPLIED',
            'errorCode': null,
          },
        ]);
        final r = transport.requests.single;
        expect(r.applicationId, TestSigner.appId);
        expect(r.platform, 'FLUTTER_ANDROID');
        expect(r.environment, 'production');
        expect(r.appVersion, '2.4.1');
        expect(r.etag, isNull);
        e.dispose();
      });
    });

    test('a lower revision is rejected as stale_revision', () {
      fakeAsync((async) {
        transport
          ..answer(served(doc(revision: 42)))
          ..answer(
            served(
              doc(revision: 41, policies: [signer.policy(action: 'ALLOW')]),
              '"e2"',
            ),
          );
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 60));

        expect(transport.fetches, 2);
        expect(e.status().revision, 42);
        expect(e.evaluate(_key).action, EmergencyAction.block);
        expect(e.status().lastError?.code, 'stale_revision');
        expect(transport.receipts.last, containsPair('status', 'FAILED'));
        expect(transport.receipts.last, containsPair('revision', 41));
        expect(
          transport.receipts.last,
          containsPair('errorCode', 'stale_revision'),
        );
        e.dispose();
      });
    });

    test('the same revision with an older or equal issued_at changes '
        'nothing; a later one is accepted', () {
      fakeAsync((async) {
        final t0 = _start.subtract(const Duration(minutes: 10));
        transport
          ..answer(served(doc(revision: 5, issuedAt: t0)))
          ..answer(
            served(
              doc(
                revision: 5,
                issuedAt: t0.subtract(const Duration(minutes: 20)),
                policies: [signer.policy(action: 'ALLOW')],
              ),
              '"older"',
            ),
          )
          ..answer(served(doc(revision: 5, issuedAt: t0), '"same"'))
          ..answer(
            served(
              doc(revision: 5, issuedAt: t0.add(const Duration(minutes: 5))),
              '"later"',
            ),
          );
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        final published = snapshots.length;

        async.elapse(const Duration(seconds: 60));
        expect(e.status().issuedAt, t0);
        expect(e.evaluate(_key).action, EmergencyAction.block);
        expect(e.status().lastError, isNull);

        async.elapse(const Duration(seconds: 60));
        expect(e.status().issuedAt, t0);
        expect(snapshots.length, published, reason: 'nothing changed');

        async.elapse(const Duration(seconds: 60));
        expect(e.status().issuedAt, t0.add(const Duration(minutes: 5)));
        expect(
          transport.requests.last.etag,
          '"e1"',
          reason: 'ignored copies do not replace the ETag',
        );
        expect(
          transport.receipts.where((r) => r['status'] == 'APPLIED'),
          hasLength(1),
          reason: 'one APPLIED receipt per revision',
        );
        e.dispose();
      });
    });

    test('a document already expired by more than 300 s is rejected', () {
      fakeAsync((async) {
        transport.answer(
          served(
            doc(
              revision: 2,
              issuedAt: _start.subtract(const Duration(hours: 2)),
              expiresAt: _start.subtract(const Duration(seconds: 301)),
            ),
          ),
        );
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        expect(e.status().state, EmergencyDocumentState.none);
        expect(e.status().lastError?.code, 'expired_on_arrival');
        expect(transport.receipts.single['errorCode'], 'expired_on_arrival');
        expect(transport.receipts.single['revision'], 2);
        e.dispose();
      });
    });

    test('a document within the 300 s grace is accepted and usable', () {
      fakeAsync((async) {
        transport.answer(
          served(
            doc(
              revision: 2,
              issuedAt: _start.subtract(const Duration(hours: 2)),
              expiresAt: _start.subtract(const Duration(seconds: 299)),
            ),
          ),
        );
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        expect(e.status().state, EmergencyDocumentState.usable);
        expect(e.evaluate(_key).source, EmergencyDecisionSource.policy);
        e.dispose();
      });
    });

    test('every verification failure keeps the current document and sends '
        'its reason once', () {
      final fixtures =
          jsonDecode(
                File(
                  '../../spec/fixtures/emergency-v1/envelopes.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final anchor = EmergencyTrustAnchor.parse(fixtures['anchor']! as String);
      final cases = [
        for (final c in fixtures['cases']! as List<Object?>)
          (c! as Map).cast<String, Object?>(),
      ];
      final valid = cases.firstWhere((c) => c['name'] == 'valid');
      final failures = cases.where((c) => c['expected'] != 'ok').toList();
      expect(
        failures.map((c) => c['expected']).toSet(),
        containsAll([
          'malformed',
          'unsupported_format',
          'unknown_key',
          'bad_signature',
          'unsupported_schema',
          'wrong_application',
          'wrong_environment',
        ]),
      );
      fakeAsync((async) {
        transport.answer(EmergencyFetched(valid['envelope'], '"v"'));
        for (final c in failures) {
          // Each bad envelope twice: the receipt goes out once.
          transport
            ..answer(EmergencyFetched(c['envelope'], '"x"'))
            ..answer(EmergencyFetched(c['envelope'], '"x"'));
        }
        // The fixtures were issued at 08:00 and expire at 09:00.
        final e = engine(async, anchor: anchor);
        unawaited(e.start());
        async.flushMicrotasks();
        expect(e.status().revision, 42);
        for (final c in failures) {
          for (var i = 0; i < 2; i++) {
            unawaited(e.refresh());
            async.flushMicrotasks();
            expect(e.status().revision, 42, reason: c['name'] as String);
            expect(
              e.status().lastError?.code,
              c['expected'],
              reason: c['name'] as String,
            );
            expect(e.evaluate(_key).action, EmergencyAction.block);
          }
        }
        final failed = transport.receipts
            .where((r) => r['status'] == 'FAILED')
            .toList();
        expect(
          failed.map((r) => r['errorCode']).toList(),
          failures.map((c) => c['expected']).toSet().toList(),
          reason: 'once per (revision, status, code)',
        );
        expect(failed.every((r) => r['revision'] == 42), isTrue);
        e.dispose();
      });
    });

    test('a body that is not an envelope is malformed', () {
      fakeAsync((async) {
        transport.answer(const EmergencyFetched(null, null));
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        expect(e.status().lastError?.code, 'malformed');
        expect(transport.receipts.single, containsPair('revision', 0));
        e.dispose();
      });
    });
  });

  group('failure modes', () {
    test('FAIL_OPEN is the default for every key before any document', () {
      fakeAsync((async) {
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        final d = e.evaluate(_key);
        expect(d.allowed, isTrue);
        expect(d.action, EmergencyAction.allow);
        expect(d.reasonCode, 'POLICY_UNAVAILABLE');
        expect(d.source, EmergencyDecisionSource.failureMode);
        expect(d.documentRevision, isNull);
        e.dispose();
      });
    });

    test('after expiry each key uses its failure mode', () {
      fakeAsync((async) {
        transport.answer(
          served(
            doc(
              revision: 9,
              expiresAt: _start.add(const Duration(minutes: 10)),
              policies: [
                signer.policy(key: 'checkout.*', id: 'p-a'),
                signer.policy(key: 'wallet.transfer', id: 'p-b'),
                signer.policy(key: 'search.query', id: 'p-c'),
              ],
            ),
          ),
        );
        transport.otherwise = () =>
            const EmergencyFetchFailed('network_error', 'offline');
        final e = engine(
          async,
          modes: {
            'checkout.*': EmergencyFailureMode.failClosed,
            'wallet.transfer': EmergencyFailureMode.useLastValidPolicy,
            'profile.edit': EmergencyFailureMode.useLastValidPolicy,
          },
        );
        unawaited(e.start());
        async.flushMicrotasks();
        expect(
          e.evaluate('search.query').source,
          EmergencyDecisionSource.policy,
        );

        // Usable until expires_at + 300 s.
        async.elapse(const Duration(minutes: 15));
        expect(e.status().state, EmergencyDocumentState.usable);
        async.elapse(const Duration(seconds: 1));
        expect(e.status().state, EmergencyDocumentState.expired);

        final open = e.evaluate('search.query');
        expect(open.action, EmergencyAction.allow);
        expect(open.reasonCode, 'POLICY_UNAVAILABLE');
        expect(open.source, EmergencyDecisionSource.failureMode);

        final closed = e.evaluate('checkout.pay');
        expect(closed.action, EmergencyAction.block);
        expect(closed.allowed, isFalse);
        expect(closed.reasonCode, 'POLICY_UNAVAILABLE');
        expect(closed.source, EmergencyDecisionSource.failureMode);

        final stale = e.evaluate('wallet.transfer');
        expect(stale.action, EmergencyAction.block);
        expect(stale.policyId, 'p-b');
        expect(stale.source, EmergencyDecisionSource.stalePolicy);

        // useLastValidPolicy with no matching policy: the stale document
        // still decides (ALLOW).
        final unmatched = e.evaluate('profile.edit');
        expect(unmatched.action, EmergencyAction.allow);
        expect(unmatched.source, EmergencyDecisionSource.stalePolicy);
        expect(
          snapshots.last.state,
          EmergencyDocumentState.expired,
          reason: 'expiry is published',
        );
        e.dispose();
      });
    });

    test('USE_LAST_VALID_POLICY without any document allows', () {
      fakeAsync((async) {
        final e = engine(
          async,
          modes: {'wallet.*': EmergencyFailureMode.useLastValidPolicy},
        );
        unawaited(e.start());
        async.flushMicrotasks();
        final d = e.evaluate('wallet.transfer');
        expect(d.action, EmergencyAction.allow);
        expect(d.reasonCode, 'POLICY_UNAVAILABLE');
        expect(d.source, EmergencyDecisionSource.failureMode);
        e.dispose();
      });
    });

    test('an exact key beats the longest prefix, which beats shorter ones', () {
      final modes = EmergencyFailureModes({
        'checkout.*': EmergencyFailureMode.failClosed,
        'checkout.pay.*': EmergencyFailureMode.useLastValidPolicy,
        'checkout.pay.card': EmergencyFailureMode.failOpen,
        'Not A Key': EmergencyFailureMode.failClosed,
        '*': EmergencyFailureMode.failClosed,
      });
      expect(modes.modeFor('checkout.view'), EmergencyFailureMode.failClosed);
      expect(
        modes.modeFor('checkout.pay.wallet'),
        EmergencyFailureMode.useLastValidPolicy,
      );
      expect(modes.modeFor('checkout.pay.card'), EmergencyFailureMode.failOpen);
      expect(
        modes.modeFor('checkout.pay'),
        EmergencyFailureMode.failClosed,
        reason: 'checkout.pay.* does not cover checkout.pay',
      );
      expect(modes.modeFor('checkout'), EmergencyFailureMode.failOpen);
      expect(modes.modeFor('search.query'), EmergencyFailureMode.failOpen);
      expect(modes.modeFor('Not A Key'), EmergencyFailureMode.failOpen);
    });

    test('a policy expiring publishes a snapshot', () {
      fakeAsync((async) {
        transport.answer(
          served(
            doc(
              revision: 4,
              policies: [
                signer.policy(
                  expiresAt: _start
                      .add(const Duration(seconds: 30))
                      .toIso8601String(),
                ),
              ],
            ),
          ),
        );
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        expect(e.evaluate(_key).action, EmergencyAction.block);
        final before = snapshots.length;
        async.elapse(const Duration(seconds: 31));
        expect(e.evaluate(_key).action, EmergencyAction.allow);
        expect(snapshots.length, before + 1);
        e.dispose();
      });
    });
  });

  group('refresh', () {
    test('success refetches every interval, sending the ETag', () {
      fakeAsync((async) {
        transport.answer(served(doc(revision: 1), '"abc"'));
        transport.otherwise = () => const EmergencyNotModified();
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        expect(transport.fetches, 1);
        async.elapse(const Duration(seconds: 59));
        expect(transport.fetches, 1);
        async.elapse(const Duration(seconds: 1));
        expect(transport.fetches, 2);
        expect(transport.requests.last.etag, '"abc"');
        // 304: nothing changes, the next fetch is scheduled normally.
        expect(e.status().revision, 1);
        expect(e.status().lastError, isNull);
        expect(e.nextFetchAt, now(async).add(const Duration(seconds: 60)));
        e.dispose();
      });
    });

    test('failures back off exponentially up to 15 minutes', () {
      fakeAsync((async) {
        transport.otherwise = () =>
            const EmergencyFetchFailed('http_503', 'HTTP 503', status: 503);
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        final delays = <int>[];
        for (var i = 0; i < 7; i++) {
          final at = e.nextFetchAt!;
          delays.add(at.difference(now(async)).inSeconds);
          async.elapse(at.difference(now(async)));
        }
        expect(delays, [60, 120, 240, 480, 900, 900, 900]);
        expect(e.status().lastError?.code, 'http_503');
        expect(e.status().lastError?.httpStatus, 503);
        e.dispose();
      });
    });

    test('jitter stays within ±20 %', () {
      fakeAsync((async) {
        transport.otherwise = () =>
            const EmergencyFetchFailed('network_error', 'offline');
        final e = EmergencyEngine(
          anchor: EmergencyTrustAnchor.parse(signer.anchor()),
          environment: 'production',
          platform: EmergencyPlatform.flutterIos,
          refreshInterval: const Duration(seconds: 60),
          failureModes: EmergencyFailureModes.defaults,
          store: null,
          transport: transport,
          connection: () => _backend,
          appVersion: () => null,
          sdkVersion: 'x',
          installationId: 'AAAAAAAAAAAAAAAAAAAAAA',
          isReplaying: () => false,
          onSnapshot: (_) {},
          now: () => async.getClock(_start).now(),
        );
        unawaited(e.start());
        async.flushMicrotasks();
        final delay = e.nextFetchAt!.difference(now(async)).inMilliseconds;
        expect(delay, inInclusiveRange(48000, 72000));
        e.dispose();
      });
    });

    test('Retry-After raises the delay, also beyond the cap', () {
      fakeAsync((async) {
        transport
          ..answer(
            const EmergencyFetchFailed(
              'http_429',
              'HTTP 429',
              status: 429,
              retryAfter: Duration(seconds: 600),
            ),
          )
          ..answer(
            const EmergencyFetchFailed(
              'http_503',
              'HTTP 503',
              status: 503,
              retryAfter: Duration(hours: 2),
            ),
          )
          ..answer(
            const EmergencyFetchFailed(
              'http_503',
              'HTTP 503',
              status: 503,
              retryAfter: Duration(seconds: 1),
            ),
          );
        transport.otherwise = () => served(doc());
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        expect(e.nextFetchAt!.difference(now(async)).inSeconds, 600);
        async.elapse(const Duration(seconds: 600));
        expect(e.nextFetchAt!.difference(now(async)), const Duration(hours: 2));
        async.elapse(const Duration(hours: 2));
        // Third failure: 240 s beats the 1 s Retry-After.
        expect(e.nextFetchAt!.difference(now(async)).inSeconds, 240);
        async.elapse(const Duration(seconds: 240));
        // Success resets the failure count.
        expect(e.status().revision, 1);
        expect(e.nextFetchAt!.difference(now(async)).inSeconds, 60);
        e.dispose();
      });
    });

    test('409 not configured is retried with backoff', () {
      fakeAsync((async) {
        transport.otherwise = () => const EmergencyFetchFailed(
          'not_configured',
          'HTTP 409 (emergency_not_configured)',
          status: 409,
        );
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        expect(e.status().lastError?.code, 'not_configured');
        expect(e.status().credentialRejected, isFalse);
        async.elapse(const Duration(seconds: 60));
        expect(transport.fetches, 2);
        e.dispose();
      });
    });

    for (final status in [401, 403, 404]) {
      test('$status stops scheduled fetches and keeps the cached document', () {
        fakeAsync((async) {
          transport
            ..answer(
              served(
                doc(
                  revision: 7,
                  expiresAt: _start.add(const Duration(days: 1)),
                ),
              ),
            )
            ..answer(
              EmergencyFetchFailed(
                'credential_rejected',
                'HTTP $status',
                status: status,
              ),
            );
          transport.otherwise = () => served(
            doc(revision: 8, expiresAt: _start.add(const Duration(days: 1))),
          );
          final e = engine(async);
          unawaited(e.start());
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 60));
          expect(transport.fetches, 2);
          expect(e.status().credentialRejected, isTrue);
          expect(e.status().lastError?.code, 'credential_rejected');
          expect(e.nextFetchAt, isNull);

          async.elapse(const Duration(hours: 3));
          expect(transport.fetches, 2, reason: 'no scheduled fetch');
          e
            ..onPaused()
            ..onResumed();
          async.flushMicrotasks();
          expect(transport.fetches, 2, reason: 'no fetch on resume');
          expect(e.evaluate(_key).documentRevision, 7);

          // An explicit refresh is still tried; success resumes the schedule.
          unawaited(e.refresh());
          async.flushMicrotasks();
          expect(transport.fetches, 3);
          expect(e.status().credentialRejected, isFalse);
          expect(e.status().revision, 8);
          e.dispose();
        });
      });
    }

    test('concurrent refreshes join the fetch in flight', () {
      fakeAsync((async) {
        final gate = Completer<EmergencyFetchResult>();
        transport.script.add(() => gate.future);
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        var done = 0;
        for (var i = 0; i < 5; i++) {
          unawaited(e.refresh().then((_) => done++));
        }
        async.flushMicrotasks();
        expect(transport.fetches, 1);
        // Evaluations during the fetch use the old snapshot.
        expect(e.evaluate(_key).source, EmergencyDecisionSource.failureMode);
        gate.complete(served(doc(revision: 2)));
        async.flushMicrotasks();
        expect(done, 5);
        expect(transport.fetches, 1);
        expect(e.evaluate(_key).documentRevision, 2);
        e.dispose();
      });
    });

    test('no timer runs in the background; resume fetches', () {
      fakeAsync((async) {
        transport.otherwise = () => const EmergencyNotModified();
        transport.answer(served(doc(revision: 1)));
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 20));
        e.onPaused();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(hours: 1));
        expect(transport.fetches, 1);
        e.onResumed();
        async.flushMicrotasks();
        expect(transport.fetches, 2);
        // A quick background/foreground round trip does not refetch.
        e
          ..onPaused()
          ..onResumed();
        async.flushMicrotasks();
        expect(transport.fetches, 2);
        e.dispose();
      });
    });

    test('resume during backoff waits for the backoff', () {
      fakeAsync((async) {
        transport.otherwise = () => const EmergencyFetchFailed(
          'http_429',
          'HTTP 429',
          status: 429,
          retryAfter: Duration(minutes: 30),
        );
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        e.onPaused();
        async.elapse(const Duration(minutes: 5));
        e.onResumed();
        async.flushMicrotasks();
        expect(transport.fetches, 1);
        async.elapse(const Duration(minutes: 25));
        expect(transport.fetches, 2);
        e.dispose();
      });
    });

    test('without a connection nothing is fetched', () {
      fakeAsync((async) {
        connection = null;
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        expect(transport.fetches, 0);
        expect(e.status().lastError?.code, 'not_connected');
        connection = _backend;
        async.elapse(const Duration(seconds: 60));
        expect(transport.fetches, 1);
        e.dispose();
      });
    });

    test('replay: no network calls and no receipts', () {
      fakeAsync((async) {
        replaying = true;
        transport.otherwise = () => served(doc());
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        unawaited(e.refresh());
        async.elapse(const Duration(hours: 1));
        e
          ..onPaused()
          ..onResumed();
        async.flushMicrotasks();
        expect(transport.fetches, 0);
        expect(transport.receipts, isEmpty);
        e.dispose();
      });
    });

    test('a failing receipt endpoint is logged and dropped', () {
      fakeAsync((async) {
        transport.failReceipts = true;
        transport.answer(served(doc(revision: 1)));
        transport.otherwise = () => served(doc(revision: 1));
        final e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));
        expect(transport.receipts, hasLength(1), reason: 'never retried');
        expect(e.status().revision, 1);
        e.dispose();
      });
    });
  });

  group('snapshots', () {
    test('observers get each new document whole, after the swap', () {
      fakeAsync((async) {
        transport
          ..answer(served(doc(revision: 1)))
          ..answer(
            served(
              doc(revision: 2, policies: [signer.policy(action: 'READ_ONLY')]),
            ),
          );
        final seen = <(int?, EmergencyAction)>[];
        late final EmergencyEngine e;
        // When called, the observer already sees the new document.
        final evaluatedInObserver = <int?>[];
        observer = (s) =>
            evaluatedInObserver.add(e.evaluate(_key).documentRevision);
        e = engine(async);
        unawaited(e.start());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 60));
        final published = snapshots.where((s) => s.document != null);
        for (final s in published) {
          seen.add((s.revision, s.document!.policies.single.action));
        }
        expect(seen, [
          (1, EmergencyAction.block),
          (2, EmergencyAction.readOnly),
        ]);
        expect(evaluatedInObserver, [null, 1, 2]);
        expect(
          snapshots.every((s) => s.revision == s.document?.revision),
          isTrue,
        );
        expect(snapshots.last.state, EmergencyDocumentState.usable);
        expect(e.snapshot.revision, 2);
        e.dispose();
      });
    });

    test('an observer that throws does not affect the engine', () {
      fakeAsync((async) {
        transport.answer(served(doc(revision: 1)));
        final e = EmergencyEngine(
          anchor: EmergencyTrustAnchor.parse(signer.anchor()),
          environment: 'production',
          platform: EmergencyPlatform.flutterIos,
          refreshInterval: const Duration(seconds: 60),
          failureModes: EmergencyFailureModes.defaults,
          store: null,
          transport: transport,
          connection: () => _backend,
          appVersion: () => null,
          sdkVersion: 'x',
          installationId: 'AAAAAAAAAAAAAAAAAAAAAA',
          isReplaying: () => false,
          onSnapshot: (_) => throw StateError('observer bug'),
          now: () => async.getClock(_start).now(),
          random: MidRandom(),
        );
        unawaited(e.start());
        async.flushMicrotasks();
        expect(e.status().revision, 1);
        expect(e.nextFetchAt, isNotNull);
        e.dispose();
      });
    });
  });
}
