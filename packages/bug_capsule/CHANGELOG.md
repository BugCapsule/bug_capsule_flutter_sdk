## 0.4.1-beta.3 — 2026-10-25

- License the Flutter SDK and bundled CLI under the MIT License.
- Apply the Dart formatter to the package sources, tests, and tools.

- Shorten the package description to meet pub.dev's metadata requirements.
- Include a Flutter example in the published package with initialization,
  navigation monitoring, and manual capsule capture.

## 0.4.1-beta.2 — 2026-10-25

- Publish the full developer README on pub.dev and check it matches the repository README.
- Wait for queued outbox operations during shutdown, including token-rejection cleanup.

- Single-token setup: `BugCapsuleConfig(token: 'bcsdk.v1.…')` with the SDK token from the dashboard; `appVersion` / `appBuild` are optional. `parseConnectionToken` parses tokens offline (connection token v1, shared test vectors). An explicit `backend` keeps working and wins over a token.
- `BugCapsule.status`: connection state (`connected`, `offline`, `rejected`, `invalid_token`, …), the backend's refusal reason, configuration-fetched and first-data confirmations, and which replay instrumentation is still missing.
- A refused credential (revoked, expired or unknown token) is logged once with the backend's explanation and stops capture and uploads for the session.

## 0.4.1-beta.1

- Public beta packaging of the validated 0.4.0 SDK and multi-runtime CLI.
- Updated package repository metadata and prerelease version.

## 0.4.0

- Unify the Flutter integrations and multi-runtime replay CLI in `bug_capsule`.
- Add monitoring, offline outbox, remote configuration and replay validation.
- Test kill-switch cancellation at a deterministic encoding boundary.
- Find Android adb from SDK paths when the replay CLI runs outside a configured PATH.

- Apply the Bug Capsule Proprietary License to the package and CLI; prior written permission is required for use or distribution.
