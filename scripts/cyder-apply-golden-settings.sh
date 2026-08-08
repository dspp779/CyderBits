#!/usr/bin/env bash
# Apply Cyder's immutable baseline to a prefix with a single regedit import.
# Avoids one Wine startup per registry value (previously ~15+ reg add calls).
#
# DllOverrides mirror CrossOver win10_64's crossover.inf Win10Install:
#   WineDllOverridesReg + WineDllOverridesRegNT
# plus Cyder VC++ 2015–2022 native preference and the existing ddraw baseline.
# Applied only when provisioning a new prefix (not migrated onto ready bottles).
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
"RetinaMode"="y"

[HKEY_CURRENT_USER\Control Panel\Desktop]
"LogPixels"=dword:000000c0
"FontSmoothing"="2"
"FontSmoothingType"=dword:00000002
"FontSmoothingGamma"=dword:00000578
"FontSmoothingOrientation"=dword:00000001

[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]
"SimSun"="Songti TC"
"NSimSun"="Songti TC"
"宋体"="Songti TC"
"新宋体"="Songti TC"
"@SimSun"="@Songti TC"
"@宋体"="@Songti TC"
"MingLiU"="Songti TC"
"PMingLiU"="Songti TC"
"細明體"="Songti TC"
"新細明體"="Songti TC"
"MS Shell Dlg"="Songti TC"
"MS Shell Dlg 2"="Songti TC"
"Microsoft Sans Serif"="Songti TC"
"@PMingLiU"="@Songti TC"
"@細明體"="@Songti TC"

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"ddraw"="native,builtin"
"atl"="native,builtin"
"dciman32"="native"
"hhctrl.ocx"="native,builtin"
"iernonce"="native,builtin"
"itss"="native,builtin"
"mshtml"="native,builtin"
"mlang"="native,builtin"
"msvcirt"="native,builtin"
"msvcrt40"="native,builtin"
"msvcrtd"="native,builtin"
"odbccp32"="native,builtin"
"riched20"="native,builtin"
"riched32"="native,builtin"
"softpub"="native,builtin"
"dxdiagn"="native,builtin"
"dplay"="native,builtin"
"dplayx"="native,builtin"
"dplaysvr.exe"="native,builtin"
"dpnaddr"="native,builtin"
"dpnet"="native,builtin"
"dpnhpast"="native,builtin"
"dpnhupnp"="native,builtin"
"dpnlobby"="native,builtin"
"dpnsvr.exe"="native,builtin"
"dpnwsock"="native,builtin"
"d3dxof"="native,builtin"
"*docbox.api"=""
"crypt32"="native,builtin"
"devenum"="native,builtin"
"hlink"="native,builtin"
"jscript"="native,builtin"
"quartz"="native,builtin"
"rsabase"="native,builtin"
"secur32"="native,builtin"
"shdocvw"="native,builtin"
"shdoclc"="native,builtin"
"urlmon"="native,builtin"
"wintrust"="native,builtin"
"wscript.exe"="native,builtin"
"odbc32"="native,builtin"
"*autorun.exe"="native,builtin"
"*ctfmon.exe"="builtin"
"*ddhelp.exe"="builtin"
"*findfast.exe"="builtin"
"*maildoff.exe"="builtin"
"*mdm.exe"="builtin"
"*mosearch.exe"="builtin"
"*pstores.exe"="builtin"
"*user.exe"="native,builtin"
"*ieinfo5.ocx"="builtin"
"amstream"="native,builtin"
"msi"="builtin"
"*msiexec.exe"="builtin"
"ole32"="builtin"
"oleaut32"="builtin"
"olepro32"="builtin"
"rpcrt4"="builtin"
"wininet"="builtin"
"msvcp140"="native,builtin"
"msvcp140_1"="native,builtin"
"msvcp140_2"="native,builtin"
"msvcp140_atomic_wait"="native,builtin"
"vcruntime140"="native,builtin"
"vcruntime140_1"="native,builtin"
"concrt140"="native,builtin"
"vccorlib140"="native,builtin"

[HKEY_CURRENT_USER\Software\Wine\AppDefaults\cxwget.exe\DllOverrides]
"wininet"="builtin"

[HKEY_CURRENT_USER\Software\Wine\AppDefaults\winewrapper.exe\DllOverrides]
"crypt32"="builtin"
"rsabase"="builtin"
"rsaenh"="builtin"
EOF

echo "regedit /s $regfile" >&2
"${WINE[@]}" regedit /s "$regfile"

printf '%s\n' \
  'schema=3' \
  'retina=1' \
  'dpi=192' \
  'fontMingLiu=songti' \
  'fontSongti=songti' \
  'smoothing=cleartype-rgb' \
  'ddraw=native,builtin' \
  'dllOverrides=crossover-win10+vc140' \
  >"$WINEPREFIX/.cyder-golden-baseline-v2"
