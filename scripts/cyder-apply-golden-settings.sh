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

# BlueLauncher only: grayscale smoothing, without changing the global default.
blue_desktop='HKCU\Software\Wine\AppDefaults\BlueLauncher.exe\Control Panel\Desktop'
reg_add "$blue_desktop" /v FontSmoothing /t REG_SZ /d 2
reg_add "$blue_desktop" /v FontSmoothingType /t REG_DWORD /d 1
reg_add "$blue_desktop" /v FontSmoothingGamma /t REG_DWORD /d 0
reg_add "$blue_desktop" /v FontSmoothingOrientation /t REG_DWORD /d 1

printf 'schema=1\nfont=songti\nsmoothing=cleartype-rgb\nddraw=native,builtin\nblue-launcher-smoothing=grayscale\n' \
  >"$WINEPREFIX/.cyder-golden-baseline-v1"
