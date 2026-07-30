#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

manifest="$ROOT/config/cyder-engine-manifest.json"
archive_relative="$(cat "$ROOT/config/cyder-engine-archive.txt")"
archive="$ROOT/$archive_relative"

assert test -f "$manifest"
plutil -convert json -o /dev/null -- "$manifest"
assert_eq "$(plutil -extract versionLabel raw -o - "$manifest")" \
  "$(cat "$ROOT/config/cyder-engine-version.txt")" \
  "pinned manifest and version file should agree"
assert_eq "$(plutil -extract artifact raw -o - "$manifest")" \
  "$(basename "$archive")" \
  "pinned manifest and archive path should agree"

if [[ ! -f "$archive" ]]; then
  echo "SKIP pinned engine payload checks: $archive is not present"
  exit 0
fi

assert_eq "$(shasum -a 256 "$archive" | awk '{print $1}')" \
  "$(plutil -extract artifactSHA256 raw -o - "$manifest")" \
  "pinned engine archive digest should match"
assert_eq "$(tar -xJOf "$archive" wine-x86_64/version | head -1)" \
  "$(plutil -extract versionLabel raw -o - "$manifest")" \
  "pinned archive version should match"
assert_eq "$(tar -xJOf "$archive" wine-x86_64/lib/wine/x86_64-windows/ntdll.dll | shasum -a 256 | awk '{print $1}')" \
  "$(plutil -extract ntdllSHA256 raw -o - "$manifest")" \
  "pinned NTDLL digest should match"

echo "PASS test-pinned-engine-manifest"
