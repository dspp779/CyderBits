#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

settings="$(cat "$ROOT/scripts/cyder_settings.swift")"
common="$(cat "$ROOT/scripts/cyder-common.sh")"

assert_contains "$settings" 'fontMingLiuTarget' "schema should store MingLiU target"
assert_contains "$settings" 'fontSongtiTarget' "schema should store Songti target"
assert_contains "$settings" '"pingfang"' "settings should list PingFang target id"
assert_not_contains "$settings" '"jhenghei"' "settings should not list retired JhengHei id"
assert_not_contains "$settings" '"lihei"' "settings should not list retired LiHei id"
assert_contains "$common" 'PingFang TC' "common should map pingfang face"
assert_contains "$common" 'mingliu|songti|pingfang' "common should only accept shipped font ids"
assert_contains "$settings" 'var retinaMode = true' "Retina should default on"
assert_contains "$settings" 'var dpi = 192' "DPI should default to 192"
assert_contains "$settings" 'var graphicsHud: CyderGraphicsHud = .off' "graphics HUD should default off"
assert_contains "$settings" 'schemaVersion = 8' "schema version 8"
assert_contains "$settings" 'CYDER_FONT_MINGLIU_TARGET' "env export MingLiU target"
assert_contains "$settings" 'CYDER_FONT_SONGTI_TARGET' "env export Songti target"
assert_not_contains "$settings" '"CYDER_FONT_PRESET": value.fontPreset' \
  "global environment should not export CYDER_FONT_PRESET"

assert_contains "$common" 'CYDER_FONT_MINGLIU_TARGET' "common should export MingLiU target"
assert_contains "$common" 'CYDER_FONT_SONGTI_TARGET' "common should export Songti target"
assert_contains "$common" 'fontMingLiuTarget' "common should read MingLiU target from settings"
assert_contains "$common" 'fontSongtiTarget' "common should read Songti target from settings"
assert_contains "$common" 'CYDER_RETINA_MODE:-1' "shell Retina default should be on"
assert_contains "$common" 'CYDER_DPI:-192' "shell DPI default should be 192"

assert_contains "$common" 'cyder_apply_graphics_preference' \
  "shell settings loader must route graphicsBackend through shared preference helper"
assert_contains "$common" 'cyder_dxmt_launch_allowed' \
  "shell launch path must fail closed on DXMT availability"
assert_contains "$common" 'cyder_macos_at_least 15 0' \
  "shell DXMT gate must require macOS 15+"
assert_not_contains "$common" 'preference=auto' \
  "OEM must not rewrite default to auto"

echo "PASS test-cyder-settings-model"
