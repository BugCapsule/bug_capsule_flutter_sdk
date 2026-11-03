import 'dart:async';
import 'dart:convert';

import 'package:bug_capsule/bug_capsule.dart';
import 'package:flutter/widgets.dart';
import 'package:stripe_platform_interface/stripe_platform_interface.dart';

const bugCapsuleStripeVersion = '0.1.0-dev.1';

/// Payments adapter (`bug_capsule.flutter_stripe`, capsule-v2 `native`) on
/// the `stripe_platform_interface` boundary.
///
/// [setUp] (run by `BugCapsule.init`) installs a delegating
/// [StripePlatform.instance], so `Stripe.instance` keeps working unchanged.
/// It records the app-facing outcome of [supportedOperations]: the success
/// value, or the [StripeException] with its [FailureCode] (`Canceled`,
/// `Failed`, `Timeout`) and messages.
///
/// **Replay substitute: the native sheet is not shown; the recorded outcome
/// is returned.** Replay never presents Stripe UI, never contacts Stripe
/// and cannot charge anyone. Client secrets, ephemeral keys and customer
/// ids are never recorded (only whether they were given), payment method
/// details are redacted (see [PaymentRedaction]), and none of them is
/// needed to replay.
///
/// Install it before the app first touches `Stripe` (including
/// `Stripe.publishableKey = ...`): `flutter_stripe` keeps the platform
/// instance it sees first.
class BugCapsuleStripe extends NativeAdapter {
  /// Wraps [platform], or the [StripePlatform.instance] registered when
  /// [setUp] runs.
  BugCapsuleStripe({StripePlatform? platform}) : _delegate = platform;

  StripePlatform? _delegate;
  _BugCapsuleStripePlatform? _installed;

  /// The platform implementation calls reach while capturing.
  StripePlatform get delegate => _delegate ??= _unwrap(StripePlatform.instance);

  @override
  String get name => 'stripe';

  @override
  String get adapter => 'bug_capsule.flutter_stripe';

  @override
  String get adapterVersion => bugCapsuleStripeVersion;

  static const supportedOperations = [
    'initPaymentSheet',
    'presentPaymentSheet',
    'confirmPaymentSheetPayment',
    'confirmPayment',
    'createPaymentMethod',
  ];

  @override
  List<String> get operations => supportedOperations;

  @override
  Map<String, String> get tested => const {
    'stripe_platform_interface': '14.2.0',
  };

  @override
  Future<void> setUp(BugCapsuleSession session) async {
    await super.setUp(session);
    install();
  }

  /// Installs the delegating [StripePlatform.instance] (idempotent).
  void install() {
    delegate;
    if (identical(StripePlatform.instance, _installed)) return;
    StripePlatform.instance = _installed = _BugCapsuleStripePlatform(this);
  }

  /// Puts [delegate] back as [StripePlatform.instance].
  void uninstall() {
    if (identical(StripePlatform.instance, _installed)) {
      StripePlatform.instance = delegate;
    }
    _installed = null;
  }

  static StripePlatform _unwrap(StripePlatform p) =>
      p is _BugCapsuleStripePlatform ? p._owner.delegate : p;

  @override
  (String, String?, Object?) describeError(Object error) {
    final (code, message, details) = switch (error) {
      StripeException(:final error) => (
        error.code.name,
        error.message,
        <String, Object?>{
          'localizedMessage': error.localizedMessage,
          'stripeErrorCode': error.stripeErrorCode,
          'declineCode': error.declineCode,
          'type': error.type,
        },
      ),
      StripeConfigException(:final message) => ('config', message, null),
      _ => super.describeError(error),
    };
    final s = session;
    return (
      code,
      message == null || s == null ? message : s.redactor.scrubText(message),
      details,
    );
  }

  @override
  Object rebuildError(String code, String? message, Object? details) {
    final failure = FailureCode.values.asNameMap()[code];
    if (failure != null) {
      final d = details is Map ? details : const {};
      return StripeException(
        error: LocalizedErrorMessage(
          code: failure,
          message: message,
          localizedMessage: d['localizedMessage'] as String?,
          stripeErrorCode: d['stripeErrorCode'] as String?,
          declineCode: d['declineCode'] as String?,
          type: d['type'] as String?,
        ),
      );
    }
    if (code == 'config') return StripeConfigException(message ?? '');
    return super.rebuildError(code, message, details);
  }

