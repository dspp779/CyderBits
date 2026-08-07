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
assert_contains "$(cat "$manifest")" "cyder-wineserver-free-async-queue-null-fd.patch" \
  "pinned Cyder009 manifest should include the latest free_async_queue guard"
assert_contains "$(cat "$manifest")" "a6-final-same-view-backing-sync.patch" \
  "pinned Cyder009 manifest should include the final A6 backing-sync patch"
assert_contains "$(cat "$manifest")" "cyder-ntdll-qdo-optnone-NtQueryDirectoryObject.patch" \
  "pinned Cyder009 manifest should include the QDO optnone bandage"

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
tar -tJf "$archive" wine-x86_64/lib/wine/x86_64-unix/libMoltenVK.dylib >/dev/null
tar -tJf "$archive" wine-x86_64/lib/wine/x86_64-unix/libMoltenVK.real.dylib >/dev/null

echo "PASS test-pinned-engine-manifest"
