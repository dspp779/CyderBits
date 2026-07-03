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
# Custom-prefix Homebrew (tarball, no .git) must not auto-update or it fails with:
# "Error: update-report should not be called directly!"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
# Keep caches inside the project (avoid Cursor sandbox temp paths dying mid-build).
export HOMEBREW_CACHE="$OGOM/.brew-x86/cache"
export HOMEBREW_LOGS="$OGOM/.brew-x86/logs"
export HOMEBREW_TEMP="$OGOM/.brew-x86/tmp"
mkdir -p "$HOMEBREW_CACHE" "$HOMEBREW_LOGS" "$HOMEBREW_TEMP"
