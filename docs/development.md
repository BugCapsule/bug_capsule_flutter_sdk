# Working on the Flutter SDK

For maintainers of this repository. App developers want the
[README](../README.md) instead.

## Build and test

```bash
flutter pub get                                  # pub workspace: the package and the demo app
(cd packages/bug_capsule && flutter test)        # core, CLI, runtime and every integration
(cd example/bug_capsule_demo && flutter test)
(cd packages/bug_capsule && dart run bugcapsule --help)
dart pub global activate --source path packages/bug_capsule   # the CLI from this checkout
```

## Shared specs and fixtures

This repository owns the cross-SDK specs in `spec/`:

- `spec/capsule-v1.md`: the capsule format.
- `spec/runtimes-v1.md`: the runtime contracts the CLI uses.
- `spec/connection-token-v1.md` and `spec/fixtures/connection-token-v1/vectors.json`:
  the SDK token format and the test vectors every BugCapsule SDK passes.
- `spec/fixtures/capsule-v1`: valid and malformed capsules every SDK tests
  against.

The Android, iOS and web SDKs keep a copy in their `spec-fixtures/` folder and
fail their tests when it differs. After changing fixtures here, run
`tool/sync_spec.sh` with the other repositories checked out next to this one.

## Release

Release builds, real-device checks and the overhead budget:
[release-and-device-test-plan.md](release-and-device-test-plan.md).
Validation evidence for past releases: [release-readiness.md](release-readiness.md).
