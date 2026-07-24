#!/usr/bin/env bash
# Install libMoltenVK.dylib from an installed CrossOver.app into GRAPHICS_INSTALL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

CROSSOVER_ROOT="${CROSSOVER_ROOT:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"
SRC_DYLIB="$CROSSOVER_ROOT/lib64/libMoltenVK.dylib"
DEST_DIR="$GRAPHICS_INSTALL/lib"
DEST_DYLIB="$DEST_DIR/libMoltenVK.dylib"

[[ -f "$SRC_DYLIB" ]] || {
  echo "Missing CrossOver MoltenVK: $SRC_DYLIB" >&2
  echo "Set CROSSOVER_ROOT or install CrossOver.app." >&2
  exit 1
}

mkdir -p "$DEST_DIR"
cp -p "$SRC_DYLIB" "$DEST_DYLIB"
chmod 755 "$DEST_DYLIB"

minos="$(otool -l "$DEST_DYLIB" 2>/dev/null | awk '/minos/{print $2; exit}')"
cat >"$GRAPHICS_INSTALL/version" <<EOF
graphics crossover-app
moltenvk crossover-app-lib64
arch x86_64
source crossover-app
minos ${minos:-unknown}
path $SRC_DYLIB
EOF

echo "Installed CrossOver.app MoltenVK -> $DEST_DYLIB (minos=${minos:-unknown})"
