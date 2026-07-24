#!/usr/bin/env bash
# Bootstrap smoke test for Cyder direct wineboot baseline into Shared.
# Requires: install/wine-cx26-x86_64 built, tools/libarchive present.
# Uses CYDER_SHARED_PREFIX so bootstrap does not touch ~/Library/Application Support.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -x "$ROOT/install/wine-cx26-x86_64/bin/wine" ]] || { echo "SKIP: no wine"; exit 0; }

source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHARED="$TMP/SharedPrefix"
SUPPORT="$TMP/support"
mkdir -p "$SHARED" "$SUPPORT/downloads"
for addon in wine-mono-10.4.1-x86.msi wine-gecko-2.47.4-x86.msi wine-gecko-2.47.4-x86_64.msi; do
  [[ -f "$ROOT/downloads/$addon" ]] || { echo "SKIP: missing downloads/$addon"; exit 0; }
  cp "$ROOT/downloads/$addon" "$SUPPORT/downloads/"
done

output="$(
  CYDER_SUPPORT="$SUPPORT" \
  CYDER_SHARED_PREFIX="$SHARED" \
  CYDER_RUNTIME_ROOT="$TMP/runtime" \
    bash "$ROOT/scripts/cyder_launcher.sh" --bootstrap-only \
    --engine-src "$ROOT/install/wine-cx26-x86_64" 2>&1
)"
assert_contains "$output" "$SHARED" "bootstrap-only should use CYDER_SHARED_PREFIX"
assert_contains "$output" ".cyder-bootstrap-v1" "bootstrap-only should print marker path"

assert test -f "$SHARED/drive_c/windows/syswow64/tar.exe" -o \
  -f "$SHARED/drive_c/windows/system32/tar.exe"
assert test -d "$SHARED/drive_c/windows/mono"
assert test -d "$SHARED/drive_c/windows/syswow64/gecko/2.47.4/wine_gecko"
assert test -f "$SHARED/.cyder-bootstrap-v1"
assert test -f "$SHARED/.cyder-golden-baseline-v2"
assert test ! -e "$SUPPORT/templates/golden/manifest.json"

WINE="$ROOT/install/wine-cx26-x86_64/bin/wine"
if WINEPREFIX="$SHARED" arch -x86_64 "$WINE" reg query \
  "HKCU\\Software\\Wine\\Fonts\\Replacements" /v "PMingLiU" >/dev/null 2>&1; then
  echo "Songti TC font replacements OK"
else
  echo "ASSERT failed: PMingLiU font replacement missing" >&2
  exit 1
fi

ddraw="$(WINEPREFIX="$SHARED" arch -x86_64 "$WINE" reg query "HKCU\\Software\\Wine\\DllOverrides" /v ddraw 2>/dev/null)"
assert_contains "$ddraw" "native,builtin" "Baseline should set ddraw native,builtin"

echo "PASS test-cyder-bootstrap"
