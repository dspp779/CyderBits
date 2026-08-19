#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

HELPER="$ROOT/scripts/cyder-extract-exe-icon.sh"
assert test -f "$HELPER"
assert test -x "$HELPER"
helper_src="$(cat "$HELPER")"
assert_not_contains "$helper_src" "python3" \
  "icon helper must not invoke python3 (CLT stub)"
assert_not_contains "$helper_src" "wineserver -k" \
  "icon helper must not kill wineserver"
assert_contains "$helper_src" "winemenubuilder.exe" \
  "icon helper must use winemenubuilder"
assert_contains "$helper_src" "winepath" \
  "lnk TargetPath must be converted with winepath -w"
assert_contains "$helper_src" "cscript" \
  "lnk must be created with cscript / WScript.Shell"

# Direct .exe to -t is upstream-unsupported; helper must pass the .lnk.
assert_contains "$helper_src" 'winemenubuilder.exe -t "$lnk"' \
  "winemenubuilder -t must receive the unix .lnk path"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-extract-icon-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
set +e
missing_out="$("$HELPER" --exe "$tmp/missing.exe" --png "$tmp/out.png" 2>&1)"
missing_status=$?
set -e
assert_eq "$missing_status" "1" "missing WINEPREFIX and exe must fail closed"
assert_contains "$missing_out" "WINEPREFIX" "failure must mention WINEPREFIX or missing inputs"

PIKA="$ROOT/dist/皮卡丘打排球.exe"
WINE="${CYDER_WINE:-$HOME/.cyder/runtime/Engines/wine-x86_64/bin/wine}"
PREFIX="${WINEPREFIX:-$HOME/Library/Application Support/Cyder/bottles/shared}"
if [[ -f "$PIKA" && -x "$WINE" && -f "$PREFIX/.cyder-bootstrap-v1" ]]; then
  scratch="$tmp/scratch"
  mkdir -p "$scratch"
  cp "$PIKA" "$scratch/game.exe"
  png="$tmp/from-lnk.png"
  WINEPREFIX="$PREFIX" \
    "$HELPER" --wine "$WINE" --exe "$scratch/game.exe" --png "$png" --scratch "$scratch"
  assert test -s "$png"
  magic="$(dd if="$png" bs=8 count=1 2>/dev/null | xxd -p)"
  assert_contains "$magic" "89504e47" "output must be a PNG"
  assert test ! -e "$scratch/game.exe"
  assert test ! -e "$scratch/game.lnk"

  set +e
  WINEPREFIX="$PREFIX" WINESERVER="${WINE%/wine}/wineserver" \
    arch -x86_64 "$WINE" winemenubuilder.exe -t "$scratch/../nope.exe" "$tmp/direct.png" >/dev/null 2>&1
  # Recreate a copy only to prove -t on exe still fails:
  cp "$PIKA" "$tmp/direct.exe"
  WINEDEBUG="-all" WINEPREFIX="$PREFIX" WINESERVER="${WINE%/wine}/wineserver" \
    arch -x86_64 "$WINE" winemenubuilder.exe -t "$tmp/direct.exe" "$tmp/direct.png" >"$tmp/direct.log" 2>&1
  set -e
  assert test ! -s "$tmp/direct.png"
  assert_contains "$(cat "$tmp/direct.log")" "could not read .lnk" \
    "winemenubuilder -t on an exe must still fail"
else
  echo "SKIP wine integration (need dist/皮卡丘打排球.exe, wine, and bootstrapped prefix)" >&2
fi

echo "PASS test-cyder-extract-exe-icon"
