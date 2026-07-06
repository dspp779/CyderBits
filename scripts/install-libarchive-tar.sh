#!/usr/bin/env bash
# Install GnuWin libarchive bsdtar as syswow64/tar.exe (BlueCG large zip).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/env-x86_64.sh" ]]; then
  # shellcheck source=env-x86_64.sh
  source "$SCRIPT_DIR/env-x86_64.sh"
fi

PREFIX="${1:-${WINEPREFIX:-}}"
if [[ "${1:-}" == "--prefix" ]]; then PREFIX="$2"; fi
[[ -n "$PREFIX" ]] || { echo "Usage: $0 --prefix PATH" >&2; exit 1; }

resolve_libarchive_src() {
  if [[ -n "${CYDER_LIBARCHIVE_SRC:-}" && -d "$CYDER_LIBARCHIVE_SRC/bin" ]]; then
    printf '%s\n' "$CYDER_LIBARCHIVE_SRC"
    return 0
  fi
  if [[ -n "${OGOM:-}" ]]; then
    if [[ -d "$OGOM/addons/libarchive/bin" ]]; then
      printf '%s\n' "$OGOM/addons/libarchive"
      return 0
    fi
    if [[ -d "$OGOM/tools/libarchive/bin" ]]; then
      printf '%s\n' "$OGOM/tools/libarchive"
      return 0
    fi
  fi
  return 1
}

SRC="$(resolve_libarchive_src)" || {
  echo "Missing libarchive source (expected OGOM/addons/libarchive or OGOM/tools/libarchive)" >&2
  exit 1
}
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
