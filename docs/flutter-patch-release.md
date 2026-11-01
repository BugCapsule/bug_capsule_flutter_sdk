# Hosted Flutter patch release

The workspace keeps local path dependencies. Publish only staged packages,
never the workspace patch directory (`publish_to: none` is intentional).

1. Choose unpublished versions on pub.dev; update core pubspec/runtime version
   and changelog together. Keep package/root README identical.
2. Run `python3 tool/package_release.py` for the standalone core candidate.
   Its outside-repository publish dry-run must pass.
3. Run `python3 tool/package_patch_release.py --candidate /reviewed/flutter-patch-sdk
   --output /new/staging/bug_capsule_patch-VERSION --core-version CORE_VERSION`.
   The input must be the reviewed native candidate with PATCH-CANDIDATE.json.
   Every JNI/XCFramework file is checked against its recorded hash, and all
   supported mobile architecture slices must exist. The staged pubspec replaces
   workspace/path dependencies with a hosted core version. Native payloads are
   included explicitly despite the development checkout gitignore.
4. Before core is published, a temporary pubspec_overrides.yaml may resolve
   that exact staged core for local dry-run/consumer checks. This override is
   excluded by .pubignore; do not describe this as hosted dependency validation.
5. Test both packages from a fresh external Flutter app; resolve dependencies,
   analyze, and build a native consumer. Retain the exact source/native hashes.
6. Obtain release approval for the immutable artifacts and green CI. Publish
   core first. Then remove the temporary override and resolve the patch package
   against hosted core, repeat publish dry-run and consumer verification, and
   publish patch. Record returned pub.dev versions and archive SHA256 values.

The native binary source is recorded separately from the Dart source. Reusing
an earlier binary is allowed only after proving its compiled inputs equivalent;
never relabel its original source commit. Publication is not customer rollout
or platform-store approval. CLI/compiler release packaging has its own workflow.
