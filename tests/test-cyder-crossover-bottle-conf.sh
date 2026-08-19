#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-common.sh
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ENGINE="$TMP/engine"
mkdir -p "$ENGINE/bin" "$ENGINE/share/crossover/bottle_data"
: >"$ENGINE/bin/wine"
cat >"$ENGINE/share/crossover/bottle_data/cxbottle.conf" <<'EOF'
;; template
[Bottle]
;;"Template" = ""

[EnvironmentVariables]
;;"PROMPT" = "$p$g"
EOF

BOTTLE="$TMP/bottle"
unset CYDER_OEM_FLAVOR CYDER_ENGINE_NAME CYDER_BOTTLE_NAME
cyder_seed_crossover_bottle_conf "$ENGINE/bin/wine" "$BOTTLE"
assert test -r "$BOTTLE/cxbottle.conf"
conf="$(cat "$BOTTLE/cxbottle.conf")"
assert_contains "$conf" '"WineArch" = "win64"' "WineArch should be injected"
assert_contains "$conf" '"Template" = "win10_64"' "Template should be injected"
if [[ "$conf" == *'"RAW_AUDIO_PARSE" = "1"'* ]]; then
  echo "ASSERT failed: generic CrossOver seed must not inject RAW_AUDIO_PARSE" >&2
  exit 1
fi

if type cyder_is_maplestory_oem >/dev/null 2>&1; then
  echo "ASSERT failed: cyder_is_maplestory_oem must be removed" >&2
  exit 1
fi

# Existing conf is left alone.
printf 'keep-me\n' >"$BOTTLE/cxbottle.conf"
cyder_seed_crossover_bottle_conf "$ENGINE/bin/wine" "$BOTTLE"
assert_eq "$(cat "$BOTTLE/cxbottle.conf")" "keep-me" \
  "existing cxbottle.conf must not be overwritten"

# Repair: bottle with system.reg but no conf still gets seeded.
REPAIR="$TMP/repair-bottle"
mkdir -p "$REPAIR"
: >"$REPAIR/system.reg"
cyder_seed_crossover_bottle_conf "$ENGINE/bin/wine" "$REPAIR"
assert test -r "$REPAIR/cxbottle.conf"
if [[ "$(cat "$REPAIR/cxbottle.conf")" == *'"RAW_AUDIO_PARSE" = "1"'* ]]; then
  echo "ASSERT failed: generic repair seed must not inject RAW_AUDIO_PARSE" >&2
  exit 1
fi

# Retail engines without bottle_data are a no-op.
RETAIL="$TMP/retail"
mkdir -p "$RETAIL/bin" "$TMP/retail-bottle"
: >"$RETAIL/bin/wine"
cyder_seed_crossover_bottle_conf "$RETAIL/bin/wine" "$TMP/retail-bottle"
assert test ! -e "$TMP/retail-bottle/cxbottle.conf"

# Frontend flags belong only to the CrossOver Perl launcher or an explicit
# OEM override. Do not infer them from a retail Wine --help response.
cat >"$RETAIL/bin/wine" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
  echo "supports --wait-children"
fi
SH
chmod +x "$RETAIL/bin/wine"
unset CYDER_WINE_FRONTEND_ARGS
assert_eq "$(cyder_wine_frontend_args "$RETAIL/bin/wine")" "" \
  "retail Wine must not receive CrossOver frontend flags"

export CYDER_WINE_FRONTEND_ARGS='--wait-children --enable-alt-loader macdrv'
assert_contains "$(cyder_wine_frontend_args "$ENGINE/bin/wine" 'd3d11,dxgi=n,b')" \
  '--dll d3d11,dxgi=n,b --wait-children --enable-alt-loader macdrv' \
  "CrossOver frontend args must prepend --dll overrides"
unset CYDER_WINE_FRONTEND_ARGS CYDER_WINE_DLL_OVERRIDES

# Saved settings should control DXVK frametimes in the shell launcher path.
# Stub engine payloads so preference apply is hermetic (no host Cyder Engines).
SETTINGS_DIR="$TMP/support"
SETTINGS_ENGINE_NAME=wine-x86_64
SETTINGS_ENGINES="$TMP/settings-engines"
mkdir -p "$SETTINGS_DIR" \
  "$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxvk/x86_64-windows" \
  "$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/wine/x86_64-unix"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxvk/x86_64-windows/d3d11.dll"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxvk/x86_64-windows/dxgi.dll"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/wine/x86_64-unix/libMoltenVK.dylib"
cat >"$SETTINGS_DIR/settings.json" <<'JSON'
{
  "schemaVersion": 6,
  "graphicsBackend": "dxvk",
  "dxvkFrameRate": "sixty",
  "graphicsHud": "dxvk",
  "dxvkHudFrametimes": false
}
JSON
(
  export CYDER_SUPPORT="$SETTINGS_DIR"
  export CYDER_ENGINES="$SETTINGS_ENGINES"
  export CYDER_ENGINE_NAME="$SETTINGS_ENGINE_NAME"
  export CYDER_GRAPHICS_BACKEND=
  unset DXVK_FRAME_RATE DXVK_HUD MTL_HUD_ENABLED
  cyder_load_saved_settings
  assert_eq "$DXVK_FRAME_RATE" "60" "shell settings loader should preserve DXVK frame limit"
  assert_eq "$DXVK_HUD" "fps" "shell settings loader should allow DXVK HUD without frametimes"
)

