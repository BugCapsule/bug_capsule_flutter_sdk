# Patch CLI

`bugcapsule patch` extends the existing product CLI. It uses the existing `bugcapsule login` profile, `BUGCAPSULE_URL` and `BUGCAPSULE_TOKEN`; it does not download tools, create another token store, or change native application code automatically.

Every executed patch command emits a JSON result/error envelope, including without `--json`. `--json` makes that intent explicit for scripts. Existing non-patch command output and exit codes are unchanged. Parser/help errors still use the existing CLI usage handler on stderr.

## Authentication and human approval

A personal (`bcp_`) or service (`bcv_`) credential with `patches.read` and `patches.upload` can inspect backend state, register bases and upload. Default CLI login scopes may not include these permissions; issue a suitably scoped credential through the existing Keys & CLI access workflow. Legacy project secrets, ingest keys and delivery tokens cannot manage patches.

Persistent CLI/CI credentials cannot plan, validate, publish or roll back a patch. Use the dashboard's Emergency Recovery workflow, or explicitly supply an **ephemeral human session** for these commands:

- `BUGCAPSULE_PATCH_SESSION_TOKEN`: the `bcw_` token returned by the existing `POST /v1/console/auth/login` sign-in endpoint. Obtain it through your approved interactive authentication workflow; never put it in source control, command arguments or job logs.
- `BUGCAPSULE_PATCH_PROJECT_ID`, `--project`, or `project` in `bugcapsule.patch.json`: the exact project UUID. Explicit command options take precedence over the file and environment.
- Backend selection remains the existing profile's URL or `BUGCAPSULE_URL`.

The CLI keeps the session only in the process environment and sends `X-BugCapsule-Project`. It never saves it, refreshes it automatically, or falls back to a CI token after the session expires. Local engine/Git subprocesses do not inherit the session or existing BugCapsule token/key environment variables. Unset the session environment variable when finished. Backend session expiry, project membership, roles, scope checks, deployment versions and second-person approval remain authoritative. There is no CLI approval bypass: a response requiring approval stays pending and is reviewed in the dashboard.

## Prepare and build

Install a reviewed patch-engine checkout locally and a Node version capable of running its TypeScript tools (Node 22.18+ or a newer supported release). Set `BUGCAPSULE_PATCH_ENGINE`, `--engine`, or `engine` in `bugcapsule.patch.json`. `doctor` runs the actual capability tool, not just an executable-presence check.

```sh
bugcapsule patch doctor --engine /path/to/bug_capsule_patch_engine --online --json
bugcapsule patch init --platform flutter
bugcapsule patch base register base-manifest.json --json
bugcapsule patch classify --engine /path/to/bug_capsule_patch_engine \
  --registered patch/registered.json --repo . --base-rev BASE_COMMIT --json
bugcapsule patch build --engine /path/to/bug_capsule_patch_engine \
  --base INSTALLED_BASE_ID --source patch/modules --repo . --base-rev BASE_COMMIT \
  --project PROJECT_UUID --patch-id coupon-fix --sequence 1 --profile internal \
  --key /secure/location/author.pem --key-id author-key --out /tmp/coupon.bcpatch --json
bugcapsule patch inspect /tmp/coupon.bcpatch --engine /path/to/bug_capsule_patch_engine --json
```

`init` creates `bugcapsule.patch.json`, an empty registered-contract inventory, and a module directory. It refuses to overwrite existing configuration. Populate the inventory from the installed binary and integrate the platform SDK binding; initialization is not proof that an application supports patches. The registered base manifest contains `applicationId`, `platform` (`flutter_android`, `flutter_ios`, `android`, `ios`), `baseBuildId`, `appVersion` and `modules`; optional surfaces, native dependencies, permissions, capability hash and provenance use the backend base contract.

`build` reads the immutable base from the backend and verifies its capability and host-ABI hashes against the installed engine. It requires a clean committed checkout and the selected `--head-rev` (default `HEAD`) to be the actual checkout HEAD. It classifies **all** changed paths between `--base-rev` and head, stops on `STORE_RELEASE_REQUIRED` or `UNKNOWN`, and refuses to omit any classified patchable file. `.bpl` modules are selected recursively under `--source`; surface documents and assets must be selected explicitly with repeatable `--surface` and `--asset`. An unsupported classification cannot be overridden by those flags. Files outside the classified repository and existing output paths are refused.

The default profile is `internal`, with Git-bound source provenance. The engine compiles and signs the artifact; the CLI does not implement another compiler or signature format. The build emits `<artifact>.source-diff.json` only when the engine's signed source commit matches the selected head. Explicit `development` artifacts have content-bound development provenance and receive no fabricated commit-bound source review. A development artifact's transport tests do not establish production qualification.

## Upload and resume

```sh
bugcapsule patch upload /tmp/coupon.bcpatch \
  --source-diff /tmp/coupon.bcpatch.source-diff.json --json
```

