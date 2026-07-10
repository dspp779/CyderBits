#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow Cyder.app to pre-set OGOM / WINE_INSTALL / ENTITLEMENTS_PLIST.
if [[ -z "${OGOM:-}" ]]; then
  export OGOM="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

export CX_VERSION="${CX_VERSION:-26}"
export HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-$OGOM/.brew-x86}"
export BUILD_DIR="${OGOM_BUILD_DIR:-$OGOM/build}"
export LLVM_MINGW_NAME="llvm-mingw-20260616-ucrt-macos-universal"

case "$CX_VERSION" in
  25)
    export CYDER_ENGINE_CX_PREFIX="${CYDER_ENGINE_CX_PREFIX:-CX25}"
    export WINE_SRC="${WINE_SRC:-$BUILD_DIR/cx25/sources/wine}"
    export WINE_INSTALL="${WINE_INSTALL:-$OGOM/install/wine-cx25-x86_64}"
    ;;
  26)
    export CYDER_ENGINE_CX_PREFIX="${CYDER_ENGINE_CX_PREFIX:-CX26}"
    export WINE_SRC="${WINE_SRC:-$BUILD_DIR/cx26/sources/wine}"
    export WINE_INSTALL="${WINE_INSTALL:-$OGOM/install/wine-cx26-x86_64}"
    ;;
  *)
    echo "Unknown CX_VERSION: $CX_VERSION (expected 25 or 26)" >&2
    exit 1
    ;;
esac

if [[ -z "${LLVM_MINGW:-}" ]]; then
  for _candidate in \
    "$BUILD_DIR/$LLVM_MINGW_NAME" \
    "$OGOM/$LLVM_MINGW_NAME"; do
    if [[ -d "$_candidate/bin" ]]; then
      LLVM_MINGW="$_candidate"
      break
    fi
  done
  LLVM_MINGW="${LLVM_MINGW:-$BUILD_DIR/$LLVM_MINGW_NAME}"
fi
export LLVM_MINGW

export BLUECG_PREFIX="${BLUECG_PREFIX:-$OGOM/BlueCrossgateNew}"
export ENTITLEMENTS_PLIST="${ENTITLEMENTS_PLIST:-$OGOM/config/entitlements.plist}"
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
  unset _d _brew_lib_path _candidate
fi
