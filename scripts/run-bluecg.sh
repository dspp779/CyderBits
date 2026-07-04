#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

PREFIX="$BLUECG_PREFIX"
DDRAW_SOURCE="official"
MODE="launcher"
DRY_RUN=0
NO_GECKO_PROMPT=0
GAME_ARGS=(updated graphicbin:66 graphicinfobin:66 animebin:4 animeinfobin:4 windowmode CGTEXTTC 3Ddevice:1 GAHD)

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift
      ;;
    --wine-install)
      WINE_INSTALL="$2"
      shift
      ;;
    --ddraw-source)
      DDRAW_SOURCE="$2"
      shift
      ;;
    --direct) MODE="direct" ;;
    --soft3d)
      GAME_ARGS=(updated graphicbin:66 graphicinfobin:66 animebin:4 animeinfobin:4 windowmode CGTEXTTC 3Ddevice:0)
      ;;
    --no-gecko-prompt) NO_GECKO_PROMPT=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

WINE_BIN="$WINE_INSTALL/bin/wine"
OFFICIAL_DDRAW="$PREFIX/BlueLauncher_temp/BlueCG_updatelogin/DDRAW.dll"
LOCAL_DDRAW="$PREFIX/ddraw.dll"

[[ -d "$PREFIX" ]] || { echo "Missing BlueCG prefix: $PREFIX" >&2; exit 1; }
[[ -x "$WINE_BIN" || "$DRY_RUN" -eq 1 ]] || { echo "Missing wine binary: $WINE_BIN" >&2; exit 1; }

case "$DDRAW_SOURCE" in
  official)
    [[ -f "$OFFICIAL_DDRAW" ]] || { echo "Missing official DDRAW.dll: $OFFICIAL_DDRAW" >&2; exit 1; }
    run cp "$OFFICIAL_DDRAW" "$LOCAL_DDRAW"
    ;;
  builtin)
    run rm -f "$LOCAL_DDRAW"
    ;;
  local)
    [[ -f "$LOCAL_DDRAW" ]] || { echo "Missing local ddraw.dll: $LOCAL_DDRAW" >&2; exit 1; }
    ;;
  *)
    echo "Unknown DDRAW source: $DDRAW_SOURCE" >&2
    exit 1
    ;;
esac

export WINEPREFIX="$PREFIX"
export LANG=zh_TW.UTF-8
export PATH="$WINE_INSTALL/bin:$PATH"

# Session-only: suppress Wine Gecko dialog (does not change prefix registry).
# For a permanent setting: bash scripts/configure-mshtml.sh --disable
if [[ "$NO_GECKO_PROMPT" -eq 1 ]]; then
  if [[ -n "${WINEDLLOVERRIDES:-}" ]]; then
    export WINEDLLOVERRIDES="mshtml=;${WINEDLLOVERRIDES}"
  else
    export WINEDLLOVERRIDES="mshtml="
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ export WINEDLLOVERRIDES=${WINEDLLOVERRIDES}"
  fi
fi

cd "$PREFIX"

if [[ "$MODE" == "launcher" ]]; then
  run arch -x86_64 "$WINE_BIN" BlueLauncher.exe
else
  run arch -x86_64 "$WINE_BIN" bluecg.exe "${GAME_ARGS[@]}"
fi
