#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/support/bottles/shared" "$TMP/game" "$TMP/engine/bin" "$TMP/scripts"
exe="$TMP/game/測試.exe"
touch "$exe" "$TMP/support/bottles/shared/user.reg"
cp "$ROOT/scripts/cyder-profile.sh" "$TMP/scripts/cyder-profile.sh"

profile_id="$(bash "$TMP/scripts/cyder-profile.sh" id "$exe")"
/usr/bin/ruby -rjson -e '
  output = ARGV.fetch(0)
  id = ARGV.fetch(1)
  rule = {
    "msync" => false,
    "esync" => true,
    "retinaMode" => false,
    "dpi" => 96,
    "fontPreset" => "mingliu",
    "fontSmoothing" => "grayscale",
    "powerMode" => "energySaving",
    "graphicsBackend" => "d3dmetal",
    "dxvkFrameRate" => "unlimited",
    "environment" => {"TEST_GAME_SETTING" => "yes"},
    "arguments" => ["--windowed", "two words"]
  }
  document = {"schemaVersion" => 4, "perProfile" => {id => rule}}
  File.write(output, JSON.pretty_generate(document))
' "$TMP/support/settings.json" "$profile_id"

cat >"$TMP/scripts/cyder-edit-user-reg.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s|%s|%s|%s|%s|%s\n' \
  "${CYDER_MSYNC:-}" "${CYDER_ESYNC:-}" "${CYDER_RETINA_MODE:-}" \
  "${CYDER_DPI:-}" "${CYDER_FONT_PRESET:-}" "${CYDER_FONT_SMOOTHING:-}" \
  "${CYDER_POWER_MODE:-}" >"$CYDER_TEST_SETTINGS_LOG"
SH
chmod +x "$TMP/scripts/cyder-edit-user-reg.sh"
cat >"$TMP/scripts/cyder-apply-settings.sh" <<'SH'
#!/usr/bin/env bash
exit 99
SH
chmod +x "$TMP/scripts/cyder-apply-settings.sh"
cat >"$TMP/engine/bin/wineserver" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${WINEPREFIX:-}" "$*" >>"$CYDER_TEST_WINESERVER_LOG"
SH
chmod +x "$TMP/engine/bin/wineserver"

CYDER_SUPPORT="$TMP/support" \
CYDER_SCRIPTS="$TMP/scripts" \
CYDER_TEST_SETTINGS_LOG="$TMP/settings.log" \
CYDER_TEST_WINESERVER_LOG="$TMP/wineserver.log" \
  bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_init_paths "$1"
    CYDER_SUPPORT="$2/support"
    CYDER_SCRIPTS="$2/scripts"
    CYDER_SHARED_PREFIX="$2/support/bottles/shared"
    cyder_prepare_game_launch_settings "$2/engine/bin/wine" "$2/engine" "$CYDER_SHARED_PREFIX" "$3"
    printf "%s|%s|%s\n" "$CYDER_GAME_SETTINGS_FOUND" "${CYDER_GAME_ARGUMENTS[0]}" "${CYDER_GAME_ARGUMENTS[1]}"
  ' _ "$ROOT" "$TMP" "$exe" >"$TMP/result.log"

result="$(cat "$TMP/result.log")"
assert_eq "$result" "1|--windowed|two words" "game settings should be loaded by stable EXE ID"
assert_eq "$(cat "$TMP/settings.log")" "0|1|0|96|mingliu|grayscale|background" \
  "fast registry settings should receive per-game values"
assert_contains "$(cat "$TMP/wineserver.log")" "$TMP/support/bottles/shared|-k" \
  "per-game settings should stop the shared wineserver after editing"

# Native Cyder passes a complete per-game environment into the shell launcher.
# Those explicit values must win over the global settings.json loaded at shell
# startup, otherwise a saved Retina-off/DPI-96 rule silently becomes 1/192.
override_result="$(
  CYDER_SUPPORT="$TMP/support" CYDER_RETINA_MODE=0 CYDER_DPI=96 \
    CYDER_MSYNC=0 CYDER_ESYNC=1 CYDER_FONT_PRESET=mingliu \
    CYDER_FONT_SMOOTHING=grayscale CYDER_POWER_MODE=background \
    bash -c '
      source "$1/scripts/cyder-common.sh"
      cyder_load_saved_settings
      printf "%s|%s|%s|%s|%s|%s|%s" \
        "$CYDER_MSYNC" "$CYDER_ESYNC" "$CYDER_RETINA_MODE" "$CYDER_DPI" \
        "$CYDER_FONT_PRESET" "$CYDER_FONT_SMOOTHING" "$CYDER_POWER_MODE"
    ' _ "$ROOT"
)"
assert_eq "$override_result" "0|1|0|96|mingliu|grayscale|background" \
  "explicit per-game environment should override global saved settings"

reserved_environment_result="$(
  bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_game_environment_key_is_allowed GAME_TOKEN
    printf "safe "
    for key in WINEPREFIX WINEDEBUG DYLD_INSERT_LIBRARIES CYDER_WINE_RESULT_FILE CYDER_SUPPORT; do
      if cyder_game_environment_key_is_allowed "$key"; then printf "bad:%s " "$key"; fi
    done
  ' _ "$ROOT"
)"
assert_eq "$reserved_environment_result" "safe " \
  "per-game environment must not override launcher transport, prefix, diagnostics, or loader keys"

