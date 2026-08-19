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
assert_contains "$settings" 'schemaVersion = 12' "schema version 12"
assert_contains "$settings" 'enum CyderWineLocale' "settings should define the Wine locale preference"
assert_contains "$settings" 'static var menuCases' "locale menu should omit Korean from the user-facing choices"
assert_contains "$settings" 'CYDER_WINE_LOCALE' "global environment should export CYDER_WINE_LOCALE"
assert_contains "$settings" 'var maplestoryWZCache = true' "MapleStory WZ cache should default on"
assert_contains "$settings" 'var updatedAt: String?' "settings should persist the last update time"
assert_contains "$settings" 'var lastModified: [String: String]' "settings should persist per-scope modification times"
assert_contains "$settings" 'case wined3d, dxvk, dxmt, d3dmetal' \
  "settings enum must expose only supported graphics backends"
assert_contains "$settings" 'Schema 10 removes the experimental dxvk2 graphics backend' \
  "settings should document the DXVK 2 migration"
assert_contains "$settings" 'usesDxvkTranslation' \
  "frame-rate and HUD must share a DXVK-family helper"
assert_contains "$settings" 'usesFrameLimiter' \
  "DXMT must share the frame-rate limiter with the DXVK family"
assert_contains "$settings" 'oneTwenty = "120"' "settings must persist 120 fps"
assert_contains "$settings" 'oneFortyFour = "144"' "settings must persist 144 fps"
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
assert_contains "$common" 'maplestoryWZCache' "shell should read the MapleStory WZ cache preference"
assert_contains "$common" 'cyder_apply_maplestory_wz_cache' "shell should scope WZ cache to MapleStory launches"
assert_contains "$common" 'CYDER_WINE_LOCALE' "shell should load the Wine locale preference"
assert_contains "$common" 'plutil -extract wineLocale' "shell should read wineLocale from settings.json"

assert_contains "$common" 'cyder_apply_graphics_preference' \
  "shell settings loader must route graphicsBackend through shared preference helper"
assert_contains "$common" 'cyder_dxmt_launch_allowed' \
  "shell launch path must fail closed on DXMT availability"
assert_contains "$common" 'cyder_maplestory_auto_graphics_backend' \
  "shell launch path must provide MapleStory platform graphics policy"
assert_contains "$common" 'cyder_is_maplestory_graphics_executable' \
  "shell graphics policy must identify both MapleStory executables"
assert_contains "$settings" 'isMapleStoryGraphicsExecutable' \
  "Swift settings model must share MapleStory executable matching"
assert_contains "$common" 'cyder_macos_at_least 15 0' \
  "shell DXMT gate must require macOS 15+"
assert_not_contains "$common" 'preference=auto' \
  "OEM must not rewrite default to auto"
assert_not_contains "$common" 'dxvk2' \
  "shell launch path must not expose the deferred DXVK 2 backend"

echo "PASS test-cyder-settings-model"
