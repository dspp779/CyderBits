#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

export CX_VERSION=26
source "$ROOT/scripts/env-x86_64.sh"

assert_eq "$OGOM" "$ROOT" "OGOM should point to the repository root"
assert_eq "$HOMEBREW_PREFIX" "$ROOT/.brew-x86" "Homebrew prefix should stay inside the repo"
assert_eq "$LLVM_MINGW" "$ROOT/build/llvm-mingw-20260616-ucrt-macos-universal" "llvm-mingw path should point at build/"
assert_eq "$WINE_INSTALL" "$ROOT/install/wine-cx26-x86_64" "Wine install prefix should match CX26 default"
assert_eq "$WINE_SRC" "$ROOT/build/cx26/sources/wine" "Wine source tree should point at build/cx26/sources/wine"
assert_eq "$CYDER_ENGINE_CX_PREFIX" "CX26" "CX26 build should set engine prefix label"
assert_eq "$BLUECG_PREFIX" "$ROOT/BlueCrossgateNew" "Game prefix should point at BlueCrossgateNew"
assert_eq "$ENTITLEMENTS_PLIST" "$ROOT/config/entitlements.plist" "entitlements path should use tracked config copy"
assert_contains "$PATH" "$ROOT/.brew-x86/bin" "PATH should include isolated Homebrew"
assert_contains "$PATH" "$ROOT/build/llvm-mingw-20260616-ucrt-macos-universal/bin" "PATH should include llvm-mingw"

export CX_VERSION=25
unset WINE_SRC WINE_INSTALL CYDER_ENGINE_CX_PREFIX
# shellcheck disable=SC1091
source "$ROOT/scripts/env-x86_64.sh"
assert_eq "$WINE_INSTALL" "$ROOT/install/wine-cx25-x86_64" "CX25 should use separate install prefix"
assert_eq "$WINE_SRC" "$ROOT/build/cx25/sources/wine" "CX25 source tree should be isolated"
assert_eq "$CYDER_ENGINE_CX_PREFIX" "CX25" "CX25 build should set engine prefix label"

export HOMEBREW_PREFIX=/opt/homebrew
unset WINE_SRC WINE_INSTALL CYDER_ENGINE_CX_PREFIX
# shellcheck disable=SC1091
source "$ROOT/scripts/env-x86_64.sh"
assert_eq "$HOMEBREW_PREFIX" "$ROOT/.brew-x86" "shell /opt/homebrew must not leak into build env"

echo "PASS test-env-x86_64"
