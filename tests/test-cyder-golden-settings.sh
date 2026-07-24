#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/engine/bin" "$TMP/prefix"
cat >"$TMP/engine/bin/wine" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CYDER_TEST_REG_LOG"
# Accept either legacy per-key reg add or a single regedit /s import.
if [[ "${1:-}" == regedit && "${2:-}" == /s && -f "${3:-}" ]]; then
  cat "$3" >>"$CYDER_TEST_REG_LOG"
fi
SH
chmod +x "$TMP/engine/bin/wine"
export CYDER_TEST_REG_LOG="$TMP/registry.log"
WINE_INSTALL="$TMP/engine" WINEPREFIX="$TMP/prefix" \
  bash "$ROOT/scripts/cyder-apply-golden-settings.sh"

log="$(cat "$CYDER_TEST_REG_LOG")"
assert_contains "$log" 'regedit /s' "Golden should apply baseline with a single regedit import"
assert_contains "$log" 'DllOverrides' "Golden should set ddraw override"
assert_contains "$log" '"ddraw"="native,builtin"' "Golden should set ddraw native,builtin"
assert_contains "$log" 'FontSmoothingType"=dword:00000002' \
  "Golden should use RGB ClearType globally"
assert_contains "$log" '"RetinaMode"="n"' "Golden should disable Retina explicitly"
assert_contains "$log" 'LogPixels"=dword:00000060' "Golden should use 96 DPI"
if [[ "$log" == *'AppDefaults\BlueLauncher.exe\Control Panel\Desktop'* ]]; then
  echo "ASSERT failed: Golden should not write ineffective BlueLauncher smoothing values" >&2
  exit 1
fi
assert test -f "$TMP/prefix/.cyder-golden-baseline-v2"

echo "PASS test-cyder-golden-settings"
