#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/env-x86_64.sh"

assert_eq "$OGOM" "$ROOT" "OGOM should point to the repository root"
assert_eq "$HOMEBREW_PREFIX" "$ROOT/.brew-x86" "Homebrew prefix should stay inside the repo"
assert_eq "$LLVM_MINGW" "$ROOT/llvm-mingw-20260616-ucrt-macos-universal" "llvm-mingw path should match the local toolchain"
assert_eq "$WINE_INSTALL" "$ROOT/install/wine-x86_64" "Wine install prefix should stay inside install/"
assert_eq "$WINE_SRC" "$ROOT/sources/wine" "Wine source tree should point at sources/wine"
assert_eq "$BLUECG_PREFIX" "$ROOT/BlueCrossgateNew" "Game prefix should point at BlueCrossgateNew"
assert_eq "$ENTITLEMENTS_PLIST" "$ROOT/config/entitlements.plist" "entitlements path should use tracked config copy"
assert_contains "$PATH" "$ROOT/.brew-x86/bin" "PATH should include isolated Homebrew"
assert_contains "$PATH" "$ROOT/llvm-mingw-20260616-ucrt-macos-universal/bin" "PATH should include llvm-mingw"

echo "PASS test-env-x86_64"
