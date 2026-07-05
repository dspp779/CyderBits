#!/usr/bin/env bash
# Install GnuWin libarchive bsdtar as syswow64/tar.exe (BlueCG large zip).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OGOM="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

PREFIX="${1:-${WINEPREFIX:-}}"
if [[ "${1:-}" == "--prefix" ]]; then PREFIX="$2"; fi
[[ -n "$PREFIX" ]] || { echo "Usage: $0 --prefix PATH" >&2; exit 1; }

SRC="${CYDER_LIBARCHIVE_SRC:-$OGOM/tools/libarchive}"
BIN="$SRC/bin"
DEP="$SRC/dep"
TARGET="$PREFIX/drive_c/windows/syswow64"
[[ -d "$PREFIX/drive_c/windows/syswow64" ]] || TARGET="$PREFIX/drive_c/windows/system32"

mkdir -p "$TARGET"
for f in bsdtar.exe libarchive2.dll bzip2.dll zlib1.dll; do
  case "$f" in
    bsdtar.exe|libarchive2.dll) cp -f "$BIN/$f" "$TARGET/" ;;
    *) cp -f "$DEP/$f" "$TARGET/" ;;
  esac
done
cp -f "$TARGET/bsdtar.exe" "$TARGET/tar.exe"
echo "Installed tar.exe (bsdtar) -> $TARGET"