  // ------------------------------------------------------------ plumbing

  bool get _replaying => session?.replay != null;

  bool get _unserved => _replaying && replayInteractions == null;

  NativeAdapterException _fail(String code, String operation, String why) {
    diverge('native.unrecorded', '$adapter $operation: $why');
    return NativeAdapterException(code, '$operation: $why');
  }

  Future<T> _call<T>(
    String operation, {
    Object? args,
    required Future<T> Function() invoke,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) {
    if (_unserved) {
      return Future.error(
        _fail(
          'bugcapsule.unrecorded',
          operation,
          'the capsule has no recording of this adapter',
        ),
      );
    }
    return call(
      operation,
      args: args,
      invoke: invoke,
      encode: encode,
      decode: decode,
    );
  }

  /// An operation this adapter does not record: the platform while
  /// capturing (with a gap), an explicit failure during replay.
  Future<T> _unsupported<T>(String operation, Future<T> Function() real) {
    if (_replaying) {
      return Future.error(
        _fail(
          'bugcapsule.unsupported',
          operation,
          'not recorded by $adapter, so it cannot be replayed',
        ),
      );
    }
    if (capturing) {
      stats.gap(
        DependencyGaps.operationUnsupported,
        'unsupported operation $operation (not recorded)',
      );
    }
    return real();
  }

  // ------------------------------------------------------------ operations

  Future<PaymentSheetPaymentOption?> initPaymentSheet(
    SetupPaymentSheetParameters params,
  ) => _call(
    'initPaymentSheet',
    args: PaymentRedaction.sheetParams(params),
    invoke: () => delegate.initPaymentSheet(params),
    encode: _option,
    decode: _readOption,
  );

  Future<PaymentSheetPaymentOption?> presentPaymentSheet({
    PaymentSheetPresentOptions? options,
  }) => _call(
    'presentPaymentSheet',
    args: {'timeout': ?options?.timeout},
    invoke: () => delegate.presentPaymentSheet(options: options),
    encode: _option,
    decode: _readOption,
  );

  Future<void> confirmPaymentSheetPayment() => _call<void>(
    'confirmPaymentSheetPayment',
    invoke: delegate.confirmPaymentSheetPayment,
    encode: (_) => null,
    decode: (_) {},
  );

  Future<PaymentIntent> confirmPayment(
    String paymentIntentClientSecret,
    PaymentMethodParams? params,
    PaymentMethodOptions? options,
  ) => _call(
    'confirmPayment',
    args: {
      'params': PaymentRedaction.methodParams(params),
      'options': options?.toJson(),
    },
    invoke: () =>
        delegate.confirmPayment(paymentIntentClientSecret, params, options),
    encode: PaymentRedaction.paymentIntent,
    decode: PaymentRedaction.readPaymentIntent,
  );

  Future<PaymentMethod> createPaymentMethod(
    PaymentMethodParams params, [
    PaymentMethodOptions? options,
  ]) => _call(
    'createPaymentMethod',
    args: {
      'params': PaymentRedaction.methodParams(params),
      'options': options?.toJson(),
    },
    invoke: () => delegate.createPaymentMethod(params, options),
    encode: PaymentRedaction.paymentMethod,
    decode: (json) =>
        PaymentMethod.fromJson((json! as Map).cast<String, dynamic>()),
  );

  static Object? _option(PaymentSheetPaymentOption? o) =>
      o == null ? null : PaymentRedaction.paymentOption(o);

  static PaymentSheetPaymentOption? _readOption(Object? json) => json == null
      ? null
      : PaymentSheetPaymentOption.fromJson(
          (json as Map).cast<String, dynamic>(),
        );
}

/// What is recorded of Stripe arguments and results: shapes and outcomes,
/// never secrets or payment details.
abstract final class PaymentRedaction {
  /// Synthetic `PaymentIntent.clientSecret` handed to the app in replay
  /// (the real one is never recorded).
  static const clientSecretPlaceholder = 'pi_redacted_secret_redacted';

