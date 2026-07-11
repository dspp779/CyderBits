#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow Cyder.app to pre-set OGOM / WINE_INSTALL / ENTITLEMENTS_PLIST.
if [[ -z "${OGOM:-}" ]]; then
  export OGOM="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
export HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-$OGOM/.brew-x86}"
export LLVM_MINGW="${LLVM_MINGW:-$OGOM/llvm-mingw-20260616-ucrt-macos-universal}"
export WINE_INSTALL="${WINE_INSTALL:-$OGOM/install/wine-x86_64}"
export WINE_SRC="${WINE_SRC:-$OGOM/sources/wine}"
export BLUECG_PREFIX="${BLUECG_PREFIX:-$OGOM/BlueCrossgateNew}"
export ENTITLEMENTS_PLIST="${ENTITLEMENTS_PLIST:-$OGOM/config/entitlements.plist}"
export CYDER_CROSSOVER_VERSION="${CYDER_CROSSOVER_VERSION:-26.2.0}"
export ARCH_CMD="arch -x86_64"

export PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH"
export PKG_CONFIG="$HOMEBREW_PREFIX/bin/pkg-config"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/zlib/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/bzip2/lib/pkgconfig"
unset PKG_CONFIG_LIBDIR

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_ASK=1
export NONINTERACTIVE=1
export CI=1

if [[ -d "$HOMEBREW_PREFIX" ]]; then
  export HOMEBREW_CACHE="$HOMEBREW_PREFIX/cache"
  export HOMEBREW_LOGS="$HOMEBREW_PREFIX/logs"
  export HOMEBREW_TEMP="$HOMEBREW_PREFIX/tmp"
  mkdir -p "$HOMEBREW_CACHE" "$HOMEBREW_LOGS" "$HOMEBREW_TEMP"

  _brew_lib_path="$HOMEBREW_PREFIX/lib"
  for _d in "$HOMEBREW_PREFIX"/opt/*/lib; do
    [[ -d "$_d" ]] || continue
    _brew_lib_path="$_brew_lib_path:$_d"
  done
  export DYLD_FALLBACK_LIBRARY_PATH="${_brew_lib_path}${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
  export DYLD_LIBRARY_PATH="${_brew_lib_path}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  unset _d _brew_lib_path
fi
