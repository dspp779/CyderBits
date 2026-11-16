#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

result="$(
  bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_compatibility_arguments "/games/Steam.EXE" "-silent"
    printf "<%s>\n" "${CYDER_STEAM_ARGUMENTS[@]}"
  ' _ "$ROOT"
)"
assert_eq "$result" $'<-silent>\n<-system-composer>\n<-no-cef-sandbox>' \
  "Steam should receive the macOS compositor compatibility arguments"

no_args="$(
  bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_compatibility_arguments "/games/steam.exe"
    printf "<%s>\n" "${CYDER_STEAM_ARGUMENTS[@]}"
  ' _ "$ROOT"
)"
assert_eq "$no_args" $'<-system-composer>\n<-no-cef-sandbox>' \
  "Steam with no argv should still get compositor args under bash 3.2 set -u"

deduplicated="$(
  bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_compatibility_arguments \
      "/games/steam.exe" "-system-composer" "-no-cef-sandbox"
    printf "<%s>\n" "${CYDER_STEAM_ARGUMENTS[@]}"
  ' _ "$ROOT"
)"
assert_eq "$deduplicated" $'<-system-composer>\n<-no-cef-sandbox>' \
  "Steam compatibility arguments should not be duplicated"

opted_out="$(
  CYDER_STEAM_COMPAT=0 bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_compatibility_arguments "/games/steam.exe" "-silent"
    printf "<%s>\n" "${CYDER_STEAM_ARGUMENTS[@]}"
  ' _ "$ROOT"
)"
assert_eq "$opted_out" '<-silent>' \
  "CYDER_STEAM_COMPAT=0 should preserve the requested Steam arguments"

non_steam="$(
  bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_compatibility_arguments "/games/game.exe" "-windowed"
    printf "<%s>\n" "${CYDER_STEAM_ARGUMENTS[@]}"
  ' _ "$ROOT"
)"
assert_eq "$non_steam" '<-windowed>' \
  "non-Steam applications should not receive Steam compatibility arguments"

cs2_env="$(
  env -u SteamAppId -u SteamGameId -u SteamOverlayGameId bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_game_environment "/games/Cities Skylines II/CITIES2.EXE"
    printf "<%s|%s|%s>" "${SteamAppId:-}" "${SteamGameId:-}" "${SteamOverlayGameId:-}"
  ' _ "$ROOT"
)"
assert_eq "$cs2_env" '<949230|949230|949230>' \
  "Cities2.exe started directly should get its Steam app ID"

cs2_user_value="$(
  SteamAppId=123 bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_game_environment "/games/Cities2.exe"
    printf "<%s|%s>" "$SteamAppId" "$SteamGameId"
  ' _ "$ROOT"
)"
assert_eq "$cs2_user_value" '<123|949230>' \
  "a Steam app ID the user already set should be kept"

other_game_env="$(
  env -u SteamAppId bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_game_environment "/games/Cities.exe"
    printf "<%s>" "${SteamAppId:-}"
  ' _ "$ROOT"
)"
assert_eq "$other_game_env" '<>' \
  "other executables (including the first Cities: Skylines) should not get an app ID"

cs2_opted_out="$(
  env -u SteamAppId CYDER_STEAM_COMPAT=0 bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_game_environment "/games/Cities2.exe"
    printf "<%s>" "${SteamAppId:-}"
  ' _ "$ROOT"
)"
assert_eq "$cs2_opted_out" '<>' \
  "CYDER_STEAM_COMPAT=0 should also turn off the Steam app ID"

# Run-time lookup from Steam's appmanifest, in a fake Steam library.
STEAM_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-steam-appid.XXXXXX")"
trap 'rm -rf "$STEAM_TMP"' EXIT
apps="$STEAM_TMP/Program Files (x86)/Steam/steamapps"
mkdir -p "$apps/common/Some Game/bin/x64" "$apps/common/No Manifest" "$apps/common/Cities Skylines II"
printf '"AppState"\n{\n\t"appid"\t\t"4242"\n\t"name"\t\t"Some Game"\n\t"installdir"\t\t"Some Game"\n\t"SharedDepots"\n\t{\n\t\t"228989"\t\t"228980"\n\t}\n}\n' \
  > "$apps/appmanifest_4242.acf"
printf '"AppState"\n{\n\t"appid"\t\t"777"\n\t"installdir"\t\t"Other Game"\n}\n' > "$apps/appmanifest_777.acf"

lookup() {
  env -u SteamAppId -u SteamGameId -u SteamOverlayGameId bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_apply_steam_game_environment "$2"
    printf "<%s|%s|%s>" "${SteamAppId:-}" "${SteamGameId:-}" "${SteamOverlayGameId:-}"
  ' _ "$ROOT" "$1"
}
assert_eq "$(lookup "$apps/common/Some Game/bin/x64/game.exe")" '<4242|4242|4242>' \
  "a Steam game in a subfolder should get the app ID from its appmanifest"
assert_eq "$(lookup "$apps/common/some game/Launcher.exe")" '<4242|4242|4242>' \
  "the installdir match should ignore case"
assert_eq "$(lookup "$apps/common/No Manifest/game.exe")" '<||>' \
  "a folder with no matching appmanifest should get no app ID"
assert_eq "$(lookup "$apps/common/Cities Skylines II/Cities2.exe")" '<949230|949230|949230>' \
  "Cities2.exe should fall back to its known app ID without a manifest"
assert_eq "$(lookup "$STEAM_TMP/Program Files (x86)/Steam/steam.exe")" '<||>' \
  "programs outside steamapps/common should get no app ID"
printf '"AppState"\n{\n\t"appid"\t\t"1"\n\t"installdir"\t\t"Cities Skylines II"\n}\n' > "$apps/appmanifest_1.acf"
assert_eq "$(lookup "$apps/common/Cities Skylines II/Cities2.exe")" '<1|1|1>' \
  "the appmanifest should win over the built-in table"

common="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_contains "$common" 'cyder_apply_steam_game_environment "$exe"' \
  "the Bash Wine launch path should apply the Steam game environment"
assert_contains "$common" 'cyder_apply_steam_compatibility_arguments "$exe"' \
  "the Bash Wine launch path should apply the Steam compatibility profile"
assert_contains "$common" 'for required in -system-composer -no-cef-sandbox' \
  "the Bash launch path should own the verified Steam compatibility arguments"

rules="$(cat "$ROOT/compatdb/rules/steam.yml")"
assert_contains "$rules" "path_suffix: '\\steamwebhelper.exe'" \
  "CompatDB data should target Steam WebHelper"
assert_contains "$rules" "'--no-sandbox'" \
  "CompatDB should append the verified CrossOver Chromium arguments"

build_wine="$(cat "$ROOT/scripts/build-wine.sh")"
assert_not_contains "$build_wine" 'cyder-compatdb-runtime.patch' \
  "app-side Wine builds should leave the original CrossOver ntdll unchanged"

echo "PASS test-cyder-steam-compat"