  /// Replaces personal and account details.
  static const redactedKeys = {
    'email',
    'phone',
    'name',
    'line1',
    'line2',
    'postalCode',
    'city',
    'state',
    'fingerprint',
    'bankCode',
    'sortCode',
    'bsbNumber',
    'routingNumber',
    'bankIdentifierCode',
    'bankName',
    'receiptEmail',
  };

  /// `initPaymentSheet` arguments: which kind of intent and customer were
  /// given (not their secrets or ids) and the sheet's display settings.
  static Map<String, Object?> sheetParams(SetupPaymentSheetParameters p) => {
    'merchantDisplayName': p.merchantDisplayName,
    'customFlow': p.customFlow,
    'primaryButtonLabel': p.primaryButtonLabel,
    'style': p.style?.name,
    'allowsDelayedPaymentMethods': p.allowsDelayedPaymentMethods,
    'intent': p.paymentIntentClientSecret != null
        ? 'payment'
        : p.setupIntentClientSecret != null
        ? 'setup'
        : p.intentConfiguration != null
        ? 'deferred'
        : null,
    'customer': p.customerId != null,
    'customerAuth': p.customerSessionClientSecret != null
        ? 'session'
        : p.customerEphemeralKeySecret != null
        ? 'ephemeralKey'
        : null,
    'applePay': p.applePay != null,
    'googlePay': p.googlePay != null,
  };

  /// Payment method parameters: the method type and which data fields were
  /// given, never their values.
  static Map<String, Object?>? methodParams(PaymentMethodParams? p) {
    if (p == null) return null;
    final json = p.toJson();
    final data = json['paymentMethodData'];
    return {
      'type': json['paymentMethodType'],
      'fields': data is Map
          ? ([
              for (final e in data.entries)
                if (e.value != null) '${e.key}',
            ]..sort())
          : const <String>[],
    };
  }

  static Map<String, Object?> paymentIntent(PaymentIntent i) {
    final json = _plain(i)..remove('clientSecret');
    return redact(json) as Map<String, Object?>;
  }

  static PaymentIntent readPaymentIntent(Object? json) =>
      PaymentIntent.fromJson({
        ...(json! as Map).cast<String, dynamic>(),
        'clientSecret': clientSecretPlaceholder,
      });

  /// The sheet's label of the selected method, with digits (the card's
  /// last four) replaced by zeros: `•••• 4242` is recorded as `•••• 0000`.
  static Map<String, Object?> paymentOption(PaymentSheetPaymentOption o) => {
    'label': o.label.replaceAll(RegExp(r'\d'), '0'),
    'image': o.image,
  };

  static Map<String, Object?> paymentMethod(PaymentMethod m) =>
      redact(_plain(m)) as Map<String, Object?>;

  /// Plain JSON of a model: some nested Stripe models are not converted by
  /// their own `toJson` (no `explicitToJson`), `jsonEncode` converts them.
  static Map<String, Object?> _plain(Object model) =>
      (jsonDecode(jsonEncode(model)) as Map).cast<String, Object?>();

  /// [redactedKeys] become `[REDACTED]`, `last4` becomes `0000`.
  static Object? redact(Object? json) {
    if (json is List) return [for (final v in json) redact(v)];
    if (json is! Map) return json;
    return <String, Object?>{
      for (final e in json.entries)
        '${e.key}': e.value == null
            ? null
            : e.key == 'last4'
            ? '0000'
            : redactedKeys.contains(e.key) && e.value is String
            ? Redactor.placeholder
            : redact(e.value),
    };
  }
}

/// The [StripePlatform.instance] [BugCapsuleStripe] installs.
class _BugCapsuleStripePlatform extends StripePlatform {
  _BugCapsuleStripePlatform(this._owner);

  final BugCapsuleStripe _owner;

  StripePlatform get _real => _owner.delegate;

  Future<T> _no<T>(String operation, Future<T> Function() real) =>
      _owner._unsupported(operation, real);

  // ------------------------------------------------ configuration & views

  @override
  bool get updateSettingsLazily =>
      _owner._replaying || _real.updateSettingsLazily;

