#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-macos-compat.sh
source "$ROOT/scripts/cyder-macos-compat.sh"
# shellcheck source=../scripts/cyder-moltenvk-variant.sh
source "$ROOT/scripts/cyder-moltenvk-variant.sh"

FAKE="$(mktemp -d "${TMPDIR:-/tmp}/cyder-mvk-variant.XXXXXX")"
cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

UNIX="$FAKE/lib/wine/x86_64-unix"
mkdir -p "$UNIX"
# Fixtures are built with the developer toolchain; the code under test must
# never run it. Every Command Line Tools shim on PATH fails loudly.
sdk="$(xcrun --sdk macosx --show-sdk-path)"
CLANG=/usr/bin/clang
BIN="$FAKE/bin"
mkdir -p "$BIN"
for tool in otool strings vtool lipo nm xcrun install_name_tool size; do
  printf '#!/bin/sh\necho "developer tool invoked: %s" >&2\ntouch "%s/devtool-used"\nexit 99\n' "$tool" "$FAKE" >"$BIN/$tool"
  chmod +x "$BIN/$tool"
done
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
printf 'int mvk_probe = 1;\n' > "$FAKE/probe.c"
printf 'const char cyder_marker[] = "cyder-moltenvk-timeline-wait-poll";\nint mvk_shim = 1;\n' > "$FAKE/shim.c"
build_real() {
  "$CLANG" -arch x86_64 -isysroot "$sdk" -mmacosx-version-min="$2" \
    -install_name '@loader_path/libMoltenVK.real.dylib' -dynamiclib "$FAKE/probe.c" -o "$1"
}
build_shim() {
  # Re-export a .real at link time, like the engine wait-poll shim.
  local dir="$FAKE/link"; mkdir -p "$dir"
  build_real "$dir/libMoltenVK.real.dylib" 10.15
  "$CLANG" -arch x86_64 -isysroot "$sdk" -mmacosx-version-min="${2:-10.15}" -dynamiclib "$FAKE/shim.c" \
    -Wl,-reexport_library,"$dir/libMoltenVK.real.dylib" -o "$1"
}
build_real "$UNIX/libMoltenVK-1.4.2.dylib" 12.0
build_real "$UNIX/libMoltenVK-1.2.10.dylib" 10.15
build_shim "$UNIX/libMoltenVK.dylib"

# A runtime left by Cyder013 has .real on the retired 1.2.10 real; the
# launch points it back at 1.4.2 whatever macOS reports.
ln -sfn libMoltenVK-1.2.10.dylib "$UNIX/libMoltenVK.real.dylib"
for host in 11.0 13.0; do
  CYDER_MOCK_MACOS="$host"
  cyder_ensure_moltenvk_real "$FAKE"
  assert_eq "$(readlink "$UNIX/libMoltenVK.real.dylib")" "libMoltenVK-1.4.2.dylib" \
    "ensure must point .real at 1.4.2 (macOS $host)"
  cyder_ensure_moltenvk_real "$FAKE"
  assert_eq "$(readlink "$UNIX/libMoltenVK.real.dylib")" "libMoltenVK-1.4.2.dylib" \
    "ensure twice must stay stable"
  ln -sfn libMoltenVK-1.2.10.dylib "$UNIX/libMoltenVK.real.dylib"
done
# A Cyder014 engine has no 1.2.10 real at all.
rm "$UNIX/libMoltenVK-1.2.10.dylib"
cyder_ensure_moltenvk_real "$FAKE"
assert_eq "$(readlink "$UNIX/libMoltenVK.real.dylib")" "libMoltenVK-1.4.2.dylib" \
  "ensure must repair a dangling link to the removed 1.2.10 real"
# The selection CLI and functions are gone.
if declare -F cyder_resolve_moltenvk_variant cyder_default_moltenvk_variant_preference >/dev/null 2>&1; then
  echo "ASSERT failed: MoltenVK variant selection must be removed" >&2; exit 1
fi
CYDER_MOCK_MACOS=11.0

# Soft ensure on engines without the versioned layout must succeed.
SINGLE="$(mktemp -d "${TMPDIR:-/tmp}/cyder-mvk-single.XXXXXX")"
mkdir -p "$SINGLE/lib/wine/x86_64-unix"
: >"$SINGLE/lib/wine/x86_64-unix/libMoltenVK.dylib"
assert cyder_ensure_moltenvk_real "$SINGLE"
assert cyder_ensure_moltenvk_real "$SINGLE/missing"
rm -rf "$SINGLE"

