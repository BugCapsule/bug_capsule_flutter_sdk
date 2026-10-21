#!/bin/sh
# Copies the shared capsule fixtures, conformance fixtures and spec documents
# from this repository (the source of truth) to the sibling SDK and backend
# checkouts.
# Each of them fails its tests when its copy differs.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(dirname "$here")
src="$here/spec/fixtures"

copy() { # <dest dir> <subdir>
  [ -d "$(dirname "$1")" ] || return 0
  rm -rf "$1/$2"
  mkdir -p "$1"
  cp -R "$src/$2" "$1/$2"
  echo "synced $1/$2"
}

copy "$root/bug_capsule_backend/test/fixtures" capsule-v1
if [ -d "$root/bug_capsule_backend/docs" ]; then
  cp "$here/spec/capsule-v1.md" "$here/spec/runtimes-v1.md" "$root/bug_capsule_backend/docs/"
  echo "synced $root/bug_capsule_backend/docs/{capsule-v1,runtimes-v1}.md"
fi
for sdk in bug_capsule_android_sdk bug_capsule_ios_sdk bug_capsule_web_sdk; do
  if [ -d "$root/$sdk" ]; then
    copy "$root/$sdk/spec-fixtures" capsule-v1
    copy "$root/$sdk/spec-fixtures" conformance
  fi
done
