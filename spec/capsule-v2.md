# BugCapsule capsule format — v2 (interaction dependencies)

v2 extends [capsule-v1](capsule-v1.md) with **replay dependencies**:
bidirectional connections (WebSockets), Flutter platform channel traffic
and operations of third-party native SDKs (Firebase, maps, location,
payments). Everything v1 says still holds unless this document changes it.

A capsule is written as v2 only when it contains at least one interaction
dependency. Sessions that use only v1 features are still written as v1, so
v1-only tooling keeps working for them.

```json
{
  "format": "bugcapsule.capsule",
  "specVersion": 2,
  "manifest": { ..., "dependencies": [ ... ] },
  "checkpoint": { ... },
  "events": [ ... ]
}
```

## 1. Compatibility

* A v2 reader reads v1 and v2. A v1 reader rejects v2 through its
  `specVersion` check (v1: "MUST reject a `specVersion` greater than the one
  they implement"). This is the only safe signal: v1 readers ignore unknown
  fields and event types, so an additive v1 event could not make a
  dependency required.
* Readers MUST reject a `specVersion` greater than 2.
* A v2 document without `manifest.dependencies` is invalid. A v1 document
  may carry the field; v1 readers ignore it and v2 readers ignore it too
  (it has no effect on a v1 capsule).
* Tools never down-convert a v2 capsule into v1 by dropping events.
* Writers are deployed after readers: backend, CLI, dashboard and every SDK
  reader accept v2 before any SDK writes it.

## 2. Dependencies

`manifest.dependencies` lists each interaction source the capsule needs.

```json
{
  "id": "ws",
  "kind": "websocket",
  "adapter": "bug_capsule.web_socket_channel",
  "adapterVersion": "0.5.0",
  "schema": 1,
  "required": true,
  "coverage": "complete",
  "operations": ["connect", "send", "close"],
  "tested": [{"package": "web_socket_channel", "version": "3.0.3"}],
  "gaps": [{"code": "payload.binaryMetadata", "count": 2, "detail": "binary frames recorded as metadata"}],
  "stats": {"events": 41, "payloadBytes": 18234, "dropped": 0, "truncated": 0}
}
```

| Field | Type | Notes |
|---|---|---|
| `id` | string 1–100 | Unique in the capsule. Interaction events name it in `data.dep`. |
| `kind` | `websocket` \| `platform.channel` \| `native` | Event family (§4). Other values are allowed and mean a kind this reader does not know. |
| `adapter` | string 1–200 | Adapter identity, e.g. `bug_capsule.web_socket_channel`, `bug_capsule.platform_channels`, `bug_capsule.firebase_auth`, `bugcapsule-okhttp.websocket`. |
| `adapterVersion` | string 1–100 | Version of the adapter that recorded it. |
| `schema` | int ≥ 1 | Version of the event payloads of this adapter. A replaying adapter supports a range. |
| `required` | bool | `true`: replay cannot be faithful without this adapter. `false`: diagnostic capture only, never served during replay. |
| `coverage` | `complete` \| `partial` \| `diagnostic` | `partial` when `gaps` is not empty; `diagnostic` for capture-only adapters (`required: false`). |
| `operations` | string[]? (≤ 100) | Operations the adapter recorded. Informative. |
| `tested` | `[{package, version}]`? (≤ 20) | Package versions the adapter was qualified against. Informative. |
| `gaps` | `[{code, count?, detail?}]`? (≤ 100) | Why coverage is partial (§7). |
| `stats` | `{events?, payloadBytes?, dropped?, truncated?}`? | Integers ≥ 0. |

At most 100 dependencies.

### Preflight

Before the app under replay starts, the replaying SDK checks every
dependency with `required: true`:

* an adapter with the same `adapter` id is installed, and
* it supports the dependency's `schema`, and
* the checkpoint's open interactions can be restored (§6).

Any failure ends the attempt with outcome `incompatible` and a message
naming the dependency (`dependency.unsupported`, `dependency.schema`,
`dependency.unrestorable`). `bugcapsule inspect` shows the same list and the
adapter versions it needs. Dependencies with `required: false` never block.

## 3. Payloads

Every value an interaction carries (message bodies, call arguments,
results, error details, events) is a **payload object**:

```json
{"mode": "full", "replayable": true, "value": {"price": 12.5}, "bytes": 15}
```

| Field | Type | Notes |
|---|---|---|
| `mode` | `full` \| `redacted` \| `metadata` \| `omitted` \| `truncated` | How the value was recorded. |
| `replayable` | bool | Whether replay can hand the app this value. Only `full` and `redacted` payloads may be replayable. `redacted` payloads are replayable only when the adapter declares the redacted fields safe to replay (placeholders where the app does not branch on the value); otherwise `false`. |
| `value` | typed value (§3.1) | Present when `replayable`. May also be present for a non-replayable payload as a diagnostic preview (`truncated` prefix). |
| `bytes` | int ≥ 0? | Size of the original value (UTF-8 bytes for text, byte length for binary, encoded JSON size otherwise). |
| `kind` | `text` \| `binary` \| `value`? | WebSocket frames: `text` or `binary`. Defaults to `value`. |

`metadata` keeps only `bytes`/`kind`; `omitted` keeps nothing (an app rule
excluded it or capture of this payload kind is off); `truncated` means the
value exceeded the payload limit (§7). A serving replay that meets a
non-replayable payload reports `<family>.noPayload` (material).

Unsanitized hashes are never stored as a substitute for redaction: match
keys (§5) are computed from redacted values only.

### 3.1 Typed values

JSON alone would change values (integers vs doubles, byte arrays, non-string
map keys). A typed value is plain JSON except for these tagged objects,
recognised by a `$t` key:

| Dart / platform value | Encoding |
|---|---|
| `null`, `bool`, `String` | as JSON |
| integer, \|n\| ≤ 2^53 − 1 | JSON integer |
| other integer (64-bit) | `{"$t": "int", "v": "<decimal>"}` |
| double with a fraction | JSON number |
| double without a fraction, NaN, ±Infinity, -0.0 | `{"$t": "double", "v": "<Dart toString>"}` (`"1.0"`, `"NaN"`, `"Infinity"`, `"-Infinity"`, `"-0.0"`) |
| byte array (`Uint8List`, `ByteBuffer`, `Data`, `ArrayBuffer`) | `{"$t": "bytes", "b64": "<base64>"}` |
| `Int32List` / `Int64List` / `Float32List` / `Float64List` | `{"$t": "i32" \| "i64" \| "f32" \| "f64", "v": [...]}`; `i64` items and non-finite floats as decimal strings |
| list | JSON array of typed values |
| map whose keys are all strings, none equal to `$t` | JSON object of typed values |
| any other map | `{"$t": "map", "e": [[key, value], ...]}` (typed key and value, insertion order) |
| a value this encoder cannot represent | `{"$t": "unsupported", "type": "<runtime type>"}` (makes the payload non-replayable) |

Readers that do not need the values (backend, dashboard) treat typed values
as opaque JSON.

## 4. Event families

All interaction events keep the v1 envelope (`seq`, `t`, `type`, `data`)
and carry `data.dep`, the dependency id. Each event is **outbound** (the app
asks the dependency for something) or **inbound** (the dependency tells the
app something). Replay consumes outbound events as expectations and delivers
inbound events as recorded results (§5).

### 4.1 WebSocket (`kind: websocket`)

| Type | Direction | Data |
|---|---|---|
| `ws.connect` | out | `conn` (logical connection id, unique per capsule), `url` (redacted), `key` (match key: redacted URL without query values the rules ignore), `occurrence` (0-based count of earlier connects with the same key), `attempt` (0-based reconnect attempt for that key, as seen by the adapter), `protocols?` (string[]) |
| `ws.open` | in | `conn`, `protocol?`, `extensions?` |
| `ws.send` | out | `conn`, `index` (0-based per connection), `payload` (`kind` `text` or `binary`) |
| `ws.message` | in | `conn`, `index` (0-based per connection), `payload` |
| `ws.error` | in | `conn`, `phase` (`connect` \| `send` \| `stream`), `error` `{type, message}` |
| `ws.close` | out when `initiator` is `client`, else in | `conn`, `initiator` (`client` \| `server` \| `unknown`), `code?` (int), `reason?` (string) |

`ws.close` from the client records the close the app requested; the close
that completes the handshake afterwards is a second `ws.close` with
`initiator: server` or `unknown`. Ping/pong and frame-level details are not
recorded unless an adapter documents them.

### 4.2 Platform channels (`kind: platform.channel`)

| Type | Direction | Data |
|---|---|---|
| `platform.call` | out when `dir` is `dart`, in when `platform` | `channel`, `codec` (`standard.method`, `json.method`, `standard.message`, `json.message`, `string.message`, `binary.message` or a custom id), `call` (call id, unique per capsule), `dir` (`dart` = app to platform, `platform` = platform to app), `method?` (method calls only), `args` (payload), `key`, `occurrence`, `isolate?` (`root` by default), `engine?` |
| `platform.result` | in for `dir: dart`, out for `dir: platform` | `channel`, `call`, `value` (payload); a `null` result is a payload with value `null` |
| `platform.error` | like `platform.result` | `channel`, `call`, `kind` (`platform` = an error envelope, `missing` = no handler on the other side, `exception` = the handler threw), `code?`, `message?`, `details?` (payload) |
| `platform.listen` | out | `channel`, `codec`, `sub` (subscription id, unique per capsule), `gen` (0-based count of earlier subscriptions on that channel), `args` (payload), `key`, `occurrence`, `call?` (id of the listen call: its answer is a `platform.result` or `platform.error` with this `call`, because a failed listen is what the app sees) |
| `platform.event` | in | `channel`, `sub`, `index` (0-based per subscription), `value` (payload) or `error` `{code, message?, details?}` |
| `platform.cancel` | out | `channel`, `sub` |
| `platform.done` | in | `channel`, `sub` |

A null result, a missing handler (`platform.error` with `kind: missing`), a
thrown error, stream completion and cancellation are distinct events.
BugCapsule's own control traffic and framework channels (`flutter/*`) are
never recorded unless an adapter qualifies them.

### 4.3 Native adapters (`kind: native`)

| Type | Direction | Data |
|---|---|---|
| `native.call` | out | `op` (operation id, unique per capsule), `operation` (name, e.g. `firestore.get`), `instance?` (adapter instance id), `parent?` (id of an enclosing interaction), `args` (payload), `key`, `occurrence` |
| `native.result` | in | `op`, `value` (payload) |
| `native.error` | in | `op` or `sub`, `code`, `message?`, `details?` (payload) |
| `native.subscribe` | out | `sub`, `operation`, `instance?`, `parent?`, `args`, `key`, `occurrence` |
| `native.event` | in | `sub`, `index`, `value` (payload) |
| `native.cancel` | out | `sub` |
| `native.done` | in | `sub` |

Native-adapter events are dependency simulations: they reproduce what the
app saw (a Firestore snapshot, a location fix, a payment-sheet outcome),
never the native rendering or the provider's internal behaviour.

### 4.4 Recording boundary

An interaction is recorded at one boundary. When a native adapter uses a
captured channel or socket internally, the lower-level events are either
suppressed or recorded with `"diagnostic": true` in `data`; replay never
serves diagnostic events, so a callback is never delivered twice.

## 5. Replay semantics

### Matching outbound operations

Each outbound event has a **scope** and a **match key**:

| Event | Scope | Matched by |
|---|---|---|
| `ws.connect` | — | `key` + `occurrence` |
| `ws.send`, client `ws.close` | the connection | `index` order within the connection; the payload is compared |
| `platform.call` (`dir: dart`) | the channel | `key` + `occurrence` |
| `platform.listen` | the channel | `key` + `occurrence` |
| `platform.cancel` | the subscription | — |
| `native.call`, `native.subscribe` | the adapter instance | `key` + `occurrence` |
| `native.cancel` | the subscription | — |

`key` is `<scope>|<method?>|<hash of the redacted, normalized arguments>`,
where the scope is the channel, the WebSocket match URL, or the operation
name (`<operation>@<instance>` when a native call names an adapter instance)
(the HTTP request-key hash: two 32-bit FNV-1a passes with offsets
`0x811C9DC5` and `0x050C5D1F` over the UTF-8 canonical typed-value JSON with
sorted object keys, as 16 lowercase hex digits); `occurrence` is the 0-based count of earlier outbound
events with the same key. Concurrent identical calls are therefore matched
by invocation order, never by payload alone. Fields an app marks
nondeterministic are removed before hashing, in capture and replay alike.

### Delivering inbound events

Each inbound event has an **anchor**: the latest outbound event in its scope
with a smaller `seq` (for `platform.call` with `dir: platform`, the
channel's latest outbound event, or none). Replay delivers an inbound event
only after its anchor was matched, at

    replayTime(anchor) + (t(inbound) - t(anchor))

and never before an earlier inbound event of the same scope. Events
without an anchor are delivered at their recorded time on the replay clock,
and only once the app has a handler for them (an EventChannel stream is
listened to, a method call handler is set). `seq` orders events with equal
times.

A delivery that is due keeps idle compression from skipping past its
deadline. An open but idle connection or subscription with nothing due does
not keep replay busy.

### Divergences

| Type | Expected? | Meaning |
|---|---|---|
| `ws.unrecorded`, `platform.unrecorded`, `native.unrecorded` | material | The app performed an operation with no recorded match, including when the capsule has no recording for that adapter at all. Replay fails it (connection error, `PlatformException` with code `bugcapsule.unrecorded`, adapter error); it never contacts the real dependency. |
| `ws.mismatch`, `platform.mismatch`, `native.mismatch` | material | Matched by order, but the payload differs from the recording. |
| `ws.unused`, `platform.unused`, `native.unused` | material | A recorded interaction at or before the failure time was never matched or delivered. |
| `ws.unusedAfterFailure`, `platform.unusedAfterFailure`, `native.unusedAfterFailure` | expected | The same, recorded after the failure. |
| `ws.noPayload`, `platform.noPayload`, `native.noPayload` | material | A delivery needed a non-replayable payload. |
| `ws.undelivered`, `platform.undelivered`, `native.undelivered` | material | A delivery waited longer than the bounded wait for its handler. |
| `ws.unrestored`, `platform.unrestored`, `native.unrestored` | material | A connection or subscription open at a periodic checkpoint could not be restored. |
| `dependency.live` | material | A dependency was reached for real during replay (escaped the adapter). |
| `dependency.late` | material | An adapter was installed after the dependency was initialised (e.g. the channel binding after plugins registered). |

## 6. Checkpoints

A launch checkpoint replays connections and subscriptions from the start of
the session. A periodic checkpoint adds `checkpoint.data.interactions`:

```json
{"open": [{"dep": "ws", "type": "ws", "id": "ws3", "restorable": false}]}
```

listing each connection or subscription that was logically open at the
checkpoint. Native handles are never serialized. An entry is restored only
when its adapter has a tested snapshot (`restorable: true` plus adapter
state under that adapter's own checkpoint key); otherwise the capsule gets
a blocking `interactions.restore` eligibility gap, and replay of that
capsule ends `incompatible` with `dependency.unrestorable`. Replay never
synthesizes an unexplained open connection.

## 7. Bounds, gaps and data controls

Default capture bounds (an SDK may apply lower limits, and remote config
can lower them further):

* 64 KiB per payload (encoded JSON); larger payloads are `truncated`;
* 1 MiB of interaction payloads per capsule; later payloads are
  `metadata` and counted in `stats.dropped`;
* 32 active captured connections and subscriptions per session; further
  ones are not captured and recorded as a `connections.limit` gap;
* opaque binary frames are `metadata` until the app registers a
  serializer for them (`payload.binaryMetadata` gap).

Gap codes: `payload.truncated`, `payload.dropped`, `payload.binaryMetadata`,
`payload.redacted`, `connections.limit`, `codec.unsupported`,
`channel.late`, `adapter.captureFailed`, `operation.unsupported` (the app
used an operation the adapter does not record), `events.dropped`. A dependency
with any gap has `coverage: partial`, and the capsule eligibility gets a
`dependency.<id>` entry. Incomplete message sequences (a dropped or
truncated payload that replay would have to serve) never verify as fixed:
replay reports `<family>.noPayload`.

All adapters follow the SDK's capture settings: local and remote enablement,
sampling, the kill switch, body capture, the payload limits and redaction
before anything is persisted. Remote config may disable a single adapter
(`disabledAdapters: ["bug_capsule.web_socket_channel"]`) without touching
HTTP capture. On a capture failure the app still gets the dependency's real
result; the adapter records an `adapter.captureFailed` gap.

## 8. Verification

`verify` cannot report a fix when a required interaction was missing,
unexpected, mismatched, served from a non-replayable payload, reached the
real dependency or failed to restore: those divergences are material
(§5), so such an attempt is never clean. Verdicts keep the v1 vocabulary;
reports add reason codes derived from divergence types:

| Reason code | From |
|---|---|
| `dependency.unsupported` | preflight (`incompatible`) |
| `interaction.missing` | `*.unused`, `*.undelivered` |
| `interaction.unexpected` | `*.unrecorded` |
| `interaction.mismatch` | `*.mismatch` |
| `interaction.incomplete` | `*.noPayload` |
| `interaction.live` | `dependency.live`, `dependency.late` |
| `interaction.unrestored` | `*.unrestored` |
| `failure.different` | a crash capsule's replay where the app died of another crash type, or a crash replaced the recorded failure (attempt invalid) |
| `failure.different_frame` | a crash capsule's replay where the same crash happened in another in-app frame (still `reproduced`) |

### 8.1 Crash capsules

`manifest.failure.kind` may be `crash` (format v2 only; a v1 capsule with it
is invalid). A crash capsule is built on the next launch from the crash
journal of the process that died:

```json
{
  "kind": "crash",
  "signature": "crash:SIGSEGV",
  "type": "SIGSEGV",
  "message": "Segmentation violation (code 1) at 0x0",
  "stack": "#0 memcpy (libc.so)\n#1 checkout_native (libshop.so)",
  "crash": { "mechanism": "signal", "signal": 11, "inAppFrame": "checkout_native" },
  "t": 18234
}
```

* `signature` = `crash:<type>`; `type` is the signal name (`SIGSEGV`), the
  Mach exception (`EXC_BAD_ACCESS`), `ApplicationNotResponding` or
  `OutOfMemory`. Line numbers and addresses never enter it.
* `crash` (optional): `mechanism` (`signal`, `mach_exception`, `anr`, `oom`,
  `metrickit`; ≤ 50 chars), integer `signal`, `inAppFrame` (≤ 1000 chars,
  the function of the in-app frame closest to the crash).
* The manifest carries the non-blocking gap `crash.native`,
  `labels.source = "crash_journal"`, `labels["crash.mechanism"]`, and
  `stats.journalGapMs` (crash time minus the last journaled event's time)
  when the crash time is known. `dependencies` is present (possibly empty).
* Replay: the same crash type is `reproduced`; another type invalidates the
  attempt (`failure.different`); the window replayed with the app alive is
  `not_reproduced`. Readers that only know the older kinds treat `crash`
  like `exception`.

## 9. Validation

A v2 reader validates everything a v1 reader does, plus:

* `specVersion` 1 or 2; for 2, `manifest.dependencies` is an array of at
  most 100 objects with `id` (1–100 chars, unique), `kind` (1–50),
  `adapter` (1–200), `adapterVersion` (1–100), integer `schema` ≥ 1,
  boolean `required` and `coverage` (`complete`, `partial`, `diagnostic`);
  optional `operations`, `tested`, `gaps`, `stats` with the types in §2;
* every event whose type starts with `ws.`, `platform.` or `native.` has a
  string `data.dep` naming a declared dependency, and the fields replay
  reads: `conn` on `ws.*`; `key` and integer `occurrence` ≥ 0 on
  `ws.connect`, `platform.call`, `platform.listen`, `native.call` and
  `native.subscribe`; integer `index` ≥ 0 on `ws.send` and `ws.message`;
  `initiator` on `ws.close`; `channel` and `call` on `platform.call`,
  `platform.result`, `platform.error`, plus `dir` (`dart` or `platform`) on
  `platform.call`; `channel` and `sub` on `platform.listen`,
  `platform.event`, `platform.cancel` and `platform.done`; `op` on
  `native.call` and `native.result`; `sub` on `native.subscribe`,
  `native.event`, `native.cancel` and `native.done`;
* every payload field (`payload`, `args`, `value`, `details`) that is
  present is an object with a known `mode` and a boolean `replayable`, and
  `bytes`, when present, is an integer ≥ 0;
* `checkpoint.data.interactions.open`, when present, is an array of objects
  with string `dep`, `type` and `id`.

Interaction events in a v1 document are not validated beyond v1 rules (v1
readers ignore them).

Shared valid and invalid examples live in `spec/fixtures/capsule-v2`; the
v1 fixtures stay unchanged except that `invalid/spec-version-2.json` became
`invalid/spec-version-3.json` (v2 readers accept specVersion 2).
