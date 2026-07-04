#!/usr/bin/env bash
# Symlink Homebrew dylibs Wine dlopens by relative soname into the unix lib dir.
# Hardened runtime allows that directory (see dlopen search paths in wine logs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

UNIX_LIB="$WINE_INSTALL/lib/wine/x86_64-unix"
[[ -d "$UNIX_LIB" ]] || { echo "Missing $UNIX_LIB; build/install wine first" >&2; exit 1; }

link_soname() {
  local src="$1"
  local name
  name=$(basename "$src")
  if [[ ! -e "$src" ]]; then
    echo "skip missing $src" >&2
    return 0
  fi
  ln -sfn "$(cd "$(dirname "$src")" && pwd)/$name" "$UNIX_LIB/$name"
  echo "linked $UNIX_LIB/$name"
}

# SONAME_* values from configure (relative names)
link_soname "$HOMEBREW_PREFIX/lib/libfreetype.6.dylib"
link_soname "$HOMEBREW_PREFIX/opt/freetype/lib/libfreetype.6.dylib"
link_soname "$HOMEBREW_PREFIX/opt/gnutls/lib/libgnutls.30.dylib"
link_soname "$HOMEBREW_PREFIX/lib/libgnutls.30.dylib"
link_soname "$HOMEBREW_PREFIX/opt/libpng/lib/libpng16.16.dylib"
link_soname "$HOMEBREW_PREFIX/lib/libpng16.16.dylib"
