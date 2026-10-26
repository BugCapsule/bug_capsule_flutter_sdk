import 'dart:async';
import 'dart:convert';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule/testing.dart';
import 'package:bug_capsule_stripe/bug_capsule_stripe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stripe_platform_interface/stripe_platform_interface.dart';

const clientSecret = 'pi_3Q_secret_SuperSecretValue';
const ephemeralKey = 'ek_test_YWNjdF9EphemeralKeyValue';
const customerId = 'cus_CustomerIdValue';

const card = PaymentMethod(
  id: 'pm_1Card',
  livemode: false,
  paymentMethodType: 'Card',
  billingDetails: BillingDetails(
    email: 'buyer@example.com',
    name: 'Buyer Person',
    phone: '+4712345678',
    address: Address(
      city: 'Oslo',
      country: 'NO',
      line1: 'Karl Johans gate 1',
      line2: null,
      postalCode: '0154',
      state: null,
    ),
  ),
  card: Card(
    brand: 'visa',
    country: 'NO',
    expMonth: 4,
    expYear: 2031,
    funding: 'credit',
    last4: '4242',
  ),
  sepaDebit: SepaDebit(),
  bacsDebit: BacsDebit(),
  auBecsDebit: AuBecsDebit(),
  ideal: Ideal(),
  fpx: Fpx(),
  usBankAccount: UsBankAccount(),
);

const intent = PaymentIntent(
  id: 'pi_3Q',
  amount: 1999,
  created: '1761470000',
  currency: 'nok',
  status: PaymentIntentsStatus.Succeeded,
  clientSecret: clientSecret,
  livemode: false,
  captureMethod: CaptureMethod.Automatic,
  confirmationMethod: ConfirmationMethod.Automatic,
  paymentMethodId: 'pm_1Card',
  receiptEmail: 'buyer@example.com',
);

StripeException stripeError(FailureCode code, String message) =>
    StripeException(
      error: LocalizedErrorMessage(
        code: code,
        message: message,
        localizedMessage: message,
        stripeErrorCode: code == FailureCode.Failed ? 'card_declined' : null,
        declineCode: code == FailureCode.Failed ? 'insufficient_funds' : null,
        type: code == FailureCode.Failed ? 'card_error' : null,
      ),
    );

/// A scripted Stripe: the sheet outcome and payment results are queued.
class FakeStripePlatform extends StripePlatform {
  final List<Object> presentOutcomes = [];
  Object confirmSheetOutcome = 'ok';
  final List<String> calls = [];

  @override
  Future<void> initialise({
    required String publishableKey,
    String? stripeAccountId,
    ThreeDSecureConfigurationParams? threeDSecureParams,
    String? merchantIdentifier,
    String? urlScheme,
    bool? setReturnUrlSchemeOnAndroid,
  }) async => calls.add('initialise');

  @override
  Future<PaymentSheetPaymentOption?> initPaymentSheet(
    SetupPaymentSheetParameters params,
  ) async {
    calls.add('initPaymentSheet');
    return params.customFlow
        ? const PaymentSheetPaymentOption(label: '•••• 4242', image: 'aW1n')
        : null;
  }

  @override
  Future<PaymentSheetPaymentOption?> presentPaymentSheet({
    PaymentSheetPresentOptions? options,
  }) async {
    calls.add('presentPaymentSheet');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final outcome = presentOutcomes.isEmpty
        ? 'ok'
        : presentOutcomes.removeAt(0);
    if (outcome is Exception) throw outcome;
    return const PaymentSheetPaymentOption(label: '•••• 4242');
  }

  @override
  Future<void> confirmPaymentSheetPayment() async {
    calls.add('confirmPaymentSheetPayment');
    if (confirmSheetOutcome case final Exception e) throw e;
  }

  @override
  Future<PaymentIntent> confirmPayment(
    String paymentIntentClientSecret,
    PaymentMethodParams? params,
    PaymentMethodOptions? options,
  ) async {
    calls.add('confirmPayment');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return intent;
  }

  @override
  Future<PaymentMethod> createPaymentMethod(
    PaymentMethodParams data, [
    PaymentMethodOptions? options,
  ]) async {
    calls.add('createPaymentMethod');
    return card;
  }