  /// Configuration: forwarded while capturing, a no-op in replay (nothing
  /// may reach Stripe).
  @override
  Future<void> initialise({
    required String publishableKey,
    String? stripeAccountId,
    ThreeDSecureConfigurationParams? threeDSecureParams,
    String? merchantIdentifier,
    String? urlScheme,
    bool? setReturnUrlSchemeOnAndroid,
  }) async {
    if (_owner._replaying) return;
    return _real.initialise(
      publishableKey: publishableKey,
      stripeAccountId: stripeAccountId,
      threeDSecureParams: threeDSecureParams,
      merchantIdentifier: merchantIdentifier,
      urlScheme: urlScheme,
      setReturnUrlSchemeOnAndroid: setReturnUrlSchemeOnAndroid,
    );
  }

  @override
  void setConfirmHandler(ConfirmHandler? handler) {
    if (!_owner._replaying) _real.setConfirmHandler(handler);
  }

  @override
  void setConfirmTokenHandler(ConfirmTokenHandler? handler) {
    if (!_owner._replaying) _real.setConfirmTokenHandler(handler);
  }

  @override
  Widget buildCard({
    Key? key,
    required CardEditController controller,
    CardChangedCallback? onCardChanged,
    CardFocusCallback? onFocus,
    CardStyle? style,
    CardPlaceholder? placeholder,
    bool enablePostalCode = false,
    double? width,
    double? height,
    BoxConstraints? constraints,
    FocusNode? focusNode,
    bool autofocus = false,
    bool dangerouslyUpdateFullCardDetails = false,
  }) => _real.buildCard(
    key: key,
    controller: controller,
    onCardChanged: onCardChanged,
    onFocus: onFocus,
    style: style,
    placeholder: placeholder,
    enablePostalCode: enablePostalCode,
    width: width,
    height: height,
    constraints: constraints,
    focusNode: focusNode,
    autofocus: autofocus,
    dangerouslyUpdateFullCardDetails: dangerouslyUpdateFullCardDetails,
  );

  @override
  Widget buildPaymentRequestButton({
    Key? key,
    required VoidCallback onPressed,
    required PlatformPayWebPaymentRequestCreateOptions
    paymentRequestCreateOptions,
    BoxConstraints? constraints,
    PlatformButtonType? type,
    PlatformButtonStyle? style,
  }) => _real.buildPaymentRequestButton(
    key: key,
    onPressed: onPressed,
    paymentRequestCreateOptions: paymentRequestCreateOptions,
    constraints: constraints,
    type: type,
    style: style,
  );

  // ------------------------------------------------------------ recorded

  @override
  Future<PaymentSheetPaymentOption?> initPaymentSheet(
    SetupPaymentSheetParameters params,
  ) => _owner.initPaymentSheet(params);

  @override
  Future<PaymentSheetPaymentOption?> presentPaymentSheet({
    PaymentSheetPresentOptions? options,
  }) => _owner.presentPaymentSheet(options: options);

  @override
  Future<void> confirmPaymentSheetPayment() =>
      _owner.confirmPaymentSheetPayment();

  @override
  Future<PaymentIntent> confirmPayment(
    String paymentIntentClientSecret,
    PaymentMethodParams? params,
    PaymentMethodOptions? options,
  ) => _owner.confirmPayment(paymentIntentClientSecret, params, options);

  @override
  Future<PaymentMethod> createPaymentMethod(
    PaymentMethodParams data, [
    PaymentMethodOptions? options,
  ]) => _owner.createPaymentMethod(data, options);

  // --------------------------------------------------------- unsupported

  @override
  Future<PaymentIntent> handleNextAction(
    String paymentIntentClientSecret, {
    String? returnURL,
  }) => _no(
    'handleNextAction',
    () =>
        _real.handleNextAction(paymentIntentClientSecret, returnURL: returnURL),
  );

  @override
  Future<SetupIntent> handleNextActionForSetupIntent(
    String setupIntentClientSecret, {
    String? returnURL,
  }) => _no(
    'handleNextActionForSetupIntent',
    () => _real.handleNextActionForSetupIntent(
      setupIntentClientSecret,
      returnURL: returnURL,
    ),
  );

