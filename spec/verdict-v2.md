# Verdict v2 (DRAFT, needs owner sign-off)

Status: **draft for review** (BC-ENT-010). Nothing implements it yet. When it
is accepted, `spec/fixtures/conformance/verdicts.json` gains v2 vectors and
every evaluator (Dart CLI, web, Android, iOS mapping, backend) must pass them.

## Why

`verify` reports FIXED when every attempt on the candidate build was
"clean": the expected failure was not observed, every input was dispatched,
and no material divergence occurred. Nothing shows that this harness could
reproduce the failure at all, or that the failing code path even ran. A
controlled test reproduced a race 11 times in 20 on **unchanged** code; two
consecutive misses were classified FIXED with exit 0. FIXED must mean: the
same harness reproduced the failure on the baseline build, and the candidate
passes with evidence that the failing path was exercised.

## Terms

| Term | Meaning |
|---|---|
| Baseline build | The capsule's captured revision (`manifest.app.gitSha`), or the build given with `--baseline <rev>` / `--baseline-artifact <path>` |
| Candidate build | The working tree (`verify`) or the build under test (`gate`, `regress run`) |
| N_b, R_b | Baseline attempts requested, baseline attempts reproduced |
| N_c, C_c | Candidate attempts requested, candidate attempts clean |
| Positive evidence | For a candidate attempt: the replay reached the recorded failure site and it did not fail there (`failure.site.reached`), or a postcondition registered for the capsule passed |
| Eligibility | `manifest.eligibility.status`: eligible, partial, ineligible |

## Verdicts

| Verdict | `verify` rule (all must hold) | Exit |
|---|---|---|
| FIXED | (1) baseline R_b = N_b with N_b ≥ 3; (2) candidate C_c = N_c with N_c ≥ required (below); (3) every clean candidate attempt has positive evidence; (4) eligibility eligible and no unsupported source touched in the failure window; (5) no material or unsafe divergence | 0 |
| FIXED_QUALIFIED | (1), (2), (3), (5) hold; eligibility is partial or unsupported sources were touched. Carries `limitations[]` | 4 (0 with `--accept-qualified`) |
| STILL_FAILING | Every candidate attempt reproduced | 1 |
| FLAKY | Baseline or candidate mixes reproduced and clean attempts | 2 |
| INCONCLUSIVE | Missing attempts; baseline did not reproduce (R_b = 0) or is unavailable; clean candidate attempts without positive evidence; eligibility ineligible | 3 |
| INCOMPATIBLE | Build, schema or runtime cannot run the capsule | 3 |
| UNSAFE | Replay containment was violated: live egress allowed (`--allow-live`, `--lenient-network` hitting a live dependency), an unauthenticated report accepted, or the app started without the engine | 5 |

`replay` (`bugcapsule run`) keeps REPRODUCED / NOT_REPRODUCED / FLAKY /
INCONCLUSIVE / INCOMPATIBLE, and adds UNSAFE. REPRODUCED additionally requires
positive evidence that the failure site was reached.

**Rule:** a candidate run can never be FIXED merely because the original
failure did not execute.

## Required candidate attempts

Let p_low be the Wilson 95% lower bound of the baseline reproduction rate
R_b / N_b. Choose N_c so that a candidate that still fails at rate p_low would
pass all N_c attempts with probability below 1%:

    N_c ≥ max(5, ceil(ln(0.01) / ln(1 − p_low)))   capped at 30

| Baseline | p_low | N_c |
|---|---:|---:|
| 3/3 | 0.44 | 8 |
| 5/5 | 0.57 | 6 |
| 10/10 | 0.72 | 5 |
| 11/20 | 0.34 | (baseline is FLAKY: no FIXED) |

The CLI raises `--runs` to N_c when it is lower and says so.

## Baseline caching

A baseline result is keyed by (capsule sha256, baseline revision or
artifact digest, harness hash: CLI version + runtime + strategy + strict
network + settle timeout). It is stored under `bugcapsule/.cache/baselines/`
and reused for 7 days, so CI runs one baseline per capsule and revision.

## Positive evidence

* SDKs emit `failure.site.reached` in the report when execution reaches the
  frame of the recorded failure (exception or assertion) during replay, with
  `failed: true|false`.
* A postcondition is registered with
  `BugCapsule.expect('<name>', () => <bool>)` (each SDK's equivalent) and is
  named in the regression entry or `--expect <name>`. It is evaluated after
  replay settles.
* Reports from SDKs that predate v2 carry neither: their clean attempts are
  INCONCLUSIVE (`no_positive_evidence`) unless `--expect` names a
  postcondition the app registered.

## Divergence changes

* `screen.size` becomes material when the attempt dispatched coordinate
  taps (semantic actions keep it informational).
* `network.unused` becomes material when the unused request was served
  before the failure point in the baseline.
* New material types: `restore.disallowed` (already emitted), `network.escaped`,
  `replay.unsafe_live`.

## Report schema additions (all optional for v1 readers)

```json
{
  "verdictVersion": 2,
  "baseline": {"revision": "<sha>", "attempts": 5, "reproduced": 5, "cached": true},
  "candidate": {"attempts": 6, "clean": 6, "positiveEvidence": "failure.site.reached"},
  "confidence": {"baselineRate": 1.0, "wilson95": [0.57, 1.0], "requiredAttempts": 6},
  "nondeterminismSignals": [],
  "limitations": []
}
```

Backend: nullable columns for these fields; dashboard shows FIXED_QUALIFIED
and the limitations. Records stored before v2 stay as they are and are never
upgraded to a v2 FIXED.

## Compatibility and rollout

* `--verdict-v1` keeps the old evaluator for one minor release (refused when
  `CI=true` unless `BUGCAPSULE_ALLOW_VERDICT_V1=1`).
* When no baseline can be built (no `gitSha`, dirty capture, missing
  revision), the result is INCONCLUSIVE with `baseline_unavailable`, unless
  `--baseline-artifact` supplies one.

## Open decisions for the owner

1. Thresholds: N_b ≥ 3 at 100%, N_c from the table, cap 30.
2. FIXED_QUALIFIED exits 4 unless `--accept-qualified`.
3. No baseline ⇒ INCONCLUSIVE (not FIXED) by default.
4. Pre-v2 SDK reports without positive evidence ⇒ INCONCLUSIVE by default.
