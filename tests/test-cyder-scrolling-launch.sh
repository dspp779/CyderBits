#!/usr/bin/env bash
# Offline settings resolution and final-launch ordering; no Wine or user bottle.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CYDER_SUPPORT="$TMP/support" CYDER_RUNTIME_ROOT="$TMP/runtime"
export CYDER_ENGINES="$TMP/runtime/Engines" CYDER_ENGINE_NAME=fixture
export CYDER_SCRIPTS="$ROOT/scripts"
mkdir -p "$CYDER_SUPPORT" "$TMP/game space" "$TMP/engine/bin" "$TMP/prefix" "$TMP/helper"
touch "$TMP/game space/MapleStory.exe" "$TMP/game space/OtherGame.exe" "$TMP/engine/bin/wine"
export CYDER_SCROLL_TEST_EVENTS="$TMP/events"
source "$ROOT/scripts/cyder-common.sh"
cyder_launch_settings_path() { printf '%s\n' "$CYDER_SUPPORT/settings.json"; }
profile_id="$(bash "$ROOT/scripts/cyder-profile.sh" id "$TMP/game space/MapleStory.exe")"
# Missing settings must use off/N even in the legacy shell launch path.
unset CYDER_SCROLLING_PREFERENCE
cyder_load_saved_settings
assert_eq "$CYDER_SCROLLING_PREFERENCE" traditional "Missing global preference must default to N"
# Read persisted global/per-profile settings through the real CLI readers.
for global in unmanaged traditional precise; do
  for game in inherit unmanaged traditional precise; do
    /usr/bin/ruby -rjson -e '
      file, global, game, id = ARGV
      rule = game == "inherit" ? {} : {"scrolling" => game}
      rule["environment"] = {"CYDER_SCROLLING_PREFERENCE" => "injected"}
      File.write(file, JSON.generate("schemaVersion" => 14, "scrolling" => global, "perProfile" => {id => rule}))
    ' "$CYDER_SUPPORT/settings.json" "$global" "$game" "$profile_id"
    unset CYDER_SCROLLING_PREFERENCE
    cyder_load_saved_settings
    cyder_load_game_settings "$TMP/game space/MapleStory.exe" "$TMP/engine"
    expected="$game"; [[ "$game" == inherit ]] && expected="$global"
    [[ "$game" == inherit && "$global" == unmanaged ]] && expected=traditional
    assert_eq "$CYDER_SCROLLING_PREFERENCE" "$expected" 'Profile choice must override global and resist custom env injection'
  done
done
# Accepted native launch requests are authoritative over saved global defaults.
export CYDER_SCROLLING_PREFERENCE=unmanaged
cyder_load_saved_settings
assert_eq "$CYDER_SCROLLING_PREFERENCE" unmanaged 'Native opt-out must survive global reload'

cat >"$TMP/helper/cyder-scrolling.rb" <<'RUBY'
File.open(ENV.fetch('CYDER_SCROLL_TEST_EVENTS'), 'a') do |f|
  f.puts [ARGV.join('|'), ENV['WINEPREFIX'], ENV['WINEMSYNC'], ENV['WINEESYNC'], ENV['CYDER_EXECUTION_FINAL']].join(';')
end
exit(ENV.fetch('CYDER_SCROLL_TEST_FAIL', '0').to_i)
RUBY
export CYDER_SCRIPTS="$TMP/helper"
# With default/unmanaged and no backup directories there is no helper work.
export CYDER_SCROLLING_PREFERENCE=unmanaged
cyder_apply_scrolling_for_exe "$TMP/engine/bin/wine" "$TMP/prefix" "$TMP/game space/MapleStory.exe"
assert test ! -e "$CYDER_SCROLL_TEST_EVENTS"
# Stub only external runtime services. Exercise the real final game dispatcher.
cyder_configure_compatdb() { :; }
cyder_apply_moltenvk_os_floor() { :; }
cyder_apply_moltenvk_variant_from_preference() { :; }
cyder_apply_gptk_launch_environment() { :; }
cyder_validate_moltenvk_for_backend() { :; }
cyder_wine_is_crossover_frontend() { return 1; }
cyder_wine_locale_exports() { :; }
cyder_exec_wine() { printf 'game;%s;%s\n' "$CYDER_EXECUTION_FINAL" "${WINEMSYNC:-}" >>"$CYDER_SCROLL_TEST_EVENTS"; }
export CYDER_CAPTURE_WINE_LOG=0 CYDER_WINE_DIAGNOSTICS=quiet CYDER_SESSION_GUARD=0
export CYDER_MSYNC=1 CYDER_ESYNC=0 CYDER_WINE_DETACH=0
export CYDER_SCROLLING_PREFERENCE=traditional
cyder_run_wine_exe "$TMP/engine/bin/wine" "$TMP/game space/MapleStory.exe" "$TMP/prefix"
actual="$(cat "$CYDER_SCROLL_TEST_EVENTS")"
assert_eq "$(printf '%s\n' "$actual" | head -1)" "traditional|MapleStory.exe;$TMP/prefix;1;;0" 'Scrolling must run under the chosen sync mode before native final handoff'
assert_eq "$(printf '%s\n' "$actual" | tail -1)" 'game;1;1' 'Final launch must follow registry preparation'
# Restore is only attempted when a Cyder baseline might exist in this prefix.
mkdir -p "$TMP/prefix/.cyder-maplestory-scrolling"
: >"$CYDER_SCROLL_TEST_EVENTS"
export CYDER_SCROLLING_PREFERENCE=unmanaged
cyder_run_wine_exe "$TMP/engine/bin/wine" "$TMP/game space/MapleStory.exe" "$TMP/prefix"
assert_contains "$(cat "$CYDER_SCROLL_TEST_EVENTS")" 'restore|MapleStory.exe' 'Opt-out must restore on next launch'
# A failed write must prevent the game from launching.
: >"$CYDER_SCROLL_TEST_EVENTS"
export CYDER_SCROLL_TEST_FAIL=9 CYDER_SCROLLING_PREFERENCE=precise
if cyder_run_wine_exe "$TMP/engine/bin/wine" "$TMP/game space/MapleStory.exe" "$TMP/prefix"; then
  echo 'ASSERT failed: scrolling failure allowed game launch' >&2; exit 1
fi
assert_not_contains "$(cat "$CYDER_SCROLL_TEST_EVENTS")" 'game;' 'Failed scrolling update must block final handoff'
unset CYDER_SCROLL_TEST_FAIL
# MSI, registry imports and unresolved link/script targets must not get an
# invented EXE registry key. Existing persisted EXE settings are left intact.
for kind in msi reg link script; do
  : >"$CYDER_SCROLL_TEST_EVENTS"
  CYDER_LAUNCH_TARGET_KIND="$kind" cyder_run_wine_exe "$TMP/engine/bin/wine" "$TMP/game space/OtherGame.exe" "$TMP/prefix"
  assert_not_contains "$(cat "$CYDER_SCROLL_TEST_EVENTS")" 'precise|' 'Only resolved EXE launches can apply scrolling'
done
assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" 'cp "$SCRIPT_DIR/cyder-scrolling.rb" "$RES/ogom-scripts/"' 'App must bundle generic scrolling tool'
echo 'PASS test-cyder-scrolling-launch (12 resolution cases, final launch ordering, opt-out, failure, non-EXE guards; no Wine)'
