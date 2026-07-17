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
    "environment" => {"TEST_GAME_SETTING" => "yes"},
    "arguments" => ["--windowed", "two words"]
  }
  document = {"schemaVersion" => 3, "perProfile" => {id => rule}}
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

echo "PASS test-cyder-game-launch-settings"
