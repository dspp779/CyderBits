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
SH
chmod +x "$TMP/engine/bin/wine"
export CYDER_TEST_REG_LOG="$TMP/registry.log"
WINE_INSTALL="$TMP/engine" WINEPREFIX="$TMP/prefix" \
  bash "$ROOT/scripts/cyder-apply-golden-settings.sh"

log="$(cat "$CYDER_TEST_REG_LOG")"
assert_contains "$log" 'HKCU\Software\Wine\DllOverrides /v ddraw /t REG_SZ /d native,builtin' \
  "Golden should set ddraw native,builtin"
assert_contains "$log" 'HKCU\Control Panel\Desktop /v FontSmoothingType /t REG_DWORD /d 2' \
  "Golden should use RGB ClearType globally"
assert_contains "$log" 'HKCU\Software\Wine\AppDefaults\BlueLauncher.exe\Control Panel\Desktop /v FontSmoothingType /t REG_DWORD /d 1' \
  "BlueLauncher should use grayscale smoothing"
assert test -f "$TMP/prefix/.cyder-golden-baseline-v1"

echo "PASS test-cyder-golden-settings"
