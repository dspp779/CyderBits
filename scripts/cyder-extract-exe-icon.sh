#!/usr/bin/env bash
# Extract a PNG from a Windows EXE via a temp .lnk and winemenubuilder -t.
# Does not parse PE. Does not kill wineserver (reuses the caller's WINEPREFIX).
set -euo pipefail

usage() {
  echo "Usage: cyder-extract-exe-icon.sh --exe UNIX.exe --png UNIX.png [--wine UNIX/wine] [--scratch DIR]" >&2
  exit 1
}

EXE=""
PNG=""
WINE_BIN="${CYDER_WINE:-}"
SCRATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exe) EXE="${2:-}"; shift 2 ;;
    --png) PNG="${2:-}"; shift 2 ;;
    --wine) WINE_BIN="${2:-}"; shift 2 ;;
    --scratch) SCRATCH="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "${WINEPREFIX:-}" && -d "$WINEPREFIX" ]] || {
  echo "WINEPREFIX is required" >&2
  exit 1
}
[[ -n "$EXE" && -n "$PNG" && -f "$EXE" ]] || {
  echo "Missing --exe/--png or exe file" >&2
  exit 1
}

if [[ -z "$WINE_BIN" ]]; then
  WINE_BIN="${CYDER_ENGINES:-$HOME/.cyder/runtime/Engines}/${CYDER_ENGINE_NAME:-wine-x86_64}/bin/wine"
fi
[[ -x "$WINE_BIN" ]] || {
  echo "Missing wine: $WINE_BIN" >&2
  exit 1
}

WINESERVER="${WINESERVER:-${WINE_BIN%/wine}/wineserver}"
export WINEPREFIX WINESERVER
export WINEDEBUG="${WINEDEBUG:--all}"

if [[ -z "$SCRATCH" ]]; then
  SCRATCH="$(cd "$(dirname "$EXE")" && pwd)/.cyder-icon-work.$$"
  mkdir -p "$SCRATCH"
  cp "$EXE" "$SCRATCH/game.exe"
  OWN_SCRATCH=1
else
  mkdir -p "$SCRATCH"
  if [[ "$(cd "$(dirname "$EXE")" && pwd)/$(basename "$EXE")" != "$(cd "$SCRATCH" && pwd)/game.exe" ]]; then
    cp "$EXE" "$SCRATCH/game.exe"
  fi
  OWN_SCRATCH=0
fi

cleanup() {
  rm -f "$SCRATCH/game.exe" "$SCRATCH/game.lnk" "$SCRATCH/make_lnk.js"
  if [[ "${OWN_SCRATCH:-0}" == 1 ]]; then
    rmdir "$SCRATCH" 2>/dev/null || rm -rf "$SCRATCH"
  fi
}
trap cleanup EXIT

run_wine() {
  arch -x86_64 "$WINE_BIN" "$@"
}

GAME_UNIX="$(cd "$SCRATCH" && pwd)/game.exe"
DOS_EXE="$(run_wine winepath -w "$GAME_UNIX")"
# JS string: escape backslashes and quotes
JS_TARGET="${DOS_EXE//\\/\\\\}"
JS_TARGET="${JS_TARGET//\"/\\\"}"
JS_LNK="$SCRATCH/game.lnk"
JS_LNK="${JS_LNK//\"/\\\"}"

cat >"$SCRATCH/make_lnk.js" <<EOF
var ws = WScript.CreateObject("WScript.Shell");
var sc = ws.CreateShortcut("$JS_LNK");
sc.TargetPath = "$JS_TARGET";
sc.Save();
EOF

DOS_JS="$(run_wine winepath -w "$SCRATCH/make_lnk.js")"
run_wine cscript.exe //Nologo "$DOS_JS"
lnk="$SCRATCH/game.lnk"
[[ -f "$lnk" ]] || {
  echo "cscript did not create game.lnk" >&2
  exit 1
}

mkdir -p "$(dirname "$PNG")"
run_wine winemenubuilder.exe -t "$lnk" "$PNG"
[[ -s "$PNG" ]] || {
  echo "winemenubuilder produced no PNG" >&2
  exit 1
}
