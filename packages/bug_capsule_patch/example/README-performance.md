# Opt-in device measurements

Use one Release binary for both modes. Place `benchmark-config.json` in the
app's Documents directory (Android uses external app storage), terminate and
launch, then retrieve `benchmark-result.json`. Attach the binary commit/build,
physical-device identifier/model, OS, power/thermal conditions and launch order
to external evidence. The Dart report cannot prove physical hardware or read
thermal state. No device actions are automated by this harness.

Example patched request for the coupon_v2 fixture and this lab's sample:

```json
{"runId":"iphone-runtime-01","mode":"runtime","expectedSource":"patched","expectedReasons":["none"],"expectedOutput":{"subtotal":"68.48","discount":"13.70","total":"54.78","label":"PATCHED 20%"}}
```

For the same-binary direct baseline set `mode` to `baseline`, `expectedSource`
to `direct_bundled`, and expected output to subtotal `69.98`, discount `1399.60`,
total `-1329.62`, label `BASE 20%`. This preserves the shipped bug deliberately.
The SDK remains linked, but no runtime is opened in baseline mode. A separate
runtime-on-base scenario uses `runtime` with source `bundled` and the same
bundled outputs. Declare its expected fallback reason (`not_patched` normally).
A known faulting signed fixture can similarly test runtime-fault fallback, but
must declare the actual fault reason and retain status/reason counts: it is not
interchangeable with ordinary runtime-on-base timing.

Each run separately measures runtime open, the first call in this process,
20 warmups and 200 timed evaluations, asserting every output field and source
outside each timed interval. Nanoseconds are scaled monotonic stopwatch ticks;
the frequency is recorded. Percentiles use nearest rank. `markHealthy` timing
and errors are separate. RSS values are snapshots, not peak memory. The first
post-frame interval starts at Dart main, after VM startup, and includes the
benchmark work; it is not OS launch-to-first-frame time. Repeated fresh process
launches are required to estimate a cold-first-call distribution. No filesystem
cache-cold claim is made. Evaluation bypasses normal HTTP/inbox delivery.

No latency threshold is assumed. Optional `budgetsNs` keys `p50Ns`, `p95Ns`,
`p99Ns`, `maxNs` accept positive numeric nanosecond limits defined in advance
by the application's requirements. Raw measurements and individual comparisons
are emitted; correctness success alone is not latency qualification.

For real HTTP measurements remove `benchmark-config.json`, retain the normal
private `patch-config.json`, and add `"measurePerformance": true` there.
`results.jsonl` adds `deliveryPerformance`: whole update/check/verify/stage time,
receipt flush time and each actual artifact fetch's elapsed time and received
byte count. Fetch time includes buffering and transport overhead, not pure wire
time. No URL/token/payload is emitted by the timing wrapper. Empty fetches mean
no download happened. Use a fresh authorized digest and backend request logs
to substantiate a first-download claim; do not erase the trust journal. Timing
success does not establish server-side receipt acceptance: retain HTTP/backend
evidence separately. Do not distribute private configuration with evidence.
