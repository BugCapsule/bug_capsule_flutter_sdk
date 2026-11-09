## 0.1.0-dev.2 — 2026-11-09

- Harden HTTP delivery, signed keyring invalidation and receipt acknowledgement.
- Embed engine 84e0431, including safe BASE fallback on activation journal failure.
- Verified real SDK crash-triggered signed rollback on Android and iOS simulators.

## 0.1.0-dev.1

- First hosted prerelease of the signed module/surface patch runtime for Android and iOS.
- Bundle native JNI libraries and an iOS device/simulator XCFramework; no native runtime download during application execution.
- Provide authenticated HTTP update/receipt transport, signed authorization, rollback, and capture/replay integration with bug_capsule.
