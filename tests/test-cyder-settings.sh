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
if [[ -n "${CYDER_TEST_WINE_FAIL_MATCH:-}" && "$*" == *"$CYDER_TEST_WINE_FAIL_MATCH"* ]]; then
  printf 'forced failure: %s\n' "$*" >>"$CYDER_TEST_WINE_LOG"
  exit 9
fi
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
assert_contains "$output" "RetinaMode /t REG_SZ /d n" "Retina off should be explicit"
assert_contains "$output" "LogPixels /t REG_DWORD /d 144" "selected DPI should be applied"
assert_contains "$output" "FontSmoothingType /t REG_DWORD /d 1" "grayscale smoothing should be applied"
assert_contains "$output" "reg copy HKCU\\Software\\Wine\\Fonts\\Replacements HKCU\\Software\\Wine\\Fonts\\Replacements(disabled) /s /f" "MingLiU should rename the replacement key"
assert_contains "$output" "HKCU\\Software\\Wine\\Fonts\\Replacements(disabled) /v MingLiU" "disabled replacements should retain their values"
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
assert_contains "$(cat "$CYDER_TEST_WINE_LOG")" "LogPixels" "forced apply should rewrite registry values"

: >"$CYDER_TEST_WINE_LOG"
rm -f "$TMP/prefix/.cyder-settings-applied.tsv"
unset CYDER_RETINA_MODE CYDER_DPI CYDER_FONT_PRESET CYDER_FONT_SMOOTHING
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
defaults="$(cat "$CYDER_TEST_WINE_LOG")"
assert_contains "$defaults" "RetinaMode /t REG_SZ /d y" "Retina should default on"
assert_contains "$defaults" "LogPixels /t REG_DWORD /d 192" "DPI should default to 192"
assert_contains "$defaults" "FontSmoothing /t REG_SZ /d 2" "font antialiasing should default on"
assert_contains "$defaults" "FontSmoothingType /t REG_DWORD /d 2" "font smoothing should default to RGB ClearType"

# A DPI-only change must not touch Retina, font, or unrelated game settings.
: >"$CYDER_TEST_WINE_LOG"
export CYDER_RETINA_MODE=1 CYDER_DPI=144 CYDER_FONT_PRESET=songti CYDER_FONT_SMOOTHING=cleartype-rgb
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
dpi_only="$(cat "$CYDER_TEST_WINE_LOG")"
assert_contains "$dpi_only" "LogPixels /t REG_DWORD /d 144" "DPI-only change should update LogPixels"
if [[ "$dpi_only" == *"RetinaMode"* || "$dpi_only" == *"FontSmoothing"* || "$dpi_only" == *"Fonts\\Replacements"* ]]; then
  echo "ASSERT failed: DPI-only change rewrote unrelated settings" >&2
  cat "$CYDER_TEST_WINE_LOG" >&2
  exit 1
fi

# A failed registry operation keeps successful fields in the ledger so retry
# only has to apply the missing field(s).
rm -f "$TMP/prefix/.cyder-settings-applied.tsv"
: >"$CYDER_TEST_WINE_LOG"
export CYDER_RETINA_MODE=1 CYDER_DPI=144 CYDER_FONT_PRESET=songti CYDER_FONT_SMOOTHING=grayscale
export CYDER_TEST_WINE_FAIL_MATCH=FontSmoothingType
if bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null 2>&1; then
  echo "ASSERT failed: forced registry failure unexpectedly succeeded" >&2
  exit 1
fi
partial_state="$(cat "$TMP/prefix/.cyder-settings-applied.tsv")"
assert_contains "$partial_state" $'dpi\t144' "partial apply should retain successful DPI"
if [[ "$partial_state" == *$'smoothing-type\t'* ]]; then
  echo "ASSERT failed: failed field was recorded as applied" >&2
  exit 1
fi
unset CYDER_TEST_WINE_FAIL_MATCH
: >"$CYDER_TEST_WINE_LOG"
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
retry_log="$(cat "$CYDER_TEST_WINE_LOG")"
assert_contains "$retry_log" "FontSmoothingType" "retry should apply failed field"
if [[ "$retry_log" == *"LogPixels"* ]]; then
  echo "ASSERT failed: retry rewrote successful DPI field" >&2
  exit 1
fi

# Retina off is represented explicitly as n. A second off apply is a no-op.
: >"$CYDER_TEST_WINE_LOG"
export CYDER_RETINA_MODE=0
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
assert_contains "$(cat "$CYDER_TEST_WINE_LOG")" "RetinaMode /t REG_SZ /d n" "changing Retina off should write n"
: >"$CYDER_TEST_WINE_LOG"
bash "$ROOT/scripts/cyder-apply-settings.sh" >/dev/null
if [[ -s "$CYDER_TEST_WINE_LOG" ]]; then
  echo "ASSERT failed: unchanged Retina-off settings should not rewrite the registry" >&2
  cat "$CYDER_TEST_WINE_LOG" >&2
  exit 1
fi

echo "PASS test-cyder-settings"
