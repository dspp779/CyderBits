#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

output="$(bash "$ROOT/scripts/build-wine.sh" --cx 26 --dry-run --bootstrap-brew --install-deps 2>&1 || true)"

if [[ "$output" != *"Homebrew/brew"* && "$output" != *"Homebrew already present"* ]]; then
  echo "ASSERT_CONTAINS failed: dry-run should bootstrap Homebrew or report it already present" >&2
  exit 1
fi
if [[ "$output" != *"Extracting llvm-mingw"* && "$output" != *"llvm-mingw already present"* ]]; then
  echo "ASSERT failed: dry-run should prepare llvm-mingw" >&2
  exit 1
fi
if [[ "$output" != *"crossover-sources-26.2.0.tar.gz"* && "$output" != *"CX26 sources already present"* ]]; then
  echo "ASSERT failed: dry-run should prepare CX26 sources" >&2
  exit 1
fi
assert_contains "$output" "brew_x86 install" "dry-run should install deps via project brew_x86"
assert_contains "$output" "PKG_CONFIG_PATH=" "dry-run configure must set PKG_CONFIG_PATH for keg-only deps"
assert_contains "$output" "require pkg-config freetype2" "dry-run should check for x86_64 freetype2"
assert_contains "$output" "ensure" "dry-run should ensure bzip2.pc exists"
assert_contains "$output" "build/cx26/sources/wine" "dry-run should use CX26 source tree"
# Tarball trees skip make_*; git checkouts regenerate.
if [[ -e "$ROOT/build/cx26/sources/wine/.git" ]]; then
  assert_contains "$output" "./tools/make_requests" "dry-run should rebuild Wine generated files"
else
  assert_contains "$output" "Non-git wine tree" "dry-run should skip make_* on tarball sources"
fi
assert_contains "$output" "--enable-win64" "dry-run should enable win64 host"
assert_contains "$output" "--enable-archs=i386" "dry-run must build 32-bit PE for BlueCG (PE32)"
assert_contains "$output" "x86_64" "dry-run archs should include x86_64 PE"
assert_contains "$output" "--with-mingw=llvm-mingw" "dry-run should use llvm-mingw"
assert_contains "$output" "install/wine-cx26-x86_64" "dry-run should install to CX26 prefix"
assert_contains "$output" "make -j" "dry-run should show the compile step"
assert_contains "$output" "make install" "dry-run should show the install step"
assert_contains "$output" "bundle-wine-dylibs.sh" "dry-run should bundle relocatable dylibs after install"

output_cx25="$(bash "$ROOT/scripts/build-wine.sh" --cx 25 --prepare-only --dry-run 2>&1 || true)"
if [[ "$output_cx25" != *"crossover-sources-25.1.1.tar.gz"* && "$output_cx25" != *"CX25 sources already present"* ]]; then
  echo "ASSERT failed: CX25 prepare should reference CX25 archive" >&2
  exit 1
fi
assert_contains "$output_cx25" "build/cx25" "CX25 prepare should target cx25 tree"

echo "PASS test-build-wine"