# Legacy DXVK 2 settings are fail-safe: the shell launcher treats the removed
# backend as the default instead of passing an unknown token to Wine.
cat >"$SETTINGS_DIR/settings.json" <<'JSON'
{
  "schemaVersion": 9,
  "graphicsBackend": "dxvk2"
}
JSON
(
  export CYDER_SUPPORT="$SETTINGS_DIR"
  export CYDER_ENGINES="$SETTINGS_ENGINES"
  export CYDER_ENGINE_NAME="$SETTINGS_ENGINE_NAME"
  export CYDER_GRAPHICS_BACKEND=
  unset CYDER_GRAPHICS_PREFERENCE DXVK_FRAME_RATE DXVK_HUD MTL_HUD_ENABLED
  cyder_load_saved_settings 2>"$TMP/legacy-dxvk2.log"
  assert_eq "$CYDER_GRAPHICS_PREFERENCE" "default" "legacy DXVK 2 should migrate to default"
  assert_eq "${CYDER_GRAPHICS_BACKEND:-}" "" "legacy DXVK 2 should not reach Wine"
)

# DXVK 120/144 use the same limiter field as 60.
cat >"$SETTINGS_DIR/settings.json" <<'JSON'
{
  "schemaVersion": 9,
  "graphicsBackend": "dxvk",
  "dxvkFrameRate": "120",
  "graphicsHud": "off"
}
JSON
(
  export CYDER_SUPPORT="$SETTINGS_DIR"
  export CYDER_ENGINES="$SETTINGS_ENGINES"
  export CYDER_ENGINE_NAME="$SETTINGS_ENGINE_NAME"
  export CYDER_GRAPHICS_BACKEND=
  unset DXVK_FRAME_RATE DXVK_HUD MTL_HUD_ENABLED DXMT_CONFIG
  cyder_load_saved_settings
  assert_eq "$DXVK_FRAME_RATE" "120" "shell settings loader should apply DXVK 120 fps"
)

# Manual DXMT uses DXMT_CONFIG, not DXVK_FRAME_RATE, and merges existing keys.
mkdir -p "$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/x86_64-windows" \
  "$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/i386-windows" \
  "$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/x86_64-unix"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/x86_64-windows/d3d11.dll"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/x86_64-windows/dxgi.dll"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/x86_64-windows/winemetal.dll"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/i386-windows/d3d11.dll"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/i386-windows/dxgi.dll"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/i386-windows/winemetal.dll"
: >"$SETTINGS_ENGINES/$SETTINGS_ENGINE_NAME/lib/dxmt/x86_64-unix/winemetal.so"
cat >"$SETTINGS_DIR/settings.json" <<'JSON'
{
  "schemaVersion": 9,
  "graphicsBackend": "dxmt",
  "dxvkFrameRate": "144",
  "graphicsHud": "off"
}
JSON
(
  export CYDER_SUPPORT="$SETTINGS_DIR"
  export CYDER_ENGINES="$SETTINGS_ENGINES"
  export CYDER_ENGINE_NAME="$SETTINGS_ENGINE_NAME"
  export CYDER_GRAPHICS_BACKEND=
  export DXMT_CONFIG="dxgi.forceSDR=True;"
  unset DXVK_FRAME_RATE DXVK_HUD MTL_HUD_ENABLED
  cyder_macos_at_least() { return 0; }
  cyder_load_saved_settings
  assert_eq "$CYDER_GRAPHICS_BACKEND" "dxmt" "shell settings loader should retain dxmt backend"
  assert_eq "${DXVK_FRAME_RATE:-}" "" "DXMT must not set DXVK_FRAME_RATE"
  assert_eq "$DXMT_CONFIG" "dxgi.forceSDR=True;d3d11.preferredMaxFrameRate=144;" \
    "shell should merge DXMT frame rate into existing DXMT_CONFIG"
)

# Metal HUD is independent of a manual DXVK selection. In particular, the
# generic "default" backend leaves CompatDB in charge but must still inject the
# user's Metal HUD request.
cat >"$SETTINGS_DIR/settings.json" <<'JSON'
{
  "schemaVersion": 7,
  "graphicsBackend": "default",
  "dxvkFrameRate": "unlimited",
  "graphicsHud": "metal",
  "dxvkHudFrametimes": false
}
JSON
(
  export CYDER_SUPPORT="$SETTINGS_DIR"
  export CYDER_ENGINES="$SETTINGS_ENGINES"
  export CYDER_ENGINE_NAME="$SETTINGS_ENGINE_NAME"
  export CYDER_GRAPHICS_BACKEND=
  unset CYDER_GRAPHICS_PREFERENCE DXVK_FRAME_RATE DXVK_HUD MTL_HUD_ENABLED
  cyder_load_saved_settings
  assert_eq "$CYDER_GRAPHICS_PREFERENCE" "default" "shell loader should retain the saved preference"
  assert_eq "$MTL_HUD_ENABLED" "1" "Metal HUD should apply with the default backend"
  assert_eq "$DXVK_HUD" "0" "Metal HUD should disable the DXVK HUD"
)

# Engine / bottle name overrides stay under the shared roots.
(
  export CYDER_ENGINE_NAME=custom-engine
  export CYDER_BOTTLE_NAME=custom-bottle
  export CYDER_SUPPORT="$TMP/cyder-support"
  unset CYDER_PREFIX CYDER_SHARED_PREFIX CYDER_OEM_FLAVOR
  # shellcheck source=../scripts/cyder-common.sh
  source "$ROOT/scripts/cyder-common.sh"
  cyder_init_paths "$ROOT/scripts"
  assert_eq "$CYDER_ENGINE_NAME" "custom-engine" "engine name override"
  assert_eq "$CYDER_PREFIX" \
    "$TMP/cyder-support/bottles/custom-bottle" \
    "prefix path uses CYDER_BOTTLE_NAME"
  assert_eq "$CYDER_SHARED_PREFIX" \
    "$TMP/cyder-support/bottles/custom-bottle" \
    "shared prefix remains a compatibility alias"
)

echo "PASS test-cyder-crossover-bottle-conf"
