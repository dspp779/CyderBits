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
if [[ "$output" != *"crossover-sources-26.3.0.tar.gz"* && "$output" != *"CX26 sources already present"* ]]; then
  echo "ASSERT failed: dry-run should prepare CX26 sources" >&2
  exit 1
fi
assert_contains "$output" "brew_x86 install" "dry-run should install deps via project brew_x86"
assert_contains "$output" "brew_x86_install_runtime" \
  "dry-run should rebuild runtime formulae from source for the product floor"
assert_contains "$output" "PKG_CONFIG_PATH=" "dry-run configure must set PKG_CONFIG_PATH for keg-only deps"
assert_contains "$output" "require pkg-config freetype2" "dry-run should check for x86_64 freetype2"
assert_contains "$output" "ensure" "dry-run should ensure bzip2.pc exists"
assert_contains "$output" "build/cx26/sources/wine" "dry-run should use CX26 source tree"
assert_not_contains "$output" "cyder-compatdb-runtime.patch" \
  "app-side builds must not modify CrossOver ntdll for CompatDB"
assert_not_contains "$output" "cyder-steam-webhelper-compat.patch" \
  "app-side builds must not carry the old executable-specific Steam patch"
assert_contains "$output" "$ROOT/patches/obsolete/cyder-ntdll-frame-walk-guard.patch" \
  "build should migrate an existing combined frame-walk patch"
assert_contains "$output" "superseded by: $ROOT/patches/cyder-ntdll-frame-walk-page-fault-guard.patch" \
  "build should recognize the fully migrated two-patch source state"
assert_contains "$output" "superseded by: $ROOT/patches/wine-11.1-rtlwalkframechain-null-function.patch" \
  "build should recognize a partially migrated incremental source tree"
assert_contains "$output" "$ROOT/patches/wine-11.1-rtlwalkframechain-null-function.patch" \
  "build should backport the upstream x64 null-function stop"
assert_contains "$output" "$ROOT/patches/cyder-ntdll-frame-walk-page-fault-guard.patch" \
  "build should guard x86_64 frame walking against invalid unwind metadata"
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
assert_contains "$output" "--disable-tests" "runtime builds should skip Wine regression tests"
assert_contains "$output" "install/wine-cx26-x86_64" "dry-run should install to CX26 prefix"
assert_contains "$output" "make -j" "dry-run should show the compile step"
assert_contains "$output" "make install" "dry-run should show the install step"
assert_contains "$output" "bundle-wine-dylibs.sh" "dry-run should bundle relocatable dylibs after install"
assert_contains "$output" "--without-vulkan" "default dry-run should disable Vulkan"

output_vk_homebrew="$(bash "$ROOT/scripts/build-wine.sh" --cx 26 --dry-run --install-deps --with-vulkan --vulkan-source homebrew 2>&1 || true)"
assert_contains "$output_vk_homebrew" "molten-vk" "homebrew vulkan deps should include molten-vk"
if [[ "$output_vk_homebrew" == *"require libMoltenVK.dylib"* ]]; then
  assert_contains "$output_vk_homebrew" "require libMoltenVK.dylib" "with-vulkan homebrew should check MoltenVK when missing"
else
  assert_contains "$output_vk_homebrew" "opt/molten-vk/lib" "with-vulkan homebrew should add MoltenVK to LIBRARY_PATH when present"
fi

output_vk_crossover="$(bash "$ROOT/scripts/build-wine.sh" --cx 26 --dry-run --install-deps --with-vulkan --vulkan-source crossover 2>&1 || true)"
assert_contains "$output_vk_crossover" "cmake" "crossover vulkan deps should include cmake"
assert_contains "$output_vk_crossover" "build-graphics-stack.sh" "crossover path should reference graphics stack build"
assert_contains "$output_vk_crossover" "require" "crossover path should check graphics install"
assert_contains "$output_vk_crossover" "graphics-cx26-x86_64" "crossover path should use graphics prefix"

retired_msg='CX25 support was retired; this tree only builds CrossOver 26.'
if output_cx25="$(bash "$ROOT/scripts/build-wine.sh" --cx 25 --dry-run --without-vulkan 2>&1)"; then
  echo "ASSERT failed: build-wine --cx 25 must fail" >&2
  exit 1
fi
assert_contains "$output_cx25" "$retired_msg" "build-wine --cx 25 must print the retired message"


echo "PASS test-build-wine"
