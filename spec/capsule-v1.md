# Repro capsule format — v1

A `.repro` file is **gzip-compressed UTF-8 JSON**. The JSON document has three
top-level parts: the manifest (who/what/where), a checkpoint (the state replay
starts from), and an ordered event window (what happened after the checkpoint).

```json
{
  "format": "repro.capsule",
  "specVersion": 1,
  "manifest": { ... },
  "checkpoint": { ... },
  "events": [ ... ]
}
```

Readers MUST reject documents whose `format` is not `repro.capsule` and MUST
reject a `specVersion` greater than the one they implement.

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
| `session.seed` | int | Seed for `Repro.random`. |
| `session.durationMs` | int | From anchor to capsule creation. |
| `failure` | object \| null | See below. Null for a manual capture with no assertion. |
| `eligibility.status` | `eligible` \| `partial` \| `ineligible` | Computed on device. |
| `eligibility.missing` | `[{dependency, reason, blocking?}]` | Every gap. `blocking: true` makes the capsule ineligible (e.g. no failure assertion); other gaps make it partial. |
| `integrations` | string[] | e.g. `["bloc","dio","go_router","shared_preferences"]` |
| `stats` | `{eventCount, droppedEvents, checkpointKind}` | |
| `labels` | map<string,string> | Free-form tags (QA note, ticket id, ...). |

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
    "bloc": { "CartBloc#0": {"type": "CartBloc", "state": {...}, "stateType": "CartLoaded"} }
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
  "bodyEncoding": "json | text | base64 | omitted | truncated",
  "durationMs": 182,
  "error": null
}
```

The event is recorded when the exchange completes: `t` is when the response
(or error) arrived, and the request was sent at `t - durationMs`.
`key` is the normalized request key (see *Network matching*); `occurrence` is
the 0-based count of earlier requests with the same key.

## Network matching

A request key is `METHOD path?sortedQuery#bodyHash`, where endpoint rules can
drop query parameters and JSON body fields (timestamps, nonces, request ids)
before hashing, or restrict hashing to a set of match fields. Replay serves the
fixture with the same key and occurrence, delayed by the recorded
`durationMs` so that response ordering (and therefore races) is preserved.

## Redaction

Redaction happens on device, before anything is written:

* Headers: `authorization`, `cookie`, `set-cookie`, `proxy-authorization`,
  `x-api-key` and any configured header are replaced with `[REDACTED]`.
* JSON keys anywhere in bodies, storage values and BLoC state whose
  normalized name (lowercase, no `_` / `-`) matches the deny list
  (`password`, `token`, `accesstoken`, `refreshtoken`, `secret`, `otp`,
  `pin`, `cvv`, `cardnumber`, `pan`, `ssn`, `apikey`, `authorization`,
  `cookie`, plus configured keys) have their values replaced.
* Query parameters with deny-listed names are replaced.

## Eligibility

The device computes eligibility when writing the capsule. `missing` explains
each gap, for example:

```json
[{"dependency": "build.gitSha", "reason": "REPRO_GIT_SHA was not set at build time"},
 {"dependency": "failure.assertion", "reason": "manual capture without a failure assertion"}]
```

Ineligible capsules are still stored and inspectable; they are reported
separately and never counted in the reproduction rate.
