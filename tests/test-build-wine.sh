#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

output="$(bash "$ROOT/scripts/build-wine.sh" --dry-run --bootstrap-brew --install-deps 2>&1 || true)"

if [[ "$output" != *"Homebrew/brew"* && "$output" != *"Homebrew already present"* ]]; then
  echo "ASSERT_CONTAINS failed: dry-run should bootstrap Homebrew or report it already present" >&2
  exit 1
fi
assert_contains "$output" ".brew-x86/bin/brew install -y autoconf bison flex pkgconf freetype gettext gnutls zlib bzip2" "dry-run should install isolated deps non-interactively"
assert_contains "$output" "PKG_CONFIG_PATH=" "dry-run configure must set PKG_CONFIG_PATH for keg-only deps"
assert_contains "$output" "require pkg-config freetype2" "dry-run should check for x86_64 freetype2"
assert_contains "$output" "ensure" "dry-run should ensure bzip2.pc exists"
# Tarball trees skip make_*; git checkouts regenerate.
if [[ -e "$ROOT/sources/wine/.git" ]]; then
  assert_contains "$output" "./tools/make_requests" "dry-run should rebuild Wine generated files"
else
  assert_contains "$output" "Non-git wine tree" "dry-run should skip make_* on tarball sources"
fi
assert_contains "$output" "../configure -C --enable-win64 --with-mingw=llvm-mingw" "dry-run should show expected configure flags"
assert_contains "$output" "make -j" "dry-run should show the compile step"
assert_contains "$output" "make install" "dry-run should show the install step"

echo "PASS test-build-wine"
