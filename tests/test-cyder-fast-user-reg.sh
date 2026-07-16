#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/prefix"
cat >"$TMP/prefix/user.reg" <<'REG'
WINE REGISTRY Version 2

[Control Panel\\Desktop] 0
"FontSmoothing"="2"
"FontSmoothingGamma"=dword:00000578
"FontSmoothingOrientation"=dword:00000001
"FontSmoothingType"=dword:00000002
"LogPixels"=dword:00000060

[Software\\Wine\\Fonts\\Replacements] 0
"MingLiU"="Songti TC"
"PMingLiU"="Songti TC"

[Software\\Wine\\Mac Driver] 0
"RetinaMode"="n"
REG

WINEPREFIX="$TMP/prefix" CYDER_RETINA_MODE=1 CYDER_DPI=192 \
  CYDER_FAST_SETTING=display \
  bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null

reg="$(cat "$TMP/prefix/user.reg")"
assert_contains "$reg" '"RetinaMode"="y"' "fast editor should enable Retina"
assert_contains "$reg" '"LogPixels"=dword:000000c0' "fast editor should encode DPI as dword"

WINEPREFIX="$TMP/prefix" CYDER_FONT_SMOOTHING=grayscale \
  CYDER_FAST_SETTING=smoothing \
  bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/prefix/user.reg")"
assert_contains "$reg" '"FontSmoothingType"=dword:00000001' "grayscale should use standard smoothing"
assert_contains "$reg" '"FontSmoothingGamma"=dword:00000000' "grayscale should clear gamma"

WINEPREFIX="$TMP/prefix" CYDER_FONT_PRESET=mingliu CYDER_FAST_SETTING=font \
  bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/prefix/user.reg")"
assert_contains "$reg" '[Software\\Wine\\Fonts\\Replacements(disabled)]' "MingLiU should disable the replacement section"
if [[ "$reg" == *'[Software\\Wine\\Fonts\\Replacements] '* ]]; then
  echo "ASSERT failed: active replacement section should be renamed" >&2
  exit 1
fi

WINEPREFIX="$TMP/prefix" CYDER_RETINA_MODE=0 CYDER_DPI=96 \
  CYDER_FONT_PRESET=songti CYDER_FONT_SMOOTHING=cleartype-rgb \
  CYDER_FAST_SETTING=all bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/prefix/user.reg")"
assert_contains "$reg" '"RetinaMode"="n"' "fast editor should disable Retina explicitly"
assert_contains "$reg" '[Software\\Wine\\Fonts\\Replacements]' "Songti should reactivate replacements"
assert_contains "$reg" '"MingLiU"="Songti TC"' "Songti replacements should be restored"

echo "PASS test-cyder-fast-user-reg"
