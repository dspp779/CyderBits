#!/usr/bin/env bash
# Install Wine Mono (for .NET apps such as BlueLauncher) into WINEPREFIX.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

MONO_VER="${WINE_MONO_VERSION:-10.4.1}"
MONO_MSI="wine-mono-${MONO_VER}-x86.msi"
URL="https://dl.winehq.org/wine/wine-mono/${MONO_VER}/${MONO_MSI}"
DEST="$OGOM/downloads/$MONO_MSI"
PREFIX="${WINEPREFIX:-$BLUECG_PREFIX}"

mkdir -p "$OGOM/downloads"
if [[ ! -f "$DEST" ]]; then
  echo "Downloading $URL"
  curl -fL --progress-bar -o "$DEST" "$URL"
fi

export WINEPREFIX="$PREFIX"
echo "Installing $DEST into WINEPREFIX=$WINEPREFIX"
arch -x86_64 "$WINE_INSTALL/bin/wine" msiexec /i "$DEST" /qn
echo "Wine Mono ${MONO_VER} installed."
