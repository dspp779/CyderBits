#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/cache" "$TMP/run"
cp "$ROOT/tests/fixtures/cyder_scrolling_harness.swift" "$TMP/main.swift"
swiftc -module-cache-path "$TMP/cache" "$ROOT/scripts/cyder_scrolling.swift" "$TMP/main.swift" -o "$TMP/harness"
"$TMP/harness" "$TMP/run"
assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" '"$SCRIPT_DIR/cyder_scrolling.swift"' \
  'App must build the native scrolling helper'
assert_contains "$(cat "$ROOT/scripts/cyder_app_main.swift")" 'CyderScrollingRegistry.run' \
  'CyderSwift must expose --scrolling'
assert_not_contains "$(cat "$ROOT/scripts/cyder-common.sh")" '/usr/bin/ruby "$helper"' \
  'Launch path must not depend on system Ruby for scrolling'
# The existing idle-prefix display editor must preserve EXE-scoped scrolling.
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