  @override
  Future<void> resetPaymentSheetCustomer() =>
      _no('resetPaymentSheetCustomer', _real.resetPaymentSheetCustomer);

  @override
  Future<void> initCustomerSheet(CustomerSheetInitParams params) =>
      _no('initCustomerSheet', () => _real.initCustomerSheet(params));

  @override
  Future<CustomerSheetResult?> presentCustomerSheet({
    CustomerSheetPresentParams? options,
  }) => _no(
    'presentCustomerSheet',
    () => _real.presentCustomerSheet(options: options),
  );

  @override
  Future<CustomerSheetResult?> retrieveCustomerSheetPaymentOptionSelection() =>
      _no(
        'retrieveCustomerSheetPaymentOptionSelection',
        _real.retrieveCustomerSheetPaymentOptionSelection,
      );

  @override
  Future<void> openApplePaySetup() =>
      _no('openApplePaySetup', _real.openApplePaySetup);

  @override
  Future<TokenData> createApplePayToken(Map<String, dynamic> payment) =>
      _no('createApplePayToken', () => _real.createApplePayToken(payment));

  @override
  Future<bool> handleURLCallback(String url) =>
      _no('handleURLCallback', () => _real.handleURLCallback(url));

  @override
  Future<void> initGooglePay(GooglePayInitParams params) =>
      _no('initGooglePay', () => _real.initGooglePay(params));

  @override
  Future<void> presentGooglePay(PresentGooglePayParams params) =>
      _no('presentGooglePay', () => _real.presentGooglePay(params));

  @override
  // ignore: deprecated_member_use
  Future<bool> googlePayIsSupported(IsGooglePaySupportedParams params) =>
      // ignore: deprecated_member_use
      _no('googlePayIsSupported', () => _real.googlePayIsSupported(params));

  @override
  Future<PaymentMethod> createGooglePayPaymentMethod(
    CreateGooglePayPaymentParams params,
  ) => _no(
    'createGooglePayPaymentMethod',
    () => _real.createGooglePayPaymentMethod(params),
  );

  @override
  // ignore: deprecated_member_use
  Future<AddToWalletResult> canAddToWallet(String last4) =>
      // ignore: deprecated_member_use
      _no('canAddToWallet', () => _real.canAddToWallet(last4));

  @override
  Future<CanAddCardToWalletResult> canAddCardToWallet(
    CanAddCardToWalletParams params,
  ) => _no('canAddCardToWallet', () => _real.canAddCardToWallet(params));

  @override
  Future<IsCardInWalletResult> isCardInWallet(String cardLastFour) =>
      _no('isCardInWallet', () => _real.isCardInWallet(cardLastFour));

  @override
  Future<bool> isPlatformPaySupported({
    IsGooglePaySupportedParams? params,
    PlatformPayWebPaymentRequestCreateOptions? paymentRequestOptions,
  }) => _no(
    'isPlatformPaySupported',
    () => _real.isPlatformPaySupported(
      params: params,
      paymentRequestOptions: paymentRequestOptions,
    ),
  );

  @override
  Future<SetupIntent> platformPayConfirmSetupIntent({
    required String clientSecret,
    required PlatformPayConfirmParams params,
  }) => _no(
    'platformPayConfirmSetupIntent',
    () => _real.platformPayConfirmSetupIntent(
      clientSecret: clientSecret,
      params: params,
    ),
  );

  @override
  Future<PaymentIntent> platformPayConfirmPaymentIntent({
    required String clientSecret,
    required PlatformPayConfirmParams params,
  }) => _no(
    'platformPayConfirmPaymentIntent',
    () => _real.platformPayConfirmPaymentIntent(
      clientSecret: clientSecret,
      params: params,
    ),
  );

  @override
  Future<PlatformPayPaymentMethod> platformPayCreatePaymentMethod({
    required PlatformPayPaymentMethodParams params,
    bool usesDeprecatedTokenFlow = false,
  }) => _no(
    'platformPayCreatePaymentMethod',
    () => _real.platformPayCreatePaymentMethod(
      params: params,
      usesDeprecatedTokenFlow: usesDeprecatedTokenFlow,
    ),
  );

