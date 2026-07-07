#!/usr/bin/env bash
# Enable CrossOver-like Mac high-resolution mode for the BlueCG prefix.
# RetinaMode=y (sharp) + LogPixels=216 (compensate window size).
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
  # Standard grayscale AA when not in Retina mode (ClearType often blurs at 1x)
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v FontSmoothing /t REG_SZ /d 2 /f
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v FontSmoothingType /t REG_DWORD /d 1 /f
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v FontSmoothingGamma /t REG_DWORD /d 0 /f
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v FontSmoothingOrientation /t REG_DWORD /d 1 /f
  echo "Mac high-res mode OFF (RetinaMode=n, DPI=96, FontSmoothingType=1)."
else
  arch -x86_64 "$WINE" reg add "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d y /f
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d 0xd8 /f
  # CrossOver / winetricks fontsmooth-rgb (ClearType RGB)
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v FontSmoothing /t REG_SZ /d 2 /f
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v FontSmoothingType /t REG_DWORD /d 2 /f
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v FontSmoothingGamma /t REG_DWORD /d 0x578 /f
  arch -x86_64 "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v FontSmoothingOrientation /t REG_DWORD /d 1 /f
  echo "Mac high-res mode ON (RetinaMode=y, DPI=216, ClearType RGB)."
fi

arch -x86_64 "$WINE_INSTALL/bin/wineserver" -k 2>/dev/null || true
echo "Restart the launcher: bash scripts/run-bluecg.sh"
echo "See docs/superpowers/specs/2026-07-04-mac-retina-hires-design.md"
