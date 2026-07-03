#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OGOM="$(cd "$SCRIPT_DIR/.." && pwd)"
export HOMEBREW_PREFIX="$OGOM/.brew-x86"
export LLVM_MINGW="$OGOM/llvm-mingw-20260616-ucrt-macos-universal"
export WINE_INSTALL="$OGOM/install/wine-x86_64"
export WINE_SRC="$OGOM/sources/wine"
export BLUECG_PREFIX="$OGOM/BlueCrossgateNew"
export ENTITLEMENTS_PLIST="$OGOM/config/entitlements.plist"
export ARCH_CMD="arch -x86_64"
export PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH"
