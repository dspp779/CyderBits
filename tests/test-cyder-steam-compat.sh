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

common="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_contains "$common" 'cyder_apply_steam_compatibility_arguments "$exe"' \
  "the Bash Wine launch path should apply the Steam compatibility profile"
assert_contains "$common" 'for required in -system-composer -no-cef-sandbox' \
  "the Bash launch path should own the verified Steam compatibility arguments"

runtime_patch="$(cat "$ROOT/patches/cyder-compatdb-runtime.patch")"
rules="$(cat "$ROOT/compatdb/rules/steam.yml")"
assert_contains "$runtime_patch" 'cyder_compat_apply_process_rules' \
  "Wine should use the generic process-creation CompatDB hook"
if [[ "$runtime_patch" == *"steamwebhelper.exe"* ]]; then
  echo "ASSERT failed: Wine runtime should not hard-code Steam WebHelper" >&2
  exit 1
fi
assert_contains "$rules" "path_suffix: '\\steamwebhelper.exe'" \
  "CompatDB data should target Steam WebHelper"
assert_contains "$rules" "'--no-sandbox'" \
  "CompatDB should append the verified CrossOver Chromium arguments"

build_wine="$(cat "$ROOT/scripts/build-wine.sh")"
assert_contains "$build_wine" 'cyder-compatdb-runtime.patch' \
  "Wine builds should apply the generic CompatDB runtime patch"

echo "PASS test-cyder-steam-compat"
