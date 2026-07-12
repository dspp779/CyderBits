#!/usr/bin/env bash
# Apply validated Cyder UI settings to the active shared Wine prefix.
set -euo pipefail

WINE_INSTALL="${WINE_INSTALL:-}"
WINEPREFIX="${WINEPREFIX:-}"
[[ -n "$WINE_INSTALL" && -x "$WINE_INSTALL/bin/wine" ]] || {
  echo "WINE_INSTALL with bin/wine is required" >&2
  exit 1
}
[[ -n "$WINEPREFIX" ]] || {
  echo "WINEPREFIX is required" >&2
  exit 1
}

WINE=(arch -x86_64 "$WINE_INSTALL/bin/wine")
retina="${CYDER_RETINA_MODE:-0}"
dpi="${CYDER_DPI:-96}"
font="${CYDER_FONT_PRESET:-songti}"
smoothing="${CYDER_FONT_SMOOTHING:-cleartype-rgb}"

[[ "$retina" == 0 || "$retina" == 1 ]] || retina=0
[[ "$dpi" =~ ^[0-9]+$ ]] && (( dpi >= 72 && dpi <= 480 )) || dpi=96
case "$font" in songti|mingliu) ;; *) font=songti ;; esac
case "$smoothing" in off|grayscale|cleartype-rgb|cleartype-bgr) ;; *) smoothing=cleartype-rgb ;; esac

if [[ "$retina" == 1 ]]; then retina_value=y; else retina_value=n; fi
"${WINE[@]}" reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d "$retina_value" /f
"${WINE[@]}" reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f

case "$smoothing" in
  off)
    smooth=0; smooth_type=1; gamma=0; orientation=1 ;;
  grayscale)
    smooth=2; smooth_type=1; gamma=0; orientation=1 ;;
  cleartype-bgr)
    smooth=2; smooth_type=2; gamma=1400; orientation=0 ;;
  *)
    smooth=2; smooth_type=2; gamma=1400; orientation=1 ;;
esac
"${WINE[@]}" reg add 'HKCU\Control Panel\Desktop' /v FontSmoothing /t REG_SZ /d "$smooth" /f
"${WINE[@]}" reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingType /t REG_DWORD /d "$smooth_type" /f
"${WINE[@]}" reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingGamma /t REG_DWORD /d "$gamma" /f
"${WINE[@]}" reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingOrientation /t REG_DWORD /d "$orientation" /f

if [[ "$font" == songti ]]; then
  face='Songti TC'
  "${WINE[@]}" reg add 'HKCU\Software\Wine\Fonts\Replacements' /v MingLiU /t REG_SZ /d "$face" /f
else
  face='MingLiU'
  # Do not map MingLiU to itself; let Wine/macOS resolve an actually installed font.
  "${WINE[@]}" reg delete 'HKCU\Software\Wine\Fonts\Replacements' /v MingLiU /f 2>/dev/null || true
fi
for name in PMingLiU 細明體 新細明體 SimSun NSimSun 'MS Shell Dlg' 'MS Shell Dlg 2' 'Microsoft Sans Serif'; do
  "${WINE[@]}" reg add 'HKCU\Software\Wine\Fonts\Replacements' /v "$name" /t REG_SZ /d "$face" /f
done
"${WINE[@]}" reg add 'HKCU\Software\Wine\Fonts\Replacements' /v @PMingLiU /t REG_SZ /d "@$face" /f
"${WINE[@]}" reg add 'HKCU\Software\Wine\Fonts\Replacements' /v @細明體 /t REG_SZ /d "@$face" /f

echo "Applied Cyder settings: Retina=$retina DPI=$dpi font=$font smoothing=$smoothing"
