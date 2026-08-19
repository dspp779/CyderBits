#!/usr/bin/env bash
# Build the CrossOver 25 DXVK snapshot with llvm-mingw and stage it in a Wine engine.
# Compile notes: docs/build-dxvk.zh-TW.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCHIVE="${DXVK_SOURCE_ARCHIVE:-$ROOT/tools/archives/crossover-sources-25.0.1.tar.gz}"
TOOLCHAIN="${LLVM_MINGW:-$ROOT/tools/llvm-mingw-20260616-ucrt-macos-universal}"
WORK="${DXVK_BUILD_ROOT:-$ROOT/build/dxvk-cx26}"
ENGINE="${WINE_INSTALL:-$ROOT/install/wine-cx26-x86_64}"
SOURCE="$WORK/sources/dxvk"
STAGE="$WORK/dxvk-stage"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
DRY_RUN=0
COPY_ONLY=0
ALSO_ENGINES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--engine PATH] [--also-engine PATH] [--work-dir PATH] [--copy-only] [--dry-run]

Build the D3D9/D3D10/D3D11/DXGI subset of CrossOver 25.0.1's DXVK snapshot for
win64 and win32, then install it below ENGINE/lib/dxvk/. Repeat --also-engine to
install the same staged payload into additional engines without rebuilding.

With --copy-only, skip the build and copy ENGINE/lib/dxvk/ into each
--also-engine destination (requires an existing primary engine payload).

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
    --also-engine) ALSO_ENGINES+=("$2"); shift 2 ;;
    --work-dir) WORK="$2"; SOURCE="$WORK/sources/dxvk"; STAGE="$WORK/dxvk-stage"; shift 2 ;;
    --copy-only) COPY_ONLY=1; shift ;;
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

