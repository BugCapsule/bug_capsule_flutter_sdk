# BugCapsule for Stripe

A native SDK adapter for [BugCapsule](https://docs.bugcapsule.com/flutter.html)
that records payment outcomes at the `stripe_platform_interface` boundary
used by `flutter_stripe`. While capturing, the payment sheet and payment
calls work as usual and BugCapsule records what your app received: the
success value, or the `StripeException` with its `FailureCode` (`Canceled`,
`Failed`, `Timeout`) and messages. A bug in how your app handles a cancelled
sheet or a declined card comes back as it happened.

> **Replay substitute: the native sheet is not shown; the recorded outcome is
> returned.** Replay never presents Stripe UI and never contacts Stripe, so
> no real charge is possible. Client secrets, ephemeral keys and payment
> method details are never needed to replay.

## Install

```yaml
dependencies:
  bug_capsule: ^0.4.1-beta.6
  bug_capsule_stripe: ^0.1.0-dev.1
  flutter_stripe: ^14.2.0
```

```dart
import 'package:bug_capsule/bug_capsule.dart';
import 'package:bug_capsule_stripe/bug_capsule_stripe.dart';

Future<void> main() async {
  await BugCapsule.init(integrations: [BugCapsuleStripe() /*, ... */]);
  Stripe.publishableKey = 'pk_live_...'; // after BugCapsule.init
  runApp(const MyApp());
}
```

`Stripe.instance` is used unchanged. `BugCapsule.init` installs a delegating
`StripePlatform.instance`. Install it **before the app first touches
`Stripe`**, including `Stripe.publishableKey`: `flutter_stripe` keeps the
platform instance it sees first.

## Supported operations

| Operation | Recorded |
|---|---|
| `initPaymentSheet` | the selected `PaymentSheetPaymentOption` (custom flow) or `null` |
| `presentPaymentSheet` | the `PaymentSheetPaymentOption`, or the `StripeException` (e.g. `Canceled`) |
| `confirmPaymentSheetPayment` | success or the `StripeException` |
| `confirmPayment` | the `PaymentIntent` or the `StripeException` |
| `createPaymentMethod` | the `PaymentMethod` or the `StripeException` |

Errors are thrown again as `StripeException` with the recorded
`FailureCode`, `message`, `localizedMessage`, `stripeErrorCode`,
`declineCode` and `type`.

**What is never recorded:**

- Client secrets, ephemeral keys, customer session secrets and customer ids.
  `initPaymentSheet` records which kind of intent and customer were given
  (`payment`, `setup` or `deferred`; `ephemeralKey` or `session`) and the
  sheet's display settings. A different client secret in replay still
  matches.
- Payment method parameters: only the method type and which data fields were
  set.
- Payment details in results. Billing and shipping name, email, phone and
  address lines become `[REDACTED]` (the country is kept). `last4` becomes
  `0000`, and digits in the sheet's option label become zeros
  (`•••• 0000`). Fingerprints and bank codes are redacted.
  `PaymentIntent.clientSecret` is not recorded, and replay hands the app
  `PaymentRedaction.clientSecretPlaceholder`. Card brand, country, funding
  and expiry are kept.

**Configuration and views.** `initialise` reaches Stripe while capturing and
does nothing during replay. `setConfirmHandler` and `setConfirmTokenHandler`
work the same way. `buildCard` and `buildPaymentRequestButton` always render
the real platform view.

**Unsupported operations** (Customer Sheet, Google Pay and Apple Pay /
platform pay, `handleNextAction`, `confirmSetupIntent`, `retrievePaymentIntent`,
tokens, bank accounts, Financial Connections and the rest of
`StripePlatform`) reach Stripe while capturing and add an
`operation.unsupported` gap naming the operation. During replay they fail
with a `NativeAdapterException` (`bugcapsule.unsupported`) and a
`native.unrecorded` divergence. They never reach Stripe.

An operation the capsule does not contain fails the same way, with
`bugcapsule.unrecorded`.

## Tested versions

| Package | Version |
|---|---|
| `stripe_platform_interface` | 14.2.0 |

Tested with Flutter 3.47.8 against a scripted `StripePlatform`, following
the call path of `flutter_stripe` 14.2.0. Not yet tested on a device with
`stripe_android` or `stripe_ios`.

## Limits

- Replay does not show the payment sheet, 3-D Secure or any other Stripe UI.
  The recorded outcome is returned after the recorded delay.
- Webhooks and your backend's view of the payment are not part of this
  adapter. Your backend's responses replay through BugCapsule's HTTP capture.
- `Stripe` must not be used before `BugCapsule.init` (see above).
- The usual capture bounds apply: 64 KiB per payload, 1 MiB of interaction
  payloads per capsule.
- The project's capture settings can turn off the adapter
  (`bug_capsule.flutter_stripe`) without touching other capture.

## License

MIT. See [LICENSE](LICENSE).