  @override
  Future<bool> isPlatformPaySupported({
    IsGooglePaySupportedParams? params,
    PlatformPayWebPaymentRequestCreateOptions? paymentRequestOptions,
  }) async {
    calls.add('isPlatformPaySupported');
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Fails the test if replay reaches Stripe.
class ThrowingStripePlatform extends StripePlatform {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('replay reached Stripe: ${invocation.memberName}');
  }
}

StripePlatform get platform => StripePlatform.instance;

const sheet = SetupPaymentSheetParameters(
  merchantDisplayName: 'Shop',
  paymentIntentClientSecret: clientSecret,
  customerId: customerId,
  customerEphemeralKeySecret: ephemeralKey,
);

/// What the app shows of the selected method; the digits (last four) are
/// zeros in replay.
Object? option(PaymentSheetPaymentOption? o) => o == null
    ? null
    : {'label': o.label.replaceAll(RegExp(r'\d'), '#'), 'image': o.image};

Object? errorJson(Object e) => e is StripeException
    ? [
        'StripeException',
        e.error.code.name,
        e.error.message,
        e.error.stripeErrorCode,
        e.error.declineCode,
      ]
    : ['other', '$e'];

void main() {
  final original = StripePlatform.instance;
  late List<BugCapsuleStripe> adapters;
  late List<ThrowingStripePlatform> throwing;

  setUp(() {
    adapters = [];
    throwing = [];
  });
  tearDown(() {
    for (final a in adapters.reversed) {
      a.uninstall();
    }
    StripePlatform.instance = original;
  });

  BugCapsuleStripe adapterFor(StripePlatform p) {
    final a = BugCapsuleStripe(platform: p);
    adapters.add(a);
    return a;
  }

  Future<AdapterConformanceResult> conform(
    FutureOr<Object?> Function(BugCapsuleStripe adapter) scenario, {
    FakeStripePlatform? fake,
  }) => AdapterConformance.run(
    create: (replaying) {
      if (!replaying) return adapterFor(fake ?? FakeStripePlatform());
      final t = ThrowingStripePlatform();
      throwing.add(t);
      return adapterFor(t);
    },
    scenario: scenario,
  );

  void expectClean(AdapterConformanceResult r) {
    expect(r.problems, isEmpty);
    expect(throwing.single.calls, 0, reason: 'replay reached Stripe');
    expect(r.dependencies.single.adapter, 'bug_capsule.flutter_stripe');
  }

  group('conformance through StripePlatform.instance', () {
    test('initPaymentSheet', () async {
      final r = await conform(
        (_) async => [
          option(await platform.initPaymentSheet(sheet)),
          option(
            await platform.initPaymentSheet(
              const SetupPaymentSheetParameters(
                merchantDisplayName: 'Shop',
                customFlow: true,
                setupIntentClientSecret: 'seti_1_secret_x',
              ),
            ),
          ),
        ],
      );
      expectClean(r);
      expect((r.replayed! as List)[1], {'label': '•••• ####', 'image': 'aW1n'});
    });

    test('presentPaymentSheet: success, then Canceled', () async {
      final r = await conform(
        (_) async {
          final out = <Object?>[];
          for (var i = 0; i < 2; i++) {
            try {
              out.add(option(await platform.presentPaymentSheet()));
            } catch (e) {
              out.add(errorJson(e));
            }
          }
          return out;
        },
        fake: FakeStripePlatform()
          ..presentOutcomes.addAll([
            'ok',
            stripeError(
              FailureCode.Canceled,
              'The payment flow has been canceled',
            ),
          ]),
      );
      expectClean(r);
      expect(r.replayed, [
        {'label': '•••• ####', 'image': null},
        [
          'StripeException',
          'Canceled',
          'The payment flow has been canceled',
          null,
          null,
        ],
      ]);
    });

    test('confirmPaymentSheetPayment: Failed with decline details', () async {
      final r = await conform(
        (_) async {
          try {
            await platform.confirmPaymentSheetPayment();
            return 'paid';
          } catch (e) {
            return errorJson(e);
          }
        },
        fake: FakeStripePlatform()
          ..confirmSheetOutcome = stripeError(
            FailureCode.Failed,
            'Your card has insufficient funds.',
          ),
      );
      expectClean(r);
      expect(r.replayed, [
        'StripeException',
        'Failed',
        'Your card has insufficient funds.',
        'card_declined',
        'insufficient_funds',
      ]);
    });

    test('confirmPayment', () async {
      final r = await conform((_) async {
        final i = await platform.confirmPayment(
          clientSecret,
          const PaymentMethodParams.cardFromMethodId(
            paymentMethodData: PaymentMethodDataCardFromMethod(
              paymentMethodId: 'pm_1Card',
            ),
          ),
          null,
        );
        return [i.id, i.status.name, i.amount, i.currency, i.paymentMethodId];
      });
      expectClean(r);
      expect(r.replayed, ['pi_3Q', 'Succeeded', 1999, 'nok', 'pm_1Card']);
    });

    test('createPaymentMethod', () async {
      final r = await conform((_) async {
        final m = await platform.createPaymentMethod(
          const PaymentMethodParams.card(
            paymentMethodData: PaymentMethodData(
              billingDetails: BillingDetails(email: 'buyer@example.com'),
            ),
          ),
        );
        return [m.id, m.paymentMethodType, m.card.brand, m.card.expYear];
      });
      expectClean(r);
      expect(r.replayed, ['pm_1Card', 'Card', 'visa', 2031]);
    });
  });

  test('secrets and payment details are never recorded', () async {
    final r = await conform((_) async {
      await platform.initPaymentSheet(sheet);
      await platform.presentPaymentSheet();
      final m = await platform.createPaymentMethod(
        const PaymentMethodParams.card(
          paymentMethodData: PaymentMethodData(
            billingDetails: BillingDetails(email: 'buyer@example.com'),
          ),
        ),
      );
      final i = await platform.confirmPayment(clientSecret, null, null);
      return [
        m.card.last4 == '4242' || m.card.last4 == '0000',
        i.clientSecret.isNotEmpty,
      ];
    });
    expectClean(r);
    final recorded = jsonEncode([for (final e in r.events) e.toJson()]);
    for (final secret in [
      clientSecret,
      'SuperSecretValue',
      ephemeralKey,
      customerId,
      'buyer@example.com',
      'Buyer Person',
      'Karl Johans gate',
      '0154',
      '4242',
    ]) {
      expect(recorded, isNot(contains(secret)), reason: secret);
    }
    final initArgs =
        (r.events.first.data['args'] as Map)['value'] as Map<String, Object?>;
    expect(initArgs['intent'], 'payment');
    expect(initArgs['customer'], true);
    expect(initArgs['customerAuth'], 'ephemeralKey');

    // Replay hands back safe placeholders.
    final replay = InteractionHarness.replay([
      for (final e in r.events) e,
    ], dependencies: r.dependencies);
    final t = ThrowingStripePlatform();
    await replay.setUp([adapterFor(t)]);
    await platform.initPaymentSheet(sheet);
    expect((await platform.presentPaymentSheet())!.label, '•••• 0000');
    final m = await platform.createPaymentMethod(
      const PaymentMethodParams.card(
        paymentMethodData: PaymentMethodData(
          billingDetails: BillingDetails(email: 'buyer@example.com'),
        ),
      ),
    );
    final i = await platform.confirmPayment(clientSecret, null, null);
    expect(m.card.last4, '0000');
    expect(m.billingDetails.email, Redactor.placeholder);
    expect(m.billingDetails.address?.country, 'NO');
    expect(i.clientSecret, PaymentRedaction.clientSecretPlaceholder);
    expect(i.receiptEmail, Redactor.placeholder);
    expect(t.calls, 0);
    expect(replay.finish(), isEmpty);
  });

  test('a different client secret in replay still matches', () async {
    final r = await conform((_) async {
      await platform.initPaymentSheet(sheet);
      return 'ok';
    });
    expectClean(r);
    final replay = InteractionHarness.replay([
      for (final e in r.events) e,
    ], dependencies: r.dependencies);
    await replay.setUp([adapterFor(ThrowingStripePlatform())]);
    await platform.initPaymentSheet(
      sheet.copyWith(paymentIntentClientSecret: 'pi_other_secret_other'),
    );
    expect(replay.finish(), isEmpty);
  });

  test(
    'initialise is forwarded while capturing and a no-op in replay',
    () async {
      final fake = FakeStripePlatform();
      await InteractionHarness.capture().setUp([adapterFor(fake)]);
      await platform.initialise(publishableKey: 'pk_test_123');
      expect(fake.calls, ['initialise']);

      final t = ThrowingStripePlatform();
      await InteractionHarness.replay(
        const [],
        dependencies: const [],
      ).setUp([adapterFor(t)]);
      await platform.initialise(publishableKey: 'pk_test_123');
      expect(platform.updateSettingsLazily, isTrue);
      expect(t.calls, 0);
    },
  );

  group('unsupported operations', () {
    test('capture delegates and records a gap', () async {
      final fake = FakeStripePlatform();
      final capture = InteractionHarness.capture();
      await capture.setUp([adapterFor(fake)]);
      await platform.presentPaymentSheet();
      expect(await platform.isPlatformPaySupported(), isTrue);
      expect(fake.calls, ['presentPaymentSheet', 'isPlatformPaySupported']);
      final dep = capture.dependencies().single;
      expect(dep.coverage, DependencyCoverage.partial);
      expect(dep.gaps.single.code, DependencyGaps.operationUnsupported);
    });

    test('replay fails them explicitly without calling Stripe', () async {
      final capture = InteractionHarness.capture();
      await capture.setUp([adapterFor(FakeStripePlatform())]);
      await platform.presentPaymentSheet();
      final replay = InteractionHarness.replay(
        capture.encodedEvents(),
        dependencies: capture.dependencies(),
      );
      final t = ThrowingStripePlatform();
      await replay.setUp([adapterFor(t)]);
      await platform.presentPaymentSheet();
      await expectLater(
        platform.isPlatformPaySupported(),
        throwsA(
          isA<NativeAdapterException>().having(
            (e) => e.code,
            'code',
            'bugcapsule.unsupported',
          ),
        ),
      );
      await expectLater(
        platform.retrievePaymentIntent(clientSecret),
        throwsA(isA<NativeAdapterException>()),
      );
      expect(t.calls, 0);
      expect(replay.finish().map((d) => d.type), [
        'native.unrecorded',
        'native.unrecorded',
      ]);
    });
  });

  test('replay without a Stripe recording never calls Stripe', () async {
    final replay = InteractionHarness.replay(const [], dependencies: const []);
    final t = ThrowingStripePlatform();
    await replay.setUp([adapterFor(t)]);
    await expectLater(
      platform.presentPaymentSheet(),
      throwsA(
        isA<NativeAdapterException>().having(
          (e) => e.code,
          'code',
          'bugcapsule.unrecorded',
        ),
      ),
    );
    expect(t.calls, 0);
    expect(replay.finish().map((d) => d.type), ['native.unrecorded']);
  });
}
