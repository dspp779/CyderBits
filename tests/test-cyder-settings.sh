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
assert_contains "$output" "reg delete HKCU\\Software\\Wine\\Mac Driver /v RetinaMode /f" "Retina off should remove the override"
if [[ "$output" == *"RetinaMode /t REG_SZ /d n"* ]]; then
  echo "ASSERT failed: Retina off must not write RetinaMode=n" >&2
  exit 1
fi
assert_contains "$output" "LogPixels /t REG_DWORD /d 144" "selected DPI should be applied"
assert_contains "$output" "FontSmoothingType /t REG_DWORD /d 1" "grayscale smoothing should be applied"
assert_contains "$output" "reg delete HKCU\\Software\\Wine\\DllOverrides /v ddraw" "old global DirectDraw override should be removed"
assert_contains "$output" "reg delete HKCU\\Software\\Wine\\AppDefaults\\BlueLauncher.exe\\DllOverrides /v ddraw" "old BlueLauncher override should be removed"
assert_contains "$output" "AppDefaults\\bluecg.exe\\DllOverrides /v ddraw /t REG_SZ /d native,builtin" "bluecg.exe should receive its own DirectDraw override"
assert_contains "$output" "reg delete HKCU\\Software\\Wine\\Fonts\\Replacements /v MingLiU" "MingLiU should resolve an installed font"
assert_contains "$output" "PMingLiU /t REG_SZ /d MingLiU" "font aliases should use MingLiU"

# Re-confirming identical settings must not issue any registry commands.
: >"$CYDER_TEST_WINE_LOG"
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
if [[ -s "$CYDER_TEST_WINE_LOG" ]]; then
  echo "ASSERT failed: unchanged settings should not rewrite the registry" >&2
  cat "$CYDER_TEST_WINE_LOG" >&2
  exit 1
fi

# CYDER_FORCE_SETTINGS remains an explicit escape hatch for repairing a
# damaged prefix or re-running migration operations.
: >"$CYDER_TEST_WINE_LOG"
export CYDER_FORCE_SETTINGS=1
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
unset CYDER_FORCE_SETTINGS
assert_contains "$(cat "$CYDER_TEST_WINE_LOG")" "AppDefaults\\bluecg.exe\\DllOverrides /v ddraw" "forced apply should rewrite registry values"

: >"$CYDER_TEST_WINE_LOG"
rm -f "$TMP/prefix/.cyder-settings-applied.tsv"
unset CYDER_RETINA_MODE CYDER_DPI CYDER_FONT_PRESET CYDER_FONT_SMOOTHING
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
defaults="$(cat "$CYDER_TEST_WINE_LOG")"
assert_contains "$defaults" "RetinaMode /t REG_SZ /d y" "Retina should default on"
assert_contains "$defaults" "LogPixels /t REG_DWORD /d 192" "DPI should default to 192"
assert_contains "$defaults" "FontSmoothing /t REG_SZ /d 2" "font antialiasing should default on"
assert_contains "$defaults" "FontSmoothingType /t REG_DWORD /d 1" "font smoothing should default to grayscale"
assert_contains "$defaults" "AppDefaults\\bluecg.exe\\DllOverrides /v ddraw /t REG_SZ /d native,builtin" "bluecg.exe DirectDraw override should always be applied"

# Retina off is represented as deletion in the ledger.  Changing from the
# default-on state applies the deletion once; a second off apply is a no-op.
: >"$CYDER_TEST_WINE_LOG"
export CYDER_RETINA_MODE=0
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
assert_contains "$(cat "$CYDER_TEST_WINE_LOG")" "reg delete HKCU\\Software\\Wine\\Mac Driver /v RetinaMode /f" "changing Retina off should delete the override"
: >"$CYDER_TEST_WINE_LOG"
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
if [[ -s "$CYDER_TEST_WINE_LOG" ]]; then
  echo "ASSERT failed: unchanged Retina-off settings should not rewrite the registry" >&2
  cat "$CYDER_TEST_WINE_LOG" >&2
  exit 1
fi

echo "PASS test-cyder-settings"
