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
"SimSun"="Songti TC"

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

WINEPREFIX="$TMP/prefix" \
  CYDER_FONT_MINGLIU_TARGET=mingliu CYDER_FONT_SONGTI_TARGET=songti \
  CYDER_FAST_SETTING=font \
  bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/prefix/user.reg")"
assert_contains "$reg" '[Software\\Wine\\Fonts\\Replacements]' "Replacements stay active"
if [[ "$reg" == *'[Software\\Wine\\Fonts\\Replacements(disabled)]'* ]]; then
  echo "ASSERT failed: disabled section should be removed" >&2
  exit 1
fi
if echo "$reg" | grep -q '^"MingLiU"='; then
  echo "ASSERT failed: MingLiU replacement should be deleted" >&2
  exit 1
fi
assert_contains "$reg" '"SimSun"="Songti TC"' "SimSun should map to Songti TC"

WINEPREFIX="$TMP/prefix" \
  CYDER_FONT_MINGLIU_TARGET=pingfang CYDER_FONT_SONGTI_TARGET=songti \
  CYDER_FAST_SETTING=font-mingliu \
  bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/prefix/user.reg")"
assert_contains "$reg" '"MingLiU"="PingFang TC"' "fast mingliu path sets PingFang TC"

WINEPREFIX="$TMP/prefix" CYDER_RETINA_MODE=0 CYDER_DPI=96 \
  CYDER_FONT_MINGLIU_TARGET=songti CYDER_FONT_SONGTI_TARGET=songti \
  CYDER_FONT_SMOOTHING=cleartype-rgb \
  CYDER_FAST_SETTING=all bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/prefix/user.reg")"
assert_contains "$reg" '"RetinaMode"="n"' "fast editor should disable Retina explicitly"
assert_contains "$reg" '[Software\\Wine\\Fonts\\Replacements]' "Songti should keep replacements active"
assert_contains "$reg" '"MingLiU"="Songti TC"' "Songti replacements should set MingLiU to Songti TC"

# user.reg without Replacements section should gain one on font apply
mkdir -p "$TMP/no-repl/prefix"
cat >"$TMP/no-repl/prefix/user.reg" <<'REG'
WINE REGISTRY Version 2

[Control Panel\\Desktop] 0
"LogPixels"=dword:00000060

[Software\\Wine\\Mac Driver] 0
"RetinaMode"="n"
REG
WINEPREFIX="$TMP/no-repl/prefix" \
  CYDER_FONT_MINGLIU_TARGET=songti CYDER_FONT_SONGTI_TARGET=songti \
  CYDER_FAST_SETTING=font \
  bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/no-repl/prefix/user.reg")"
assert_contains "$reg" '[Software\\Wine\\Fonts\\Replacements]' "missing section should be created"
assert_contains "$reg" '"MingLiU"="Songti TC"' "MingLiU key should be appended"
assert_contains "$reg" '"SimSun"="Songti TC"' "SimSun key should be appended"

echo "PASS test-cyder-fast-user-reg"
