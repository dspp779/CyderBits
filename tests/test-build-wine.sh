#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

output="$(bash "$ROOT/scripts/build-wine.sh" --dry-run --bootstrap-brew --install-deps 2>&1 || true)"

assert_contains "$output" "Homebrew/brew" "dry-run should bootstrap Homebrew into .brew-x86"
assert_contains "$output" ".brew-x86/bin/brew install autoconf bison flex pkg-config freetype gettext gnutls" "dry-run should install isolated deps"
assert_contains "$output" "./tools/make_requests" "dry-run should rebuild Wine generated files"
assert_contains "$output" "../configure -C --enable-win64 --with-mingw=llvm-mingw" "dry-run should show expected configure flags"
assert_contains "$output" "make -j" "dry-run should show the compile step"
assert_contains "$output" "make install" "dry-run should show the install step"

echo "PASS test-build-wine"
