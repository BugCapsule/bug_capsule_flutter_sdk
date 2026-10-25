# SDK connection token (v1)

One string an app needs to connect to BugCapsule. It replaces typing a
backend URL, a project ID and an ingest key:

```ts
await BugCapsule.init({ token: 'bcsdk.v1.eyJhcGkiOi…' });
```

The token is **client-visible**: it ships inside apps and web bundles. It
grants exactly what an ingest key grants — fetch the project's SDK config,
upload Capsules, send monitoring envelopes — and nothing else. It never reads
data, never changes settings and never reaches the console.

## Format

```
bcsdk.v<version>.<payload>
```

- `bcsdk.` — fixed prefix. Anything else is not a connection token.
- `v<version>` — decimal contract version. This document is version `1`.
  SDKs refuse other versions with `unsupported_token_version` (an older SDK
  meeting a newer token says so instead of guessing).
- `<payload>` — base64url (RFC 4648 §5) of UTF-8 JSON, **without** padding.
  Decoders must accept a payload without padding and may accept padding.

Payload (version 1):

| Field | Type | Rule |
|---|---|---|
| `api` | string | Absolute `http` or `https` URL of the BugCapsule API. No user info, query or fragment. May have a path prefix (self-hosted behind a path). Trailing slashes are removed. |
| `key` | string | The ingest credential: `bct_` (SDK token) or `bci_` (legacy ingest key) followed by 16–200 base64url characters. A `bcs_` secret key is always refused. |

Unknown fields are ignored, so v1 can gain optional fields without a new
version. Whitespace around the whole token is trimmed.

The project is **not** in the token. The backend derives the project from the
credential on every request, so a token can't be pointed at another project by
editing it.

Hosted tokens carry `https://api.bugcapsule.com`. Self-hosted backends put
their own public API URL there, so the same SDK code works for both.

## What an SDK does with a token

1. Parse offline. On failure, log one actionable line (`[bugcapsule] …`),
   expose the error code through the SDK's status API and run the app without
   a backend. Never throw out of `init`, never block start-up.
2. Use `api` and `key` exactly like the existing backend configuration
   (`url` + `ingestKey`): `GET {api}/v1/sdk/config`, `POST {api}/v1/capsules`,
   `POST {api}/v1/envelope`, each with `Authorization: Bearer {key}`.
3. Fetch the remote config in the background. Until it arrives, defaults and
   the cached config apply. Offline: keep capsules and envelopes in the
   existing bounded outbox, retry with the existing backoff.
4. Interpret refusals (below) and stop sending with a revoked credential.

Passing both `token` and an explicit backend URL / ingest key is a
configuration error: the explicit backend wins and the SDK logs that the
token was ignored. Existing apps that pass `url` + `ingestKey` are unchanged.

## Error codes

Offline (SDK, from parsing):

| Code | When |
|---|---|
| `invalid_token` | Empty, wrong prefix, an ingest/secret key pasted instead of a token, payload not base64url/JSON/object, missing or invalid `api`/`key`. |
| `unsupported_token_version` | `bcsdk.vN.` with N ≠ 1. Update the SDK or generate a v1 token. |

Online (backend answer to any ingest route, `401` problem with a `reason`):

| `reason` | Meaning | SDK behaviour |
|---|---|---|
| `token_revoked` | Someone revoked the token in the dashboard. | Stop capture and uploads for this run; log once. |
| `token_expired` | Replaced by rotation; its grace period ended. | Same. |
| `token_unknown` | No such credential (typo, other backend, deleted project). | Same. |
| `key_unknown_or_revoked` | A legacy `bci_` key that isn't active. | Same (existing behaviour). |

Network failures and 5xx are never fatal: the app keeps running, data waits
in the outbox, the SDK retries with backoff, and its status says `offline`.

## Connection confirmation

Two separate observations, shown separately in onboarding and in the token
list:

1. **Configuration fetched** — the SDK reached the backend with a valid
   credential (`last_config_at`). Proves URL, credential and network.
2. **First event / Capsule received** — the SDK sent data the backend stored
   (`first_event_at`, `first_capsule_at`). Proves capture works end to end.

Neither proves complete replay instrumentation (network, navigation and
app-state adapters). Those remain progressive setup steps per framework, and
Capsule eligibility reports what is missing.

## Test vectors

`spec/fixtures/connection-token-v1/vectors.json` (the same file is
`spec-fixtures/connection-token-v1/vectors.json` in the other SDK repositories) lists valid tokens with their
expected `url` + `ingestKey` and invalid tokens with their error code. Every
SDK runs all of them.
