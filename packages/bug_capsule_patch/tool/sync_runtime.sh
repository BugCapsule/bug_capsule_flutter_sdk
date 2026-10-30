#!/usr/bin/env bash
# Copies the runtime built by bug_capsule_patch_engine/tools/build-native.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${BCPATCH_ENGINE:-$HERE/../../../../bug_capsule_patch_engine}"
rm -rf "$HERE/android/src/main/jniLibs" "$HERE/ios/Frameworks"
mkdir -p "$HERE/ios/Frameworks"
cp -R "$ENGINE/dist/android/jniLibs" "$HERE/android/src/main/jniLibs"
cp -R "$ENGINE/dist/apple/BcpatchRuntime.xcframework" "$HERE/ios/Frameworks/"
echo "synced runtime from $ENGINE/dist"
