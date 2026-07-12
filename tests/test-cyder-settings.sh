#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/wine/bin" "$TMP/prefix"

cat >"$TMP/bin/arch" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -x86_64 ]] && shift
exec "$@"
SH
cat >"$TMP/wine/bin/wine" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CYDER_TEST_WINE_LOG"
SH
chmod +x "$TMP/bin/arch" "$TMP/wine/bin/wine"

export PATH="$TMP/bin:$PATH"
export CYDER_TEST_WINE_LOG="$TMP/wine.log"
export WINE_INSTALL="$TMP/wine"
export WINEPREFIX="$TMP/prefix"
export CYDER_RETINA_MODE=0 CYDER_DPI=144
export CYDER_FONT_PRESET=mingliu CYDER_FONT_SMOOTHING=grayscale
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null

output="$(cat "$CYDER_TEST_WINE_LOG")"
assert_contains "$output" "RetinaMode /t REG_SZ /d n" "Retina off should be applied"
assert_contains "$output" "LogPixels /t REG_DWORD /d 144" "selected DPI should be applied"
assert_contains "$output" "FontSmoothingType /t REG_DWORD /d 1" "grayscale smoothing should be applied"
assert_contains "$output" "reg delete HKCU\\Software\\Wine\\Fonts\\Replacements /v MingLiU" "MingLiU should resolve an installed font"
assert_contains "$output" "PMingLiU /t REG_SZ /d MingLiU" "font aliases should use MingLiU"

: >"$CYDER_TEST_WINE_LOG"
unset CYDER_RETINA_MODE CYDER_DPI CYDER_FONT_PRESET CYDER_FONT_SMOOTHING
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
defaults="$(cat "$CYDER_TEST_WINE_LOG")"
assert_contains "$defaults" "RetinaMode /t REG_SZ /d n" "Retina should default off"
assert_contains "$defaults" "LogPixels /t REG_DWORD /d 96" "DPI should default to 96"
assert_contains "$defaults" "FontSmoothing /t REG_SZ /d 2" "font antialiasing should default on"
assert_contains "$defaults" "FontSmoothingType /t REG_DWORD /d 2" "font smoothing should default to ClearType"

echo "PASS test-cyder-settings"