# EXE launches must never attach a Wine registry client to an active prefix,
# regardless of the selected synchronization mode. Registry-backed display and
# font changes remain saved and are applied on the next inactive launch.
active_prefix_result="$(
  CYDER_SCRIPTS="$TMP/scripts" CYDER_MSYNC=0 \
    bash -c '
      source "$1/scripts/cyder-common.sh"
      cyder_has_running_prefix() { return 0; }
      cyder_apply_user_settings "$2/engine/bin/wine" "$2/engine" "$2/support/bottles/shared"
    ' _ "$ROOT" "$TMP"
)"
assert_contains "$active_prefix_result" "Skipped Cyder registry settings" \
  "every active prefix should defer EXE-launch registry settings without failing"

force_status=0
CYDER_SCRIPTS="$TMP/scripts" CYDER_FORCE_SETTINGS=1 \
  bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_has_running_prefix() { return 0; }
    cyder_apply_user_settings "$2/engine/bin/wine" "$2/engine" "$2/support/bottles/shared"
  ' _ "$ROOT" "$TMP" || force_status=$?
assert_eq "$force_status" "99" \
  "explicit Apply All Settings should remain the only Wine registry-client path"

# Bash owns the Wine environment. It must preserve the GPTK contract that the
# former Swift launch path provided and mirror graphics keys into cxbottle.conf.
gptk_root="$TMP/support/runtime/apple_gptk"
mkdir -p "$gptk_root/external/D3DMetal.framework"
printf 'gptk\n' >"$gptk_root/external/libd3dshared.dylib"
cat >"$TMP/support/bottles/shared/cxbottle.conf" <<'CONF'
[Bottle]
"WineArch" = "win64"
[EnvironmentVariables]
"CX_GRAPHICS_BACKEND" = "wined3d"
"DXVK_HUD" = "old"
[Other]
"Keep" = "yes"
CONF
gptk_environment="$TMP/gptk-environment.log"
CYDER_SUPPORT="$TMP/support" \
  bash -c '
    source "$1/scripts/cyder-common.sh"
    export CX_GRAPHICS_BACKEND=d3dmetal DXVK_HUD=0 MTL_HUD_ENABLED=1
    cyder_apply_gptk_launch_environment "$2/engine"
    cyder_sync_crossover_graphics_environment "$2/support/bottles/shared"
    printf "%s\n%s\n%s\n" "$CYDER_GPTK_ROOT" \
      "$CX_APPLEGPTK_LIBD3DSHARED_PATH" "$DYLD_FRAMEWORK_PATH"
  ' _ "$ROOT" "$TMP" >"$gptk_environment"
assert_contains "$(cat "$gptk_environment")" "$gptk_root" \
  "Bash launch environment should discover Cyder-installed GPTK"
assert test -L "$TMP/engine/lib64/apple_gptk"
crossover_conf="$(cat "$TMP/support/bottles/shared/cxbottle.conf")"
assert_contains "$crossover_conf" '"CX_GRAPHICS_BACKEND" = "d3dmetal"' \
  "CrossOver bottle metadata should receive the selected backend"
assert_contains "$crossover_conf" '"MTL_HUD_ENABLED" = "1"' \
  "CrossOver bottle metadata should receive the selected HUD"
assert_not_contains "$crossover_conf" '"DXVK_HUD" = "old"' \
  "CrossOver bottle metadata should not retain stale graphics values"
auto_backend="$(
  CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_macos_at_least() { return 0; }
    export CYDER_GRAPHICS_PREFERENCE=auto
    cyder_resolve_effective_graphics_backend "$2/engine"
    printf "%s" "$CYDER_GRAPHICS_BACKEND"
  ' _ "$ROOT" "$TMP"
)"
assert_eq "$auto_backend" "d3dmetal" \
  "Bash auto graphics cascade should prefer an available GPTK on macOS 14+"

# Runtime harness: d3dmetal + fake GPTK root must emit CYDER_GPTK_ROOT,
# CX_APPLEGPTK_LIBD3DSHARED_PATH, and DYLD_FRAMEWORK_PATH containing external/.
# CX_ACTIVE_GRAPHICS_BACKEND is set by Wine apply_graphics_backend() to match
# CYDER_GRAPHICS_BACKEND (dxvk→dxvk, d3dmetal→d3dmetal); see harness comments.
WINE_ENV_BIN="$TMP/cyder-wine-environment-harness"
swiftc -O -module-cache-path "$TMP/module-cache" \
  "$ROOT/scripts/cyder_paths.swift" \
  "$ROOT/scripts/cyder_settings.swift" \
  "$ROOT/scripts/cyder_gptk.swift" \
  "$ROOT/tests/fixtures/cyder_settings_diagnostics_stub.swift" \
  "$ROOT/tests/fixtures/cyder_wine_environment_harness.swift" \
  -o "$WINE_ENV_BIN"
wine_env_result="$("$WINE_ENV_BIN" "$TMP")"
assert_contains "$wine_env_result" "PASS cyder-wine-environment-harness" \
  "wine launch environment harness should validate d3dmetal GPTK wiring"

echo "PASS test-cyder-game-launch-settings"
