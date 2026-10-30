# Internal-profile acceptance lab

`lib/main_capsule_lab.dart` retains its development defaults. Its bundled coupon
already has the deliberate percentage bug, so capture on the bare base provides
a real failing baseline without deploying a knowingly broken internal patch.

For an isolated internal run, build with explicit public Dart defines:

- `BCPATCH_PROJECT_ID`: isolated backend project UUID
- `BCPATCH_PROFILE=internal`
- `BCPATCH_TRUST_ANCHOR`: that backend's public root anchor
- `BCPATCH_BASE_BUILD`: unique base ID shared by registration and artifact
- `BCPATCH_INSTALLATION_ID`: stable ID for this lab installation
- `BUGCAPSULE_GIT_SHA`: actual committed source SHA; required outside development

Register the exact shipped `coupon` and `summarySurface` contracts. Build the fix
from a clean tracked source repository and archive its source diff. Create the
patch validation before running candidate verification and regression gates.

Optional delivery is configured at runtime in the app's exchange directory
(Documents on iOS, external files on Android) as `acceptance-config.json`:

```json
{"backendUrl":"http://127.0.0.1:PORT","deliveryToken":"SCOPED_TEST_TOKEN"}
```

Keep this file private and out of source control/evidence exports. No private
signing key belongs in the app. The lab captures its deterministic checkout first,
then checks the real HTTP updater and flushes its real receipts. `acceptance.json`
records the output and before/after runtime status, with no token. Existing
`capture.txt` and `lab.bugcapsule` remain compatible with the capture demo script.
Replay mode never performs this capture/delivery work.

Use the actual CLI baseline and verification results, then an actual regression
gate. Do not manufacture evidence outcomes. A one-capsule regression run proves
only that recorded scenario. After validated publication, restart the same
installed app to activate the staged fix; publish a signed rollback and restart
again to return to the bundled baseline. Record the installed binary hash before
and after. Emulator/Simulator evidence does not qualify physical devices or stores.

For a capsule linked to a real monitoring issue, provision the app sandbox's
`tmp/acceptance-monitoring.json` before launch with `backendUrl` and `ingestKey`.
The optional file is read synchronously before SDK initialization. This enables
SDK automatic failure capture; the lab copies the resulting failure-linked
capsule rather than creating a second manual capsule. Keep this disposable
project credential private. Replay does not run the lab's recording callback.
