# Onboarding: from a new project to a verified fix

A step-by-step path with the demo app (`example/bug_capsule_demo`). About 30
minutes on a Mac with Xcode and Flutter 3.35+. The same steps apply to your
own app; the differences are listed at the end.

## 1. Project and tokens

1. Sign in at [app.bugcapsule.com](https://app.bugcapsule.com) and create a
   project.
2. Generate an **SDK token** (`bcsdk.v1.…`) in **Project settings → Keys → SDK
   tokens**. It is shown once.
3. Create a **personal CLI token** (`bcp_…`) in **Project settings → Keys & CLI
   access**.

## 2. CLI

```bash
dart pub global activate bug_capsule 0.4.1-beta.1
bugcapsule login --url https://api.bugcapsule.com --token bcp_…
```

## 3. First capture

Boot an iOS simulator, then:

```bash
cd example/bug_capsule_demo
flutter run -d <simulator> \
  --dart-define=BUGCAPSULE_GIT_SHA=$(git rev-parse HEAD) \
  --dart-define=BUGCAPSULE_TOKEN=bcsdk.v1.…
```

On SDK versions without token support, pass
`--dart-define=BUGCAPSULE_BACKEND_URL=https://api.bugcapsule.com` and
`--dart-define=BUGCAPSULE_INGEST_KEY=bci_…` instead.

Trigger the negative-total bug: open the cart until the subtotal is below
$100, type `SAVE100`, apply. The app raises `cart_total_non_negative`, writes
a capsule and uploads it. The upload waits for the first successful config
fetch, so give it a second.

```bash
bugcapsule list                      # the capsule, status new, eligibility eligible
bugcapsule inspect <id>              # failure, eligibility, network, timeline
```

Check the capsule for anything that should not be there before going further
(`bugcapsule inspect <id> --json | less`).

## 4. First replay

```bash
bugcapsule run <id> -d <simulator> -n 3
```

Expected: `REPRODUCED 3/3`, exit 0, and the capsule status becomes
`reproduced`. `INCONCLUSIVE` lists why (for example an action id that is not
registered on the replayed build); fix that, then run again.

## 5. Fix and verify

Fix the bug in `lib/shop.dart` (clamp the coupon discount to the subtotal),
then:

```bash
bugcapsule verify <id> -d <simulator> -n 5
```

Expected: `FIXED — failure gone in 5/5 valid runs`, exit 0, capsule status
`fixed`. Anything less than every requested attempt running validly is
`INCONCLUSIVE` (exit 3) and does not change the status.

```bash
bugcapsule regress add <id> --name "coupon over subtotal"
bugcapsule regress run -d <simulator>   # for CI
```

## For your own app

- Integrate per the [README](../README.md) (about 20 lines), and register
  `BugCapsule.action` ids for the flows QA tests most.
- Build QA builds with `BUGCAPSULE_MODE=qa` and `BUGCAPSULE_GIT_SHA`; keep
  production capture off until the
  [production checklist](https://docs.bugcapsule.com/production.html) passes.
- Before the first upload from a real user, review redaction with a real login
  and payment flow, and set `redactKeys` / `redactPatterns` / `exclude` rules.
  See [Privacy and redaction](https://docs.bugcapsule.com/privacy.html).
