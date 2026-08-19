#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RESOLVE="$ROOT/scripts/resolve-wine-locale.sh"

# Preference wins over an inherited LC_ALL from the parent process.
got="$(
  env -i PATH="$PATH" HOME="$HOME" \
    CYDER_WINE_LOCALE=zh_TW.UTF-8 LC_ALL=en_US.UTF-8 LANG=C.UTF-8 \
    bash "$RESOLVE"
)"
assert_eq "$got" "zh_TW.UTF-8" "CYDER_WINE_LOCALE must win over LC_ALL"

got="$(
  env -i PATH="$PATH" HOME="$HOME" \
    CYDER_WINE_LOCALE=ja_JP LC_ALL=zh_TW.UTF-8 \
    bash "$RESOLVE"
)"
assert_eq "$got" "ja_JP.UTF-8" "short CYDER_WINE_LOCALE ids should expand to UTF-8 locales"

got="$(
  env -i PATH="$PATH" HOME="$HOME" \
    CYDER_WINE_LOCALE=system LC_ALL=en_US.UTF-8 \
    bash "$RESOLVE"
)"
assert_eq "$got" "en_US.UTF-8" "system preference should fall through to LC_ALL"

got="$(
  env -i PATH="$PATH" HOME="$HOME" \
    CYDER_WINE_LOCALE=bogus LC_ALL=ko_KR.UTF-8 \
    bash "$RESOLVE"
)"
assert_eq "$got" "ko_KR.UTF-8" "unknown CYDER_WINE_LOCALE should fall through"

got="$(
  env -i PATH="$PATH" HOME="$HOME" \
    LC_ALL=C.UTF-8 LANG=C CYDER_WINE_LOCALE_FALLBACK=zh_TW.UTF-8 \
    bash "$RESOLVE"
)"
assert_eq "$got" "zh_TW.UTF-8" "C.UTF-8 should not be treated as a Wine locale"

mkdir -p "$TMP/support"
printf '%s\n' '{"schemaVersion":12,"wineLocale":"en_US"}' >"$TMP/support/settings.json"
loaded="$(
  env -i PATH="$PATH" HOME="$HOME" \
    bash -c '
      source "$1/scripts/cyder-common.sh"
      CYDER_SUPPORT="$2/support"
      CYDER_GRAPHICS_BACKEND=wined3d
      cyder_load_saved_settings
      bash "$1/scripts/resolve-wine-locale.sh"
    ' _ "$ROOT" "$TMP"
)"
assert_eq "$loaded" "en_US.UTF-8" "settings.json wineLocale should reach Wine as a Unix locale"

echo "PASS test-resolve-wine-locale"
