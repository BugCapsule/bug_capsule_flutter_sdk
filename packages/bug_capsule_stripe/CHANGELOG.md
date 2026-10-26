## 0.1.0-dev.1

- Pilot release. `BugCapsuleStripe` (`bug_capsule.flutter_stripe`) installs a delegating `StripePlatform.instance` and records the outcome of `initPaymentSheet`, `presentPaymentSheet`, `confirmPaymentSheetPayment`, `confirmPayment` and `createPaymentMethod`, including `StripeException` failure codes. Replay substitute: the native sheet is not shown; the recorded outcome is returned. Client secrets, ephemeral keys and payment details are never recorded.
