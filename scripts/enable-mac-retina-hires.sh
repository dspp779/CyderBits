#!/usr/bin/env bash
# Enable CrossOver-like Mac high-resolution mode for the BlueCG prefix.
# RetinaMode=y (sharp) + LogPixels=192 (compensate window size).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

PREFIX="${WINEPREFIX:-$BLUECG_PREFIX}"
WINE="$WINE_INSTALL/bin/wine"
export WINEPREFIX="$PREFIX"

OFF=0
if [[ "${1:-}" == "--off" ]]; then
  OFF=1
fi

arch -x86_64 "$WINE_INSTALL/bin/wineserver" -k 2>/dev/null || true

if [[ "$OFF" -eq 1 ]]; then
  arch -x86_64 "$WINE" reg add "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d n /f
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d 0x60 /f
  echo "Mac high-res mode OFF (RetinaMode=n, DPI=96)."
else
  arch -x86_64 "$WINE" reg add "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d y /f
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d 0xc0 /f
  echo "Mac high-res mode ON (RetinaMode=y, DPI=192)."
fi

arch -x86_64 "$WINE_INSTALL/bin/wineserver" -k 2>/dev/null || true
echo "Restart the launcher: bash scripts/run-bluecg.sh"
echo "See docs/superpowers/specs/2026-07-04-mac-retina-hires-design.md"
