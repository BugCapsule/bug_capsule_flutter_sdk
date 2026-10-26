/// BugCapsule native SDK adapter for payments (capsule-v2 `native`):
/// [BugCapsuleStripe] records payment sheet and payment outcomes at the
/// `stripe_platform_interface` boundary (`flutter_stripe`).
///
/// Replay substitute: the native sheet is not shown; the recorded outcome
/// is returned. Replay never contacts Stripe, so no real charge is
/// possible, and no client secret or payment detail is needed.
///
/// ```dart
/// await BugCapsule.init(integrations: [BugCapsuleStripe(), ...]);
/// Stripe.publishableKey = 'pk_live_...'; // after BugCapsule.init
/// ```
library;

export 'src/stripe.dart';
