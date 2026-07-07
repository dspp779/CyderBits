#!/usr/bin/env bash
# Apply Cyder Songti TC font replacements to the active WINEPREFIX.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${WINEPREFIX:-}"
[[ -n "$PREFIX" ]] || {
  echo "WINEPREFIX is required" >&2
  exit 1
}

WINE_INSTALL="${WINE_INSTALL:-}"
[[ -n "$WINE_INSTALL" && -x "$WINE_INSTALL/bin/wine" ]] || {
  echo "WINE_INSTALL with bin/wine is required" >&2
  exit 1
}

REG="${CYDER_FONT_REPLACEMENTS_REG:-$SCRIPT_DIR/cyder-songti-replacements.reg}"
[[ -f "$REG" ]] || {
  echo "Missing font replacements registry: $REG" >&2
  exit 1
}

export WINEPREFIX="$PREFIX"
arch -x86_64 "$WINE_INSTALL/bin/wine" regedit "$REG"
echo "Applied Songti TC font replacements from ${REG##*/}"
