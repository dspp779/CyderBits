#!/usr/bin/env bash
# Build the CrossOver 25 DXVK snapshot with llvm-mingw and stage it in a Wine engine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCHIVE="${DXVK_SOURCE_ARCHIVE:-$ROOT/tools/archives/crossover-sources-25.0.1.tar.gz}"
TOOLCHAIN="${LLVM_MINGW:-$ROOT/tools/llvm-mingw-20260616-ucrt-macos-universal}"
WORK="${DXVK_BUILD_ROOT:-$ROOT/build/maplestory-oem25}"
ENGINE="${WINE_INSTALL:-$ROOT/install/wine-maplestory-oem25-source-x86_64}"
SOURCE="$WORK/sources/dxvk"
STAGE="$WORK/dxvk-stage"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--engine PATH] [--work-dir PATH] [--dry-run]

Build the D3D11/DXGI subset of CrossOver 25.0.1's DXVK snapshot for win64
and win32, then install it below ENGINE/lib/dxvk/.

Environment:
  DXVK_SOURCE_ARCHIVE   CrossOver source archive
  LLVM_MINGW            llvm-mingw toolchain directory
  GLSLANG_VALIDATOR     glslangValidator executable
  JOBS                  parallel build jobs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2 ;;
    --work-dir) WORK="$2"; SOURCE="$WORK/sources/dxvk"; STAGE="$WORK/dxvk-stage"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

run() {
  if (( DRY_RUN )); then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

find_glslang() {
  local candidate
  for candidate in \
    "${GLSLANG_VALIDATOR:-}" \
    "$WORK/glslang-build/StandAlone/glslangValidator" \
    "$ROOT/.brew-x86/bin/glslangValidator"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

[[ -f "$ARCHIVE" ]] || { echo "Missing DXVK source archive: $ARCHIVE" >&2; exit 1; }
[[ -x "$TOOLCHAIN/bin/x86_64-w64-mingw32-clang" ]] ||
  { echo "Missing llvm-mingw toolchain: $TOOLCHAIN" >&2; exit 1; }
[[ -x "$ROOT/.brew-x86/bin/meson" && -x "$ROOT/.brew-x86/bin/ninja" ]] ||
  { echo "Missing project-local meson/ninja under .brew-x86/bin" >&2; exit 1; }
GLSLANG="$(find_glslang)" || {
  echo "Missing glslangValidator; set GLSLANG_VALIDATOR to an executable." >&2
  exit 1
}

if [[ ! -f "$SOURCE/meson.build" ]]; then
  run mkdir -p "$WORK"
  run tar -xzf "$ARCHIVE" -C "$WORK" sources/dxvk
fi

make_cross_file() {
  local file="$1" triplet="$2" family="$3" cpu="$4"
  {
    echo "[binaries]"
    echo "c = '$triplet-clang'"
    echo "cpp = '$triplet-clang++'"
    echo "ar = '$triplet-ar'"
    echo "strip = '$triplet-strip'"
    echo "windres = '$triplet-windres'"
    echo
    echo "[properties]"
    echo "needs_exe_wrapper = true"
    echo
    echo "[host_machine]"
    echo "system = 'windows'"
    echo "cpu_family = '$family'"
    echo "cpu = '$cpu'"
    echo "endian = 'little'"
  } >"$file"
}

build_arch() {
  local bits="$1" triplet="$2" family="$3" cpu="$4" machine="$5"
  local cross="$WORK/dxvk-$bits.cross" build="$WORK/dxvk-build.$bits"
  if (( DRY_RUN )); then
    echo "+ generate $cross"
  else
    make_cross_file "$cross" "$triplet" "$family" "$cpu"
  fi
  if [[ ! -f "$build/build.ninja" ]]; then
    run env \
      PATH="$TOOLCHAIN/bin:$ROOT/.brew-x86/bin:/usr/bin:/bin" \
      GLSLANG_VALIDATOR="$GLSLANG" \
      "$ROOT/.brew-x86/bin/meson" setup \
      --cross-file "$cross" \
      --buildtype release \
      --prefix "$STAGE/$machine" \
      --bindir bin \
      --libdir lib \
      -Denable_tests=false \
      -Denable_d3d9=false \
      -Denable_d3d10=false \
      -Denable_d3d11=true \
      -Denable_dxgi=true \
      "$build" "$SOURCE"
  fi
  run env \
    PATH="$TOOLCHAIN/bin:$ROOT/.brew-x86/bin:/usr/bin:/bin" \
    GLSLANG_VALIDATOR="$GLSLANG" \
    "$ROOT/.brew-x86/bin/meson" compile -C "$build" -j "$JOBS"
  run env \
    PATH="$TOOLCHAIN/bin:$ROOT/.brew-x86/bin:/usr/bin:/bin" \
    "$ROOT/.brew-x86/bin/meson" install -C "$build"
}

build_arch 64 x86_64-w64-mingw32 x86_64 x86_64 x86_64-windows
build_arch 32 i686-w64-mingw32 x86 i686 i386-windows

run mkdir -p "$ENGINE/lib/dxvk/x86_64-windows" "$ENGINE/lib/dxvk/i386-windows"
for machine in x86_64-windows i386-windows; do
  for module in d3d11 dxgi; do
    run cp "$STAGE/$machine/bin/$module.dll" "$ENGINE/lib/dxvk/$machine/$module.dll"
  done
done
run cp "$SOURCE/LICENSE" "$ENGINE/lib/dxvk/LICENSE"
run cp "$SOURCE/dxvk.conf" "$ENGINE/lib/dxvk/dxvk.conf"

echo "DXVK D3D11/DXGI installed in $ENGINE/lib/dxvk"
