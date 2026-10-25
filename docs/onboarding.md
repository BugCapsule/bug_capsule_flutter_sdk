# Onboarding: from a new project to a verified fix

A reproducible path using the demo app (`example/bug_capsule_demo`) and a local
backend. About 30 minutes on a Mac with Xcode, Flutter 3.35+, Node 22+ and
PostgreSQL 13+. The same steps apply to a pilot app; the differences are
listed at the end.

## 1. Backend and project

```bash
git clone <bug_capsule_backend> && cd bug_capsule_backend
npm install
createdb bugcapsule
cp .env.example .env               # set ADMIN_TOKEN (openssl rand -hex 32)
npm run migrate
npm run config:check               # configuration, database, storage
npm run project:create -- --name "Shop demo"   # prints ingest + secret keys (once)
npm run dev                        # http://127.0.0.1:8787; /ready answers 200
```

## 2. CLI

```bash
cd ../bug_capsule_flutter_sdk
flutter pub get
dart pub global activate --source path packages/bug_capsule
bugcapsule login --url http://127.0.0.1:8787 --secret-key bcs_... --ingest-key bci_...
```

## 3. First capture

Boot an iOS simulator, then:

```bash
cd example/bug_capsule_demo
flutter run -d <simulator> \
  --dart-define=BUGCAPSULE_GIT_SHA=$(git rev-parse HEAD) \
  --dart-define=BUGCAPSULE_TOKEN=bcsdk.v1....    # the SDK token from the dashboard
```

The SDK token carries the API URL and an upload-only credential. Without a
token (an older backend, or an ingest key you already have), pass
`--dart-define=BUGCAPSULE_BACKEND_URL=http://127.0.0.1:8787` and
`--dart-define=BUGCAPSULE_INGEST_KEY=bci_...` instead.

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

## For a pilot app

* Production host: the backend from `bug_capsule_backend/DEPLOY.md`; the API host is
  compiled into the app, so fix it before the first pilot build.
* Integrate per the README (about 20 lines), and register `BugCapsule.action` ids
  for the flows QA tests most.
* Build QA builds with `BUGCAPSULE_MODE=qa` and `BUGCAPSULE_GIT_SHA`; keep production
  capture off until the release checklist in
  [release-and-device-test-plan.md](release-and-device-test-plan.md) passes.
* Before the first upload from a real user: review redaction with a real login
  and payment flow, set `redactKeys` / `redactPatterns` / `exclude` rules, and
  read `bug_capsule_backend/docs/data-lifecycle.md` with the customer.
* Measure: time from project creation to first `REPRODUCED` (target under one
  hour with our help), and keep the numbers.
