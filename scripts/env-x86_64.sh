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
# Prefer project toolchains; keep system paths but put .brew-x86 ahead of /opt/homebrew.
export PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH"
# Use project Homebrew pkg-config only. Include keg-only deps (zlib/bzip2)
# that freetype2.pc Requires.private. Do NOT set PKG_CONFIG_LIBDIR alone to
# lib/pkgconfig — that hides keg-only .pc files and breaks --exists.
export PKG_CONFIG="$HOMEBREW_PREFIX/bin/pkg-config"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/zlib/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/bzip2/lib/pkgconfig"
unset PKG_CONFIG_LIBDIR
# Custom-prefix Homebrew (tarball, no .git) must not auto-update or it fails with:
# "Error: update-report should not be called directly!"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
# Homebrew 4.x defaults to ask-mode ("Do you want to proceed? [y/n]").
# NONINTERACTIVE/CI alone do not skip it; HOMEBREW_NO_ASK does (same as brew -y).
export HOMEBREW_NO_ASK=1
export NONINTERACTIVE=1
export CI=1
# Keep caches inside the project (avoid Cursor sandbox temp paths dying mid-build).
export HOMEBREW_CACHE="$OGOM/.brew-x86/cache"
export HOMEBREW_LOGS="$OGOM/.brew-x86/logs"
export HOMEBREW_TEMP="$OGOM/.brew-x86/tmp"
mkdir -p "$HOMEBREW_CACHE" "$HOMEBREW_LOGS" "$HOMEBREW_TEMP"
