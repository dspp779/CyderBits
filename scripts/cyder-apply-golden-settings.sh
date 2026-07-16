#!/usr/bin/env bash
# Apply Cyder's immutable baseline to a Golden staging prefix.
set -Eeuo pipefail

WINE_INSTALL="${WINE_INSTALL:?WINE_INSTALL not set}"
WINEPREFIX="${WINEPREFIX:?WINEPREFIX not set}"
WINE=(/usr/bin/arch -x86_64 "$WINE_INSTALL/bin/wine")

reg_add() {
  "${WINE[@]}" reg add "$@" /f
}

# Global default: Songti TC with RGB subpixel smoothing.
reg_add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d n
reg_add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 96
reg_add 'HKCU\Control Panel\Desktop' /v FontSmoothing /t REG_SZ /d 2
reg_add 'HKCU\Control Panel\Desktop' /v FontSmoothingType /t REG_DWORD /d 2
reg_add 'HKCU\Control Panel\Desktop' /v FontSmoothingGamma /t REG_DWORD /d 1400
reg_add 'HKCU\Control Panel\Desktop' /v FontSmoothingOrientation /t REG_DWORD /d 1

for name in MingLiU PMingLiU 細明體 新細明體 SimSun NSimSun 'MS Shell Dlg' 'MS Shell Dlg 2' 'Microsoft Sans Serif'; do
  reg_add 'HKCU\Software\Wine\Fonts\Replacements' /v "$name" /t REG_SZ /d 'Songti TC'
done
reg_add 'HKCU\Software\Wine\Fonts\Replacements' /v @PMingLiU /t REG_SZ /d '@Songti TC'
reg_add 'HKCU\Software\Wine\Fonts\Replacements' /v @細明體 /t REG_SZ /d '@Songti TC'

# Cyder baseline for DirectDraw. Wine's n,b notation is native,builtin.
reg_add 'HKCU\Software\Wine\DllOverrides' /v ddraw /t REG_SZ /d native,builtin

printf 'schema=2\nretina=0\ndpi=96\nfont=songti\nsmoothing=cleartype-rgb\nddraw=native,builtin\n' \
  >"$WINEPREFIX/.cyder-golden-baseline-v2"
