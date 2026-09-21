#!/usr/bin/env bash
# Formal Bash settings readers with inert files; this test never runs Wine.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/support/launch-requests" "$TMP/game"
touch "$TMP/game/test.exe"
export CYDER_SUPPORT="$TMP/support" CYDER_SCRIPTS="$ROOT/scripts"
PROFILE="$(bash "$ROOT/scripts/cyder-profile.sh" id "$TMP/game/test.exe")"
export CYDER_WINE_SETTINGS_SNAPSHOT="$TMP/support/launch-requests/accepted.json"
python3 - "$PROFILE" "$CYDER_WINE_SETTINGS_SNAPSHOT" "$CYDER_SUPPORT/settings.json" <<'PY'
import json, sys
profile, snapshot, live = sys.argv[1:]
for path, dpi, argument in [(snapshot, 144, '--accepted'), (live, 192, '--later')]:
    environment = {key: 'invalid-override' for key in
                   ['CYDER_EXECUTION_OWNER_ROOT', 'CYDER_EXECUTION_OWNER_TICKET',
                    'CYDER_EXECUTION_OWNER_HELPER', 'CYDER_EXECUTION_FINAL']}
    environment['GAME_CUSTOM_VALUE'] = 'normal-value'
    environment['CYDER_MOLTENVK_VARIANT_PREFERENCE'] = '1.4.2'
    with open(path, 'w') as f:
        json.dump({'schemaVersion': 13, 'dpi': dpi, 'retinaMode': False, 'graphicsBackend': 'default',
                   'moltenvkVariant': '1.2.10' if argument == '--accepted' else '1.4.2',
                   'perProfile': {profile: {'arguments': [argument, 'two words'], 'dpi': dpi,
                                           'environment': environment}}}, f)
PY
(
  source "$ROOT/scripts/cyder-common.sh"
  unset CYDER_DPI CYDER_RETINA_MODE CYDER_MOLTENVK_VARIANT_PREFERENCE || true
  cyder_load_saved_settings
  [[ "$CYDER_DPI" == 144 && "$CYDER_RETINA_MODE" == 0 ]]
  export CYDER_EXECUTION_OWNER_ROOT=authorized-root CYDER_EXECUTION_OWNER_TICKET=authorized-ticket
  export CYDER_EXECUTION_OWNER_HELPER=authorized-helper CYDER_EXECUTION_FINAL=1
  cyder_load_game_settings "$TMP/game/test.exe" "$TMP/engine"
  [[ "$CYDER_EXECUTION_OWNER_ROOT" == authorized-root && "$CYDER_EXECUTION_OWNER_TICKET" == authorized-ticket ]]
  [[ "$CYDER_EXECUTION_OWNER_HELPER" == authorized-helper && "$CYDER_EXECUTION_FINAL" == 1 ]]
  [[ "$GAME_CUSTOM_VALUE" == normal-value ]]
  [[ "$CYDER_MOLTENVK_VARIANT_PREFERENCE" == 1.2.10 ]]
  [[ "$CYDER_DPI" == 144 && "${#CYDER_GAME_ARGUMENTS[@]}" == 2 ]]
  [[ "${CYDER_GAME_ARGUMENTS[0]}" == --accepted && "${CYDER_GAME_ARGUMENTS[1]}" == 'two words' ]]
  # Explicit test-launch overrides still win, without changing the saved copy.
  export CYDER_TEST_SETTINGS_REQUEST="$CYDER_SUPPORT/launch-requests/override.json"
  printf '%s\n' '{"dpi":168,"arguments":["--explicit"]}' > "$CYDER_TEST_SETTINGS_REQUEST"
  cyder_load_game_settings "$TMP/game/test.exe" "$TMP/engine"
  [[ "$CYDER_DPI" == 168 && "${CYDER_GAME_ARGUMENTS[0]}" == --explicit ]]
)
(
  source "$ROOT/scripts/cyder-common.sh"
  unset CYDER_WINE_SETTINGS_SNAPSHOT CYDER_DPI CYDER_RETINA_MODE || true
  cyder_load_saved_settings
  [[ "$CYDER_DPI" == 192 ]]
  cyder_load_game_settings "$TMP/game/test.exe" "$TMP/engine"
  [[ "${CYDER_GAME_ARGUMENTS[0]}" == --later ]]
)
rm "$CYDER_WINE_SETTINGS_SNAPSHOT"
(
  source "$ROOT/scripts/cyder-common.sh"
  if cyder_load_saved_settings; then echo 'Missing snapshot silently fell back' >&2; exit 1; fi
  if cyder_load_game_settings "$TMP/game/test.exe"; then echo 'Missing game snapshot silently fell back' >&2; exit 1; fi
  # Propagate failure before a registry/environment mutation can start.
  cyder_apply_maplestory_wz_cache() { touch "$TMP/unexpected-mutation"; }
  if cyder_prepare_game_launch_settings inert inert inert "$TMP/game/test.exe"; then exit 1; fi
  [[ ! -e "$TMP/unexpected-mutation" ]]
  printf 'corrupt\n' > "$CYDER_WINE_SETTINGS_SNAPSHOT"
  if cyder_load_saved_settings; then exit 1; fi
  rm "$CYDER_WINE_SETTINGS_SNAPSHOT"
  ln -s "$CYDER_SUPPORT/settings.json" "$CYDER_WINE_SETTINGS_SNAPSHOT"
  if cyder_load_saved_settings; then exit 1; fi
)
printf '%s\n' 'PASS saved settings snapshot: global/per-game frozen, explicit override, CLI fallback, missing/corrupt/symlink fail closed (no Wine)'
