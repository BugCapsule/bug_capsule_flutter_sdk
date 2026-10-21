#!/bin/sh
# Copies the shared capsule fixtures, conformance fixtures and spec documents
# from this repository (the source of truth) to the sibling SDK and backend
# checkouts. Each of them fails its tests when its copy differs.
#
#   tool/sync_spec.sh                  # every sibling that exists
#   tool/sync_spec.sh android web      # only these (backend, android, ios, web)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(dirname "$here")
src="$here/spec/fixtures"
targets=${*:-"backend android ios web"}

copy() { # <dest dir> <subdir>
  [ -d "$(dirname "$1")" ] || return 0
  rm -rf "$1/$2"
  mkdir -p "$1"
  cp -R "$src/$2" "$1/$2"
  echo "synced $1/$2"
}

for t in $targets; do
  case "$t" in
    backend)
      copy "$root/bug_capsule_backend/test/fixtures" capsule-v1
      if [ -d "$root/bug_capsule_backend/docs" ]; then
        cp "$here/spec/capsule-v1.md" "$here/spec/runtimes-v1.md" "$root/bug_capsule_backend/docs/"
        echo "synced $root/bug_capsule_backend/docs/{capsule-v1,runtimes-v1}.md"
      fi
      ;;
    android|ios|web)
      sdk="$root/bug_capsule_${t}_sdk"
      if [ -d "$sdk" ]; then
        copy "$sdk/spec-fixtures" capsule-v1
        copy "$sdk/spec-fixtures" conformance
      fi
      ;;
    *) echo "unknown target: $t (backend, android, ios, web)" >&2; exit 64 ;;
  esac
done
