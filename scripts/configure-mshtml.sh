#!/usr/bin/env bash
# Opt-in: disable or re-enable mshtml in the BlueCG prefix.
# Disabling suppresses the recurring Wine Gecko install dialog (banner HTML may be blank).
# Default project behavior is unchanged until you run this with --disable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

PREFIX="${WINEPREFIX:-$BLUECG_PREFIX}"
WINE="$WINE_INSTALL/bin/wine"
export WINEPREFIX="$PREFIX"

usage() {
  cat <<'EOF'
Usage: bash scripts/configure-mshtml.sh --disable|--enable

  --disable   Set DllOverrides mshtml="" (no Gecko prompt; no embedded HTML)
  --enable    Remove the override (Wine may prompt to install Gecko again)

Default launch (run-bluecg.sh without flags) does not change mshtml.
For a single session only, use: bash scripts/run-bluecg.sh --no-gecko-prompt
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  --disable)
    arch -x86_64 "$WINE_INSTALL/bin/wineserver" -k 2>/dev/null || true
    arch -x86_64 "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v mshtml /t REG_SZ /d "" /f
    arch -x86_64 "$WINE_INSTALL/bin/wineserver" -k 2>/dev/null || true
    echo "mshtml disabled in $WINEPREFIX (Gecko install prompt suppressed)."
    ;;
  --enable)
    arch -x86_64 "$WINE_INSTALL/bin/wineserver" -k 2>/dev/null || true
    arch -x86_64 "$WINE" reg delete "HKCU\\Software\\Wine\\DllOverrides" /v mshtml /f 2>/dev/null || true
    arch -x86_64 "$WINE_INSTALL/bin/wineserver" -k 2>/dev/null || true
    echo "mshtml override removed in $WINEPREFIX (Gecko prompt may appear again)."
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac

echo "Restart with: bash scripts/run-bluecg.sh"
