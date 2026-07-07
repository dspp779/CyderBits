#!/usr/bin/env bash
# Bootstrap smoke test for Cyder shared prefix (mono + tar + hi-res).
# Requires: install/wine-x86_64 built, tools/libarchive present.
# Uses CYDER_SHARED_PREFIX so bootstrap does not touch ~/Library/Application Support.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -x "$ROOT/install/wine-x86_64/bin/wine" ]] || { echo "SKIP: no wine"; exit 0; }

source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHARED="$TMP/SharedPrefix"
mkdir -p "$SHARED"

output="$(
  CYDER_SHARED_PREFIX="$SHARED" \
    bash "$ROOT/scripts/cyder_launcher.sh" --bootstrap-only \
    --engine-src "$ROOT/install/wine-x86_64" 2>&1
)"
assert_contains "$output" "$SHARED" "bootstrap-only should use CYDER_SHARED_PREFIX"
assert_contains "$output" ".cyder-bootstrap-v1" "bootstrap-only should print marker path"

assert test -f "$SHARED/drive_c/windows/syswow64/tar.exe"
assert test -d "$SHARED/drive_c/windows/mono"
assert test -f "$SHARED/.cyder-bootstrap-v1"
assert test -f "$SHARED/.cyder-font-songti-v1"

WINE="$ROOT/install/wine-x86_64/bin/wine"
if WINEPREFIX="$SHARED" arch -x86_64 "$WINE" reg query \
  "HKCU\\Software\\Wine\\Fonts\\Replacements" /v "PMingLiU" >/dev/null 2>&1; then
  echo "Songti TC font replacements OK"
else
  echo "ASSERT failed: PMingLiU font replacement missing" >&2
  exit 1
fi

if WINEPREFIX="$SHARED" arch -x86_64 "$WINE" reg query "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode >/dev/null 2>&1; then
  echo "RetinaMode registry OK"
fi

echo "PASS test-cyder-bootstrap"
