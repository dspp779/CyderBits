#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/usr/bin/ruby "$ROOT/tests/test-cyder-maplestory-scrolling.rb"
source "$ROOT/tests/assert.sh"
assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" \
  'cp "$SCRIPT_DIR/cyder-maplestory-scrolling.rb" "$RES/ogom-scripts/"' \
  'App must ship the explicit scrolling and restore tool'
# The existing idle-prefix display editor must preserve EXE-scoped scrolling.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/user.reg" <<'REG'
WINE REGISTRY Version 2

[Control Panel\\Desktop] 0
"LogPixels"=dword:00000060

[Software\\Wine\\Mac Driver] 0
"RetinaMode"="n"
"UsePreciseScrolling"="Y"

[Software\\Wine\\AppDefaults\\MapleStory.exe\\Mac Driver] 0
"UsePreciseScrolling"="N"
REG
WINEPREFIX="$TMP" CYDER_FAST_SETTING=display CYDER_RETINA_MODE=1 CYDER_DPI=144 \
  CYDER_FONT_MINGLIU_TARGET=songti CYDER_FONT_SONGTI_TARGET=songti \
  bash "$ROOT/scripts/cyder-edit-user-reg.sh" >/dev/null
reg="$(cat "$TMP/user.reg")"
assert_contains "$reg" '"RetinaMode"="y"' 'Existing display update must run'
assert_contains "$reg" '"UsePreciseScrolling"="Y"' 'Global scrolling must survive display settings'
assert_contains "$reg" '[Software\\Wine\\AppDefaults\\MapleStory.exe\\Mac Driver] 0
"UsePreciseScrolling"="N"' 'EXE scrolling must survive display settings'
echo 'PASS test-cyder-maplestory-scrolling'