The CLI declares byte count and SHA-256, uploads `application/vnd.bugcapsule.bcpatch`, and finalizes the artifact. `--change-report file.json` supplies the backend's optional change report. The source-diff JSON contains `format: "unified"`, `baseCommit`, `headCommit`, and `diff`; the backend binds the head to the signed source commit and makes it immutable.

The default checkpoint is `<artifact>.upload.json`; choose another with `--state`. It is saved before the first request and after creation/finalization. Repeating the same command resumes the same upload with stable phase idempotency keys, including a lost finalize response. A completed checkpoint reports the archived upload result, not current deployment eligibility. Different bytes, backend, credential, or review metadata require a separate checkpoint. Expired upload sessions require starting a new checkpoint. Checkpoints contain identifiers and credential fingerprints, never raw credentials or private signing keys; retain them outside source control. Concurrent invocations should use separate checkpoint files.

All HTTP calls have an absolute 30-second deadline. The client retries network failures, timeouts, HTTP 429/502/503/504 at most twice, preserving the exact mutation key and payload. It honors a bounded numeric `Retry-After`; authorization and optimistic-version conflicts are not retried. Redirects are refused so a management token cannot follow an external URL. For non-upload mutations, reuse the returned `idempotencyKey` with `--idempotency-key` only for an exact retry; a changed request requires a new key.

## Exact validation and replay

With the explicit human session configured:

```sh
bugcapsule patch validate ARTIFACT_UUID --capsule CAPSULE_UUID --json
bugcapsule patch validate VALIDATION_UUID --get --json
bugcapsule patch validate VALIDATION_UUID --evidence baseline-evidence.json --json
```

Starting validation returns `PENDING`, not a successful test. Regressions are required and partial evidence is refused. `--affected-digest` identifies an already-patched failing baseline; omit it for the bare base. `--deadline-hours` defaults to 48. `--capsule` takes the backend capsule resource UUID returned by upload/list, not the embedded manifest capsule ID. `--get` reads the stored evidence/status. `--evidence` submits **supplied real replay evidence** to the validation endpoint; it does not run a test or invent outcomes.

Run the existing `bugcapsule replay`, `bugcapsule verify`, and `bugcapsule gate` commands on the real application/device. Pin the exact fix with `--patch-artifact`, `--patch-keyring`, and `--patch-keyring-signature`; a baseline without an artifact runs the bare base. Keep archived delegated-key metadata with its artifact. Existing replay preflight rejects the wrong base, digest, ABI or missing runtime. Convert actual reports to the evidence contract: `kind` (`baseline`, `fix`, `regression`), `capsuleId`, `outcome`, `attempts`, `reproductions`, `platform`, exact `identity` (`baseBuildId`, `patchSetDigest`, `engineAbi`, `hostAbiHash`) and optional `reasonCodes`. Do not mark a build, static inspection or server publication as replay evidence. The backend judges all required evidence; this command family does not orchestrate physical devices automatically.

## Plan, request, inspect, roll back

```sh
bugcapsule patch plan ARTIFACT_UUID --environment staging --stages 100,500,2500,10000 --json
bugcapsule patch deploy DEPLOYMENT_UUID --expected-version 1 --reason 'Reviewed exact validation and source' --json
bugcapsule patch status DEPLOYMENT_UUID --json
bugcapsule patch rollback DEPLOYMENT_UUID --expected-version CURRENT_VERSION \
  --to-base --reason 'Observed regression' --json
```

Planning never publishes. `deploy` explicitly requests delivery and may return `approval_required`; it does not approve its own request. Versions come from the current plan/status. A conflict requires reviewing fresh state; never blindly substitute a newer version. Rollout stages are increasing basis points ending at 10000. Non-development deployment still requires exact validation and applicable distribution qualification, regardless of local command success.

Rollback requires exactly one of `--to-base` or `--to-digest sha256:…`; `--revoke` additionally asks the backend to revoke the faulty artifact. Publication is not device acknowledgment. `status` returns deployment state and the backend's complete receipts, including no-report/stale coverage and pending rollback. Zero reports never means all devices are healthy.

## Exit codes and checks

| Code | Meaning |
|---|---|
| 0 | Command accepted or read completed; inspect returned state before claiming delivery |
| 1 | Network, local configuration, filesystem, engine execution or nonclassified backend failure |
| 2 | Validation pending/running or second-person approval required |
| 3 | Store release required, failed/inconclusive/unsupported validation, or backend conflict/gone |
| 4 | Classifier cannot prove patchability (`UNKNOWN`) |
| 64 | Invalid usage/input |
| 77 | Authentication/authorization failure or missing explicit person session |

From `packages/bug_capsule`, run `dart test test/cli`. To package the product CLI with existing native build hooks, run `dart build cli --target=packages/bug_capsule/bin/bugcapsule.dart` from the workspace root. Tests cover the token/session boundary, redirects, deadline, stable retry keys, upload resumption, exact API bodies, truthful pending results, classification refusal and omitted inputs. Physical-device/store qualification is separate.