# Real Mach-O fixtures: do not mistake a version/name for loadability.
build_real "$UNIX/libMoltenVK.dylib" 10.15
build_real "$UNIX/libMoltenVK-1.4.2.dylib" 12.0
ln -sfn libMoltenVK-1.4.2.dylib "$UNIX/libMoltenVK.real.dylib"
for host in 10.15 11.0 11.7.10; do
  CYDER_MOCK_MACOS="$host"
  if cyder_validate_moltenvk_for_backend "$FAKE" dxvk 2> "$FAKE/error"; then
    echo "expected macOS $host to reject minOS 12 real" >&2; exit 1
  fi
  assert_contains "$(cat "$FAKE/error")" 'requires macOS 12.0' 'error explains actual floor'
  for backend in wined3d d3dmetal dxmt default; do
    assert cyder_validate_moltenvk_for_backend "$FAKE" "$backend"
  done
done
for host in 12.0 13.0; do
  CYDER_MOCK_MACOS="$host"
  assert cyder_validate_moltenvk_for_backend "$FAKE" dxvk
done
# The gate reads the actual floor: a real built for 10.15 passes on 10.15/11,
# and a single-dylib engine remains usable.
build_real "$FAKE/low-real.dylib" 10.15
ln -sfn ../../../low-real.dylib "$UNIX/libMoltenVK.real.dylib"
for host in 10.15 11.0; do
  CYDER_MOCK_MACOS="$host"
  assert cyder_validate_moltenvk_for_backend "$FAKE" dxvk
done
rm "$UNIX/libMoltenVK.real.dylib"
assert cyder_validate_moltenvk_for_backend "$FAKE" dxvk
# Real re-export shim must not hide a missing dependency behind its 10.15 floor.
cp "$UNIX/libMoltenVK.dylib" "$FAKE/single.dylib"
ln -s ../../../low-real.dylib "$UNIX/libMoltenVK.real.dylib"
"$CLANG" -arch x86_64 -isysroot "$sdk" -mmacosx-version-min=10.15 \
  -dynamiclib "$FAKE/probe.c" -Wl,-reexport_library,"$UNIX/libMoltenVK.real.dylib" \
  -o "$UNIX/libMoltenVK.dylib"
assert cyder_validate_moltenvk_for_backend "$FAKE" dxvk
rm "$UNIX/libMoltenVK.real.dylib"
if cyder_validate_moltenvk_for_backend "$FAKE" dxvk 2>/dev/null; then exit 1; fi
cp "$FAKE/single.dylib" "$UNIX/libMoltenVK.dylib"
# The shim itself must also fit the host.
build_real "$UNIX/libMoltenVK.dylib" 12.0
if cyder_validate_moltenvk_for_backend "$FAKE" dxvk 2>/dev/null; then exit 1; fi
cp "$FAKE/single.dylib" "$UNIX/libMoltenVK.dylib"

# Missing/broken real, non-Mach-O and missing x86_64 slice fail closed.
ln -s missing.dylib "$UNIX/libMoltenVK.real.dylib"
if cyder_validate_moltenvk_for_backend "$FAKE" dxvk 2>/dev/null; then exit 1; fi
rm "$UNIX/libMoltenVK.real.dylib"
printf 'invalid\n' > "$UNIX/libMoltenVK.dylib"
if cyder_validate_moltenvk_for_backend "$FAKE" dxvk 2>/dev/null; then exit 1; fi
"$CLANG" -arch arm64 -isysroot "$sdk" -mmacosx-version-min=12.0 \
  -dynamiclib "$FAKE/probe.c" -o "$UNIX/libMoltenVK.dylib"
CYDER_MOCK_MACOS=13.0
if cyder_validate_moltenvk_for_backend "$FAKE" dxvk 2>/dev/null; then exit 1; fi
# Old lib64 layout is checked too.
mkdir -p "$FAKE/old/lib64"
build_real "$FAKE/old/lib64/libMoltenVK.dylib" 10.15
CYDER_MOCK_MACOS=11.0
assert cyder_validate_moltenvk_for_backend "$FAKE/old" dxvk
build_real "$FAKE/old/lib64/libMoltenVK.dylib" 12.0
if cyder_validate_moltenvk_for_backend "$FAKE/old" dxvk 2>/dev/null; then exit 1; fi