  @override
  Future<void> updatePlatformSheet({
    required PlatformPaySheetUpdateParams params,
  }) => _no(
    'updatePlatformSheet',
    () => _real.updatePlatformSheet(params: params),
  );

  @override
  Future<void> configurePlatformOrderTracking({
    required PlatformPayOrderDetails orderDetails,
  }) => _no(
    'configurePlatformOrderTracking',
    () => _real.configurePlatformOrderTracking(orderDetails: orderDetails),
  );

  @override
  Future<TokenData> createToken(CreateTokenParams params) =>
      _no('createToken', () => _real.createToken(params));

  @override
  Future<SetupIntent> confirmSetupIntent(
    String setupIntentClientSecret,
    PaymentMethodParams data,
    PaymentMethodOptions? options,
  ) => _no(
    'confirmSetupIntent',
    () => _real.confirmSetupIntent(setupIntentClientSecret, data, options),
  );

  @override
  Future<PaymentIntent> retrievePaymentIntent(String clientSecret) => _no(
    'retrievePaymentIntent',
    () => _real.retrievePaymentIntent(clientSecret),
  );

  @override
  Future<SetupIntent> retrieveSetupIntent(String clientSecret) =>
      _no('retrieveSetupIntent', () => _real.retrieveSetupIntent(clientSecret));

  @override
  Future<String> createTokenForCVCUpdate(String cvc) =>
      _no('createTokenForCVCUpdate', () => _real.createTokenForCVCUpdate(cvc));

  @override
  Future<RadarSession> createRadarSession() =>
      _no('createRadarSession', _real.createRadarSession);

  @override
  Future<CollectBankAccountResult> collectBankAccount({
    required bool isPaymentIntent,
    required String clientSecret,
    required CollectBankAccountParams params,
  }) => _no(
    'collectBankAccount',
    () => _real.collectBankAccount(
      isPaymentIntent: isPaymentIntent,
      clientSecret: clientSecret,
      params: params,
    ),
  );

  @override
  Future<CollectBankAccountResult> verifyPaymentIntentWithMicrodeposits({
    required bool isPaymentIntent,
    required String clientSecret,
    required VerifyMicroDepositsParams params,
  }) => _no(
    'verifyPaymentIntentWithMicrodeposits',
    () => _real.verifyPaymentIntentWithMicrodeposits(
      isPaymentIntent: isPaymentIntent,
      clientSecret: clientSecret,
      params: params,
    ),
  );

  @override
  Future<FinancialConnectionTokenResult> collectBankAccountToken({
    required String clientSecret,
    required CollectBankAccountTokenParams params,
  }) => _no(
    'collectBankAccountToken',
    () => _real.collectBankAccountToken(
      clientSecret: clientSecret,
      params: params,
    ),
  );

  @override
  Future<FinancialConnectionSessionResult> collectFinancialConnectionsAccounts({
    required String clientSecret,
    CollectFinancialConnectionsAccountsParams? params =
        const CollectFinancialConnectionsAccountsParams(),
  }) => _no(
    'collectFinancialConnectionsAccounts',
    () => _real.collectFinancialConnectionsAccounts(
      clientSecret: clientSecret,
      params: params,
    ),
  );

  @override
  Future<void> dangerouslyUpdateCardDetails(CardDetails card) => _no(
    'dangerouslyUpdateCardDetails',
    () => _real.dangerouslyUpdateCardDetails(card),
  );

  @override
  Future<void> intentCreationCallback(IntentCreationCallbackParams params) =>
      _no('intentCreationCallback', () => _real.intentCreationCallback(params));

  @override
  Future<void> confirmationTokenCreationCallback(
    IntentCreationCallbackParams params,
  ) => _no(
    'confirmationTokenCreationCallback',
    () => _real.confirmationTokenCreationCallback(params),
  );

  @override
  Future<List<String>> pollAndClearPendingStripeConnectUrls() => _no(
    'pollAndClearPendingStripeConnectUrls',
    _real.pollAndClearPendingStripeConnectUrls,
  );
}
