# BugCapsule capsule format — v1

A `.bugcapsule` file is **gzip-compressed UTF-8 JSON**. The JSON document has three
top-level parts: the manifest (who/what/where), a checkpoint (the state replay
starts from), and an ordered event window (what happened after the checkpoint).

```json
{
  "format": "bugcapsule.capsule",
  "specVersion": 1,
  "manifest": { ... },
  "checkpoint": { ... },
  "events": [ ... ]
}
```

Readers MUST reject documents whose `format` is not `bugcapsule.capsule` and MUST
reject a `specVersion` greater than the one they implement.

Readers MUST ignore fields and event types they do not know (forward
compatibility); writers MUST NOT change the meaning of existing fields
within v1. See *Validation* for what a v1 reader checks.

## Time

All event times (`t`) are integer **milliseconds since the session anchor**.
The anchor is the first rendered frame of the app. Events that happen before
the first frame (startup network calls, storage reads) have negative `t`.

`manifest.session.wallClockAtAnchorMs` is the wall clock (epoch ms) at the
anchor. Replay maps `t` back to wall time with
`wallClockAtAnchorMs + t`, which is what the replay clock returns.

## Manifest

| Field | Type | Notes |
|---|---|---|
| `capsuleId` | string (UUID v4) | Globally unique, generated on device. Idempotency key for uploads. |
| `createdAt` | ISO-8601 string | When the capsule was written. |
| `mode` | `debug` \| `qa` \| `production` | Capture mode. |
| `app.id` | string? | Bundle / application id. |
| `app.version` | string | Marketing version. |
| `app.build` | string | Build number. |
| `app.flavor` | string? | Flavor / environment. |
| `source.gitSha` | string? | Exact source pin. Missing SHA makes the capsule `partial`. |
| `source.dirty` | bool? | True when built from an uncommitted tree. |
| `sdk.name`, `sdk.version` | string | Capture SDK identity. |
| `stateSchemaVersion` | int | App-declared version of its serialized state. |
| `platform.os` | string | `ios`, `android`, `macos`, ... |
| `platform.osVersion` | string | |
| `platform.locale` | string | |
| `platform.screen` | `{width, height, pixelRatio}` | Logical size; used to scale pointer replay. |
| `platform.dartVersion` | string | |
| `session.id` | string | |
| `session.startedAt` | ISO-8601 | |
| `session.wallClockAtAnchorMs` | int | See *Time*. |
| `session.seed` | int | Seed for `BugCapsule.random`. |
| `session.durationMs` | int | From anchor to capsule creation. |
| `failure` | object \| null | See below. Null for a manual capture with no assertion. |
| `eligibility.status` | `eligible` \| `partial` \| `ineligible` | Computed on device. |
| `eligibility.missing` | `[{dependency, reason, blocking?}]` | Every gap. `blocking: true` makes the capsule ineligible (e.g. no failure assertion); other gaps make it partial. |
| `integrations` | string[] | e.g. `["bloc","dio","go_router","shared_preferences"]`; also `riverpod`, `notifier`, `getx`, `mobx`, `http` (package:http) |
| `stats` | `{eventCount, droppedEvents, checkpointKind}` | |
| `labels` | map<string,string> | Free-form tags (QA note, ticket id, ...). Values are scrubbed like free text. |
| `redaction` | `{extraKeys: string[], extraHeaders: string[]}`? | Redaction rules used on top of the defaults (app config and remote config). Replay applies the same rules so request keys computed from redacted bodies match. Omitted when empty. |
| `monitoring` | `{eventId, traceId?, release?, environment?}`? | The monitoring `event` sent for the same failure ([monitoring-v1](https://github.com/draz26648/bug_capsule_backend/blob/main/docs/monitoring-v1.md) §4.3); the backend links the capsule to that event's issue. `eventId` ≤100, `traceId` ≤32, `release` ≤200, `environment` ≤64. Omitted when monitoring is off. |

### Failure

```json
{
  "kind": "exception | assertion | manual",
  "signature": "exception:StateError:Cart total is negative (#)",
  "type": "StateError",
  "message": "Bad state: Cart total is negative (-3)",
  "stack": "...",
  "assertionId": null,
  "t": 18234
}
```

`signature` is the comparison key used by replay and verify:
`<kind>:<type>:<normalized message>`, where the normalized message has digit
runs replaced by `#`, hex ids of 8+ chars replaced by `#`, and is cut to 200
characters. Stack traces are informative only (debug and release frames differ).

## Checkpoint

```json
{
  "kind": "launch | periodic",
  "t": -412,
  "wallClockMs": 1760870000000,
  "afterSeq": 0,
  "data": {
    "shared_preferences": { "onboarding_done": {"type": "bool", "value": true} },
    "go_router": { "location": "/cart" },
    "bloc": { "CartBloc#0": {"type": "CartBloc", "state": {...}, "stateType": "CartLoaded"} },
    "riverpod": { "cart#0": {"provider": "cart", "state": {...}, "stateType": "Cart"} },
    "notifier": { "auth#0": {"type": "AuthModel", "state": {...}} },
    "getx": { "cart.items#0": {"type": "RxList<CartItem>", "state": {...}} },
    "mobx": { "login#0": {"type": "LoginStore", "state": {...}} }
  }
}
```

* A **launch** checkpoint is taken before `runApp`. Replay from a launch
  checkpoint re-executes the whole session; only storage needs restoring.
  This is the most reliable kind and is used whenever the whole session fits
  in the event window.
* A **periodic** checkpoint (default every 30 s) additionally carries
  serialized BLoC states and the current route. It is used when the session
  is longer than the retained window.

`afterSeq` is the sequence number of the last event recorded before the
checkpoint; the capsule's events are exactly those with a greater `seq`.

Each key of `data` belongs to one integration; the integration that wrote it
is the only one that reads it.

## Events

```json
{ "seq": 41, "t": 1820, "type": "http", "data": { ... } }
```

`seq` is strictly increasing. Known types:

| Type | Data | Replayed? |
|---|---|---|
| `lifecycle` | `{state}` (`resumed`, `inactive`, `hidden`, `paused`, `detached`) | yes |
| `pointer` | `{phase: down\|move\|up\|cancel, pointer, x, y, kind, buttons}` (logical px) | yes |
| `action` | `{id, payload?}` semantic action | yes |
| `text` | `{id, value}` tracked text field | yes |
| `route` | `{location}` | no (diagnostic) |
| `bloc.create` / `bloc.close` | `{bloc, key}` | no |
| `bloc.event` | `{bloc, key, event, data?}` | no |
| `bloc.state` | `{bloc, key, state, data?}` | no |
| `bloc.error` | `{bloc, key, error}` | no |
| `riverpod.add` / `riverpod.update` | `{provider, key, state, data?}` (`state` is the value's type) | no |
| `riverpod.error` | `{provider, key, error}` | no |
| `riverpod.dispose` | `{provider, key}` | no |
| `notifier.create` / `getx.create` / `mobx.create` | `{type, key}` tracked object | no |
| `notifier.change` / `getx.change` / `mobx.change` | `{type, key, data?}` | no |
| `mobx.observable` | `{name, type, value?}` observable write (`value` only for primitives) | no |
| `mobx.action` | `{name}` | no |
| `mobx.error` | `{reaction, error}` | no |
| `http` | see below | served as fixture |
| `log` | `{level, message}` | no |
| `failure` | same shape as `manifest.failure` | no (it is the assertion) |

### `http`

```json
{
  "id": 7,
  "key": "GET /api/cart",
  "occurrence": 0,
  "method": "GET",
  "url": "https://api.example.com/api/cart?lang=en",
  "requestHeaders": {"accept": "application/json", "authorization": "[REDACTED]"},
  "requestBody": null,
  "status": 200,
  "responseHeaders": {"content-type": "application/json"},
  "responseBody": {"items": [...]},
  "requestEncoding": "json | text | form | base64 | omitted | truncated",
  "bodyEncoding": "json | text | form | base64 | omitted | truncated",
  "durationMs": 182,
  "error": null,
  "excluded": false
}
```

Every HTTP client integration (Dio, package:http) records this same shape
and computes the same key for the same request, so the fixture store does
not depend on the client. The event is recorded when the exchange completes: `t` is when the response
(or error) arrived, and the request was sent at `t - durationMs`.
`key` is the normalized request key (see *Network matching*); `occurrence` is
the 0-based count of earlier requests with the same key.

Bodies are never buffered whole: capture keeps a bounded prefix while the
bytes stream to the app. `omitted` means body capture was off (the exchange
is then recorded when the headers arrive) or the request was excluded by an
app rule (`excluded: true`, no headers either); `truncated` means the body was
larger than the capture limit, was still streaming after the wait limit, or
failed mid-stream (`error` set). A fixture without a body makes the capsule
`partial`, and replay reports `network.noBody` when it serves one.

## Network matching

A request key is `METHOD path?sortedQuery#bodyHash`, where endpoint rules can
drop query parameters and JSON body fields (timestamps, nonces, request ids)
before hashing, or restrict hashing to a set of match fields. The key uses the
redacted URL and body, and only bodies up to a fixed size (64 KiB by default,
independent of body capture) are hashed, so capture and replay compute the
same key whatever the capture settings. Multipart bodies are not hashed
(their boundary changes on every request). Replay serves the
fixture with the same key and occurrence, delayed by the recorded
`durationMs` so that response ordering (and therefore races) is preserved.

## Redaction

Redaction happens on device, before anything is written, and applies the
same way to events and to checkpoint data:

* **By name.** Values whose key matches the deny list are replaced with
  `[REDACTED]` anywhere in bodies, storage, BLoC / Riverpod / notifier / GetX / MobX state, action payloads,
  custom integration data and checkpoints. Names are normalized (lowercase,
  no `_` `-` `.` or spaces); `password`, `passwd`, `token`, `secret`,
  `apikey`, `authorization`, `cookie`, `cardnumber`, `creditcard`,
  `privatekey`, `sessionid` match as substrings; `pin`, `pan`, `otp`, `ssn`,
  `cvv`, `cvc`, `passcode`, `iban` match exactly; configured keys
  (`BugCapsuleConfig.redactKeys`, remote `redactKeys`) are added.
* **Headers.** `authorization`, `cookie`, `set-cookie`,
  `proxy-authorization`, `x-api-key`, `x-auth-token`, configured headers and
  any header whose name matches the deny list are replaced; other header
  values are scrubbed as free text.
* **URLs** (request URLs, route events and route checkpoints): user info is
  replaced, and query and fragment parameters whose name matches the deny
  list or `code`, `sig`, `key`, `auth`, `sid`, `session`, `*signature*`,
  `*credential*` are replaced.
* **Free text** (failure messages and stacks, logs, labels, tracked text,
  text bodies, every string value): bearer/basic tokens, JWTs, well-known API
  key formats, `key=value` / `key: value` / `"key": "value"` pairs with a
  sensitive key, Luhn-valid card numbers, and configured patterns
  (`BugCapsuleConfig.redactPatterns`). A string that holds a JSON object or array
  is redacted as JSON.
* Tracked text fields are replaced whole when their id matches the deny list
  or the app marks them `sensitive`.

Automatic redaction is best effort. It does not find: secrets in URL path
segments, personal data that is not a credential (names, emails, addresses,
free-form notes), secrets under innocuous key names that do not match a
pattern, binary bodies, or state an integration chose not to describe. Apps
close these gaps with `redactKeys`, `redactPatterns`, `beforeRecord` /
`beforeCheckpoint` hooks, integration options (`BugCapsuleDio.exclude`,
`BugCapsuleHttp.exclude`, `BugCapsuleGoRouter.sanitizeLocation`, storage
allow/deny prefixes, state-management serializers that project state), and by disabling body capture remotely.

Replay reports placeholders it has to replay as `text.redacted`,
`storage.redacted`, `route.redacted`, `bloc.unrestored`,
`riverpod.unrestored`, `notifier.unrestored`, `getx.unrestored` or
`mobx.unrestored` divergences. MobX observable writes are redacted by the
observable's field name (`_LoginStore.password`).

## Eligibility

The device computes eligibility when writing the capsule. `missing` explains
each gap, for example:

```json
[{"dependency": "build.gitSha", "reason": "BUGCAPSULE_GIT_SHA was not set at build time"},
 {"dependency": "failure.assertion", "reason": "manual capture without a failure assertion"}]
```

Ineligible capsules are still stored and inspectable; they are reported
separately and never counted in the reproduction rate.

## Validation

A v1 reader (the backend on upload, the SDK and CLI on decode) accepts a
document only if:

* `format`, `specVersion`, `manifest`, `checkpoint` and `events` are present
  with the types above;
* manifest: `capsuleId` (1-100 chars), `createdAt` (ISO-8601 with a time
  zone), `mode`, `app.version`, `app.build`, `platform.os`, `session` (`id`,
  `startedAt`, `wallClockAtAnchorMs`, `seed`, `durationMs`) and
  `eligibility.status` are present and typed; optional fields, when
  present, have their documented types (`failure.kind` and `signature` are
  required inside a failure);
* checkpoint: `kind`, `t`, `wallClockMs`; `afterSeq` >= 0 and `data` an
  object when present;
* events: each has integer `seq` (strictly increasing), integer `t`, a
  `type` (1-100 chars) and an object `data`; known types carry the fields
  replay reads (`http.key`, string `responseHeaders` values, `pointer`
  `phase`/`pointer`/`x`/`y`, `action.id`, `text.id`, `lifecycle.state`);
* bounds: at most 200,000 events, nesting depth 100, 100 labels, 100
  integrations, 500 eligibility entries, 4,000,000 JSON values in total
  (counted before parsing, since parse memory grows with the number of
  values); decompressed size at most min(10 × the project's
  `maxCapsuleBytes`, 64 MB) on upload.

Integers are JSON numbers without a fraction (`1`, not `1.0`). Errors name
the JSON path of the first problem, e.g. `$.events[3].data.key must be a
string`. Shared valid and invalid examples live in `spec/fixtures/capsule-v1`
(SDK repository) and `test/fixtures/capsule-v1` (backend), and both test
suites run them.
