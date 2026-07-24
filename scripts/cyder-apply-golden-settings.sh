#!/usr/bin/env bash
# Apply Cyder's immutable baseline to a prefix with a single regedit import.
# Avoids one Wine startup per registry value (previously ~15+ reg add calls).
set -Eeuo pipefail

WINE_INSTALL="${WINE_INSTALL:?WINE_INSTALL not set}"
WINEPREFIX="${WINEPREFIX:?WINEPREFIX not set}"
[[ -d "$WINEPREFIX" ]] || { echo "WINEPREFIX missing: $WINEPREFIX" >&2; exit 1; }

WINE=(/usr/bin/arch -x86_64 "$WINE_INSTALL/bin/wine")
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cyder-golden-reg.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
regfile="$tmpdir/golden-baseline.reg"

# REGEDIT4 import: one Wine process applies the whole baseline.
cat >"$regfile" <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\Mac Driver]
"RetinaMode"="n"

[HKEY_CURRENT_USER\Control Panel\Desktop]
"LogPixels"=dword:00000060
"FontSmoothing"="2"
"FontSmoothingType"=dword:00000002
"FontSmoothingGamma"=dword:00000578
"FontSmoothingOrientation"=dword:00000001

[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]
"MingLiU"="Songti TC"
"PMingLiU"="Songti TC"
"細明體"="Songti TC"
"新細明體"="Songti TC"
"SimSun"="Songti TC"
"NSimSun"="Songti TC"
"MS Shell Dlg"="Songti TC"
"MS Shell Dlg 2"="Songti TC"
"Microsoft Sans Serif"="Songti TC"
"@PMingLiU"="@Songti TC"
"@細明體"="@Songti TC"

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"ddraw"="native,builtin"
EOF

echo "regedit /s $regfile" >&2
"${WINE[@]}" regedit /s "$regfile"

printf 'schema=2\nretina=0\ndpi=96\nfont=songti\nsmoothing=cleartype-rgb\nddraw=native,builtin\n' \
  >"$WINEPREFIX/.cyder-golden-baseline-v2"
