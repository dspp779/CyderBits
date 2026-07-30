#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

tree="$TMP/tree/wine-x86_64"
mkdir -p "$tree/lib/wine/x86_64-windows"
printf '%s\n' "CX26.3.0-W11-Cyder007" >"$tree/version"
printf '%s\n' "synthetic ntdll" >"$tree/lib/wine/x86_64-windows/ntdll.dll"
ntdll_sha="$(shasum -a 256 "$tree/lib/wine/x86_64-windows/ntdll.dll" | awk '{print $1}')"
cat >"$tree/engine-manifest.json" <<EOF
{
  "schemaVersion": 1,
  "versionLabel": "CX26.3.0-W11-Cyder007",
  "ntdllSHA256": "$ntdll_sha"
}
EOF

archive="$TMP/engine-test.tar.xz"
(
  cd "$TMP/tree"
  tar -cJf "$archive" wine-x86_64
)
archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
manifest="$archive.manifest.json"
cat >"$manifest" <<EOF
{
  "schemaVersion": 1,
  "engineId": "cx26.3-w11-cyder007",
  "versionLabel": "CX26.3.0-W11-Cyder007",
  "ntdllSHA256": "$ntdll_sha",
  "artifact": "$(basename "$archive")",
  "artifactSHA256": "$archive_sha"
}
EOF

output="$(bash "$ROOT/scripts/import-engine-release.sh" --manifest "$manifest")"
assert_contains "$output" "Verified engine release" "valid engine releases should verify"
assert_contains "$output" "Verification only" "verification should not mutate Cyder without --apply"

cp "$manifest" "$TMP/bad.manifest.json"
plutil -replace artifactSHA256 -string "$(printf '0%.0s' {1..64})" "$TMP/bad.manifest.json"
set +e
bad_output="$(bash "$ROOT/scripts/import-engine-release.sh" --manifest "$TMP/bad.manifest.json" 2>&1)"
bad_status=$?
set -e
assert_eq "$bad_status" "1" "digest mismatch should fail closed"
assert_contains "$bad_output" "SHA-256 mismatch" "digest failure should be explicit"

echo "PASS test-import-engine-release"