install_dxvk_into_engine() {
  local dest_engine="$1"
  local modules=(d3d9 d3d10 d3d10_1 d3d10core d3d11 dxgi)
  local pinned_version=""
  [[ "$dest_engine" == /* ]] || { echo "Engine path must be absolute: $dest_engine" >&2; return 1; }
  run mkdir -p "$dest_engine/lib/dxvk/x86_64-windows" "$dest_engine/lib/dxvk/i386-windows"
  for machine in x86_64-windows i386-windows; do
    for module in "${modules[@]}"; do
      run cp "$STAGE/$machine/bin/$module.dll" "$dest_engine/lib/dxvk/$machine/$module.dll"
    done
  done
  run cp "$SOURCE/LICENSE" "$dest_engine/lib/dxvk/LICENSE"
  run cp "$SOURCE/dxvk.conf" "$dest_engine/lib/dxvk/dxvk.conf"
  if [[ -f "$SOURCE/RELEASE" ]]; then
    pinned_version="$(python3 "$SCRIPT_DIR/pin-dxvk-version.py" "$SOURCE")"
    if (( DRY_RUN )); then
      printf '+ printf %s\n %q >%q\n' "dxvk ${pinned_version}" "$dest_engine/lib/dxvk/version"
    else
      {
        printf 'dxvk %s\n' "$pinned_version"
      } >"$dest_engine/lib/dxvk/version"
    fi
  else
    echo "Warning: missing $SOURCE/RELEASE; pack will fall back to unknown DXVK version" >&2
  fi
  run python3 "$SCRIPT_DIR/stamp-wine-builtin-pe.py" "$dest_engine/lib/dxvk"
}

copy_dxvk_from_engine() {
  local src_engine="$1" dest_engine="$2"
  [[ "$src_engine" == /* && "$dest_engine" == /* ]] ||
    { echo "Engine paths must be absolute: $src_engine $dest_engine" >&2; return 1; }
  [[ -f "$src_engine/lib/dxvk/x86_64-windows/d3d11.dll" ]] ||
    { echo "Missing DXVK payload in source engine: $src_engine/lib/dxvk" >&2; return 1; }
  run mkdir -p "$dest_engine/lib/dxvk"
  run cp -R "$src_engine/lib/dxvk/." "$dest_engine/lib/dxvk/"
  run python3 "$SCRIPT_DIR/stamp-wine-builtin-pe.py" "$dest_engine/lib/dxvk"
}

if (( COPY_ONLY )); then
  if ((${#ALSO_ENGINES[@]} == 0)); then
    echo "--copy-only requires at least one --also-engine destination" >&2
    exit 1
  fi
  for also in "${ALSO_ENGINES[@]}"; do
    copy_dxvk_from_engine "$ENGINE" "$also"
  done
  echo "DXVK copied from $ENGINE/lib/dxvk into ${#ALSO_ENGINES[@]} additional engine(s)"
  exit 0
fi

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

patch_dxvk_source() {
  local header="$SOURCE/src/d3d10/d3d10_interfaces.h"
  local pinned_version=""
  if [[ -f "$SOURCE/meson.build" && -f "$SOURCE/RELEASE" ]]; then
    pinned_version="$(python3 "$SCRIPT_DIR/pin-dxvk-version.py" "$SOURCE")"
    echo "DXVK version pinned to $pinned_version (from RELEASE; not parent git describe)"
  fi
  local d3d9_header="$SOURCE/src/d3d9/d3d9_include.h"
  if [[ -f "$d3d9_header" ]]; then
    python3 - "$d3d9_header" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """// MinGW headers are broken. Who'dve guessed?
#ifndef _MSC_VER
typedef struct _D3DDEVINFO_RESOURCEMANAGER
"""
new = """// Older MinGW headers omit this type. MinGW-w64 15 provides the real
// definition, so do not redeclare it when building with current llvm-mingw.
#if !defined(_MSC_VER) \
 && (!defined(__MINGW64_VERSION_MAJOR) || __MINGW64_VERSION_MAJOR < 15)
typedef struct _D3DDEVINFO_RESOURCEMANAGER
"""
if old in text:
    path.write_text(text.replace(old, new, 1))
PY
  fi
  [[ -f "$header" ]] || return 0
  python3 - "$header" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """#ifdef _MSC_VER
struct __declspec(uuid("0803425a-57f5-4dd6-9465-a87570834a08")) ID3D10StateBlock;
#else
__CRT_UUID_DECL(ID3D10StateBlock, 0x0803425a,0x57f5,0x4dd6,0x94,0x65,0xa8,0x75,0x70,0x83,0x4a,0x08);
#endif
"""
new = """#ifdef _MSC_VER
struct __declspec(uuid("0803425a-57f5-4dd6-9465-a87570834a08")) ID3D10StateBlock;
#elif !defined(__MINGW32__)
__CRT_UUID_DECL(ID3D10StateBlock, 0x0803425a,0x57f5,0x4dd6,0x94,0x65,0xa8,0x75,0x70,0x83,0x4a,0x08);
#endif
"""
if old in text:
    path.write_text(text.replace(old, new, 1))
PY
}

if (( ! DRY_RUN )); then
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
  patch_dxvk_source
else
  GLSLANG="${GLSLANG_VALIDATOR:-$ROOT/.brew-x86/bin/glslangValidator}"
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
  local setup_args=(
    --cross-file "$cross"
    --buildtype release
    --prefix "$STAGE/$machine"
    --bindir bin
    --libdir lib
    -Denable_tests=false
    -Denable_d3d9=true
    -Denable_d3d10=true
    -Denable_d3d11=true
    -Denable_dxgi=true
  )
  if [[ -f "$build/build.ninja" ]]; then
    run env \
      PATH="$TOOLCHAIN/bin:$ROOT/.brew-x86/bin:/usr/bin:/bin" \
      GLSLANG_VALIDATOR="$GLSLANG" \
      "$ROOT/.brew-x86/bin/meson" setup \
      --reconfigure \
      "${setup_args[@]}" \
      "$build" "$SOURCE"
  else
    run env \
      PATH="$TOOLCHAIN/bin:$ROOT/.brew-x86/bin:/usr/bin:/bin" \
      GLSLANG_VALIDATOR="$GLSLANG" \
      "$ROOT/.brew-x86/bin/meson" setup \
      "${setup_args[@]}" \
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

install_dxvk_into_engine "$ENGINE"
if ((${#ALSO_ENGINES[@]})); then
  for also in "${ALSO_ENGINES[@]}"; do
    install_dxvk_into_engine "$also"
  done
fi

echo "DXVK D3D9/D3D10/D3D11/DXGI installed in $ENGINE/lib/dxvk"
if ((${#ALSO_ENGINES[@]})); then
  echo "DXVK also installed in ${#ALSO_ENGINES[@]} additional engine(s)"
fi
