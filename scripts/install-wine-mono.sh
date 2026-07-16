#!/usr/bin/env bash
# Install Wine Mono (for .NET apps such as BlueLauncher) into WINEPREFIX.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/env-x86_64.sh" ]]; then
  # shellcheck source=env-x86_64.sh
  source "$SCRIPT_DIR/env-x86_64.sh"
fi
WINE_INSTALL="${WINE_INSTALL:?WINE_INSTALL not set}"

MONO_VER="${WINE_MONO_VERSION:-10.4.1}"
MONO_MSI="wine-mono-${MONO_VER}-x86.msi"
URL="https://dl.winehq.org/wine/wine-mono/${MONO_VER}/${MONO_MSI}"
DOWNLOADS="${CYDER_DOWNLOADS:-$HOME/Library/Application Support/Cyder/downloads}"
DEST="$DOWNLOADS/$MONO_MSI"
PREFIX="${WINEPREFIX:-$BLUECG_PREFIX}"

case "$MONO_VER" in
  10.4.1) MONO_SHA256="071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23" ;;
  *) echo "Unsupported Wine Mono version: $MONO_VER" >&2; exit 2 ;;
esac

mkdir -p "$DOWNLOADS"
if [[ -f "$DEST" ]] && [[ "$(shasum -a 256 "$DEST" | awk '{print $1}')" != "$MONO_SHA256" ]]; then
  rm -f "$DEST"
fi
if [[ ! -f "$DEST" ]]; then
  echo "Downloading $URL"
  curl -fL --progress-bar -o "$DEST.part" "$URL"
  mv -f "$DEST.part" "$DEST"
fi
[[ "$(shasum -a 256 "$DEST" | awk '{print $1}')" == "$MONO_SHA256" ]] || {
  echo "Wine Mono checksum verification failed: $DEST" >&2
  rm -f "$DEST"
  exit 1
}

export WINEPREFIX="$PREFIX"
echo "Installing $DEST into WINEPREFIX=$WINEPREFIX"
arch -x86_64 "$WINE_INSTALL/bin/wine" msiexec /i "$DEST" /qn
printf 'version=%s\nsha256=%s\n' "$MONO_VER" "$MONO_SHA256" >"$WINEPREFIX/.cyder-mono-$MONO_VER"
echo "Wine Mono ${MONO_VER} installed."
