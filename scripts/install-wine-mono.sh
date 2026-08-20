#!/usr/bin/env bash
# Install Wine Mono (for .NET apps such as BlueLauncher) into WINEPREFIX.
set -euo pipefail

DOWNLOAD_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --download-only)
      DOWNLOAD_ONLY=1
      shift
      ;;
    -h | --help)
      cat <<'EOF'
Usage: install-wine-mono.sh [--download-only]

Downloads and verifies the pinned Wine Mono MSI. Without --download-only,
installs it into WINEPREFIX via msiexec.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/env-x86_64.sh" ]]; then
  # shellcheck source=env-x86_64.sh
  source "$SCRIPT_DIR/env-x86_64.sh"
fi

MONO_VER="${WINE_MONO_VERSION:-10.4.1}"
MONO_MSI="wine-mono-${MONO_VER}-x86.msi"
URL="https://dl.winehq.org/wine/wine-mono/${MONO_VER}/${MONO_MSI}"
DOWNLOADS="${CYDER_DOWNLOADS:-$HOME/Library/Application Support/Cyder/downloads}"
DEST="$DOWNLOADS/$MONO_MSI"

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

if [[ "$DOWNLOAD_ONLY" -eq 1 ]]; then
  echo "Wine Mono ${MONO_VER} download ready: $DEST"
  exit 0
fi

WINE_INSTALL="${WINE_INSTALL:?WINE_INSTALL not set}"
PREFIX="${WINEPREFIX:-$BLUECG_PREFIX}"

export WINEPREFIX="$PREFIX"
echo "Installing $DEST into WINEPREFIX=$WINEPREFIX"
arch -x86_64 "$WINE_INSTALL/bin/wine" msiexec /i "$DEST" /qn
printf 'version=%s\nsha256=%s\n' "$MONO_VER" "$MONO_SHA256" >"$WINEPREFIX/.cyder-mono-$MONO_VER"
echo "Wine Mono ${MONO_VER} installed."