# Old Mach-O load command and patch-level floors are compared correctly.
build_real "$FAKE/legacy.dylib" 10.13
assert_contains "$(cyder_macho_inspect "$FAKE/legacy.dylib")" 'minos 10.13.0' 'LC_VERSION_MIN_MACOSX is read'
CYDER_MOCK_MACOS=11.0
assert cyder_moltenvk_check_minos "$FAKE/legacy.dylib"
build_real "$FAKE/patch.dylib" 12.0.1
CYDER_MOCK_MACOS=12.0
if cyder_moltenvk_check_minos "$FAKE/patch.dylib" 2>/dev/null; then exit 1; fi
CYDER_MOCK_MACOS=12.0.1
assert cyder_moltenvk_check_minos "$FAKE/patch.dylib"
# Universal files select the x86_64 slice; truncated files fail closed.
"$CLANG" -arch x86_64 -arch arm64 -isysroot "$sdk" -mmacosx-version-min=11.0 -dynamiclib "$FAKE/probe.c" -o "$FAKE/fat.dylib"
assert_contains "$(cyder_macho_inspect "$FAKE/fat.dylib" x86_64)" 'minos 11.0.0' 'fat x86_64 slice'
head -c 200 "$FAKE/fat.dylib" > "$FAKE/truncated.dylib"
if cyder_macho_inspect "$FAKE/truncated.dylib" >/dev/null 2>&1; then exit 1; fi
assert test ! -e "$FAKE/devtool-used"
CYDER_MOCK_MACOS=11.0

# Exercise the shared Wine entry point: blocked DXVK never spawns Wine.
source "$ROOT/scripts/cyder-common.sh"
cyder_configure_compatdb() { :; }
cyder_apply_steam_compatibility_arguments() { :; }
cyder_wine_locale_exports() { :; }
cyder_apply_gptk_launch_environment() { :; }
cyder_wine_is_crossover_frontend() { return 1; }
mkdir -p "$FAKE/old/bin" "$FAKE/prefix"
printf '#!/bin/sh\ntouch "%s/spawned"\n' "$FAKE" > "$FAKE/old/bin/wine"
chmod +x "$FAKE/old/bin/wine"
CYDER_GRAPHICS_BACKEND=dxvk
if cyder_run_wine_exe "$FAKE/old/bin/wine" "$FAKE/game.exe" "$FAKE/prefix" 2> "$FAKE/error"; then
  echo 'expected Wine entry point to block DXVK' >&2; exit 1
fi
assert test ! -e "$FAKE/spawned"
assert_contains "$(cat "$FAKE/error")" 'DXVK/Vulkan blocked' 'launch surfaces compatibility error'

common="$(cat "$ROOT/scripts/cyder-common.sh")"
launcher="$(cat "$ROOT/scripts/cyder_launcher.sh")"
assert_contains "$common" 'cyder_ensure_moltenvk_real' \
  "common.sh must repair the MoltenVK real link"
assert_contains "$common" 'cyder-moltenvk-variant.sh' \
  "common.sh must source the MoltenVK helper"
assert_contains "$launcher" 'cyder_ensure_moltenvk_real' \
  "launcher path must repair the MoltenVK real link"
assert_not_contains "$common" 'moltenvkVariant' \
  "the retired moltenvkVariant setting must not be read"

settings="$(cat "$ROOT/scripts/cyder_settings.swift")"
assert_not_contains "$settings" 'var moltenvkVariant' "settings must not store a MoltenVK variant"
assert_not_contains "$settings" 'CYDER_MOLTENVK_VARIANT_PREFERENCE": value' \
  "settings must not export a MoltenVK variant"
assert_contains "$settings" 'enum CyderMoltenvk' "launch scope must still detect a residual 1.2.10 link"
assert_contains "$settings" 'schemaVersion = 14' "settings schema must be current"

ui="$(cat "$ROOT/scripts/cyder_settings_ui.swift")"
assert_not_contains "$ui" 'moltenvkVariant' "settings UI must not offer a MoltenVK version"
assert_not_contains "$ui" '1.2.10' "settings UI must not mention MoltenVK 1.2.10"

assert test ! -e "$FAKE/devtool-used"
echo "PASS test-cyder-moltenvk-variant"
