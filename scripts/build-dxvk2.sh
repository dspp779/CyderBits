#!/usr/bin/env bash
# Build upstream DXVK 2.x (doitsujin) into ENGINE/lib/dxvk2.
# Leaves ENGINE/lib/dxvk (1.10.3 / CrossOver snapshot) untouched.
# Compile notes: docs/build-dxvk.zh-TW.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DXVK2_VERSION="${DXVK2_VERSION:-2.7.1}"
ARCHIVE="${DXVK2_SOURCE_ARCHIVE:-$ROOT/tools/archives/dxvk-${DXVK2_VERSION}-src.tar.gz}"
TOOLCHAIN="${LLVM_MINGW:-$ROOT/tools/llvm-mingw-20260616-ucrt-macos-universal}"
WORK="${DXVK2_BUILD_ROOT:-$ROOT/build/dxvk-${DXVK2_VERSION}}"
ENGINE="${WINE_INSTALL:-$ROOT/install/wine-cx26-x86_64}"
SOURCE="$WORK/sources/dxvk"
STAGE="$WORK/dxvk2-stage"
DEST_NAME="dxvk2"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
DRY_RUN=0
COPY_ONLY=0
ALSO_ENGINES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--engine PATH] [--also-engine PATH] [--work-dir PATH] [--copy-only] [--dry-run]

Build doitsujin DXVK ${DXVK2_VERSION} for win64 and win32, then install it
below ENGINE/lib/${DEST_NAME}/. Does not modify ENGINE/lib/dxvk.

Environment:
  DXVK2_VERSION         Upstream tag without v (default: 2.7.1)
  DXVK2_SOURCE_ARCHIVE  Fallback source tarball if git clone is skipped
  LLVM_MINGW            llvm-mingw toolchain directory
  GLSLANG_VALIDATOR     glslang / glslangValidator executable
  JOBS                  parallel build jobs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2 ;;
    --also-engine) ALSO_ENGINES+=("$2"); shift 2 ;;
    --work-dir) WORK="$2"; SOURCE="$WORK/sources/dxvk"; STAGE="$WORK/dxvk2-stage"; shift 2 ;;
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

dxvk2_modules=(d3d8 d3d9 d3d10core d3d11 dxgi)

install_dxvk2_into_engine() {
  local dest_engine="$1"
  local dest="$dest_engine/lib/$DEST_NAME"
  local pinned_version=""
  [[ "$dest_engine" == /* ]] || { echo "Engine path must be absolute: $dest_engine" >&2; return 1; }
  run mkdir -p "$dest/x86_64-windows" "$dest/i386-windows"
  for machine in x86_64-windows i386-windows; do
    for module in "${dxvk2_modules[@]}"; do
      run cp "$STAGE/$machine/bin/$module.dll" "$dest/$machine/$module.dll"
    done
  done
  [[ -f "$SOURCE/LICENSE" ]] && run cp "$SOURCE/LICENSE" "$dest/LICENSE"
  [[ -f "$SOURCE/dxvk.conf" ]] && run cp "$SOURCE/dxvk.conf" "$dest/dxvk.conf"
  if [[ -f "$SOURCE/RELEASE" ]]; then
    pinned_version="$(python3 "$SCRIPT_DIR/pin-dxvk-version.py" "$SOURCE")"
    if (( DRY_RUN )); then
      printf '+ printf %s\n %q >%q\n' "dxvk ${pinned_version}" "$dest/version"
    else
      printf 'dxvk %s\n' "$pinned_version" >"$dest/version"
    fi
  else
    echo "Warning: missing $SOURCE/RELEASE; writing ${DXVK2_VERSION}" >&2
    printf 'dxvk v%s\n' "$DXVK2_VERSION" >"$dest/version"
  fi
  run python3 "$SCRIPT_DIR/stamp-wine-builtin-pe.py" "$dest"
}

copy_dxvk2_from_engine() {
  local src_engine="$1" dest_engine="$2"
  [[ "$src_engine" == /* && "$dest_engine" == /* ]] ||
    { echo "Engine paths must be absolute: $src_engine $dest_engine" >&2; return 1; }
  [[ -f "$src_engine/lib/$DEST_NAME/x86_64-windows/d3d11.dll" ]] ||
    { echo "Missing DXVK2 payload: $src_engine/lib/$DEST_NAME" >&2; return 1; }
  run mkdir -p "$dest_engine/lib/$DEST_NAME"
  run cp -R "$src_engine/lib/$DEST_NAME/." "$dest_engine/lib/$DEST_NAME/"
  run python3 "$SCRIPT_DIR/stamp-wine-builtin-pe.py" "$dest_engine/lib/$DEST_NAME"
}

if (( COPY_ONLY )); then
  if ((${#ALSO_ENGINES[@]} == 0)); then
    echo "--copy-only requires at least one --also-engine destination" >&2
    exit 1
  fi
  for also in "${ALSO_ENGINES[@]}"; do
    copy_dxvk2_from_engine "$ENGINE" "$also"
  done
  echo "DXVK2 copied from $ENGINE/lib/$DEST_NAME into ${#ALSO_ENGINES[@]} additional engine(s)"
  exit 0
fi

find_glslang() {
  local candidate
  for candidate in \
    "${GLSLANG_VALIDATOR:-}" \
    "$ROOT/.brew-x86/bin/glslang" \
    "$ROOT/.brew-x86/bin/glslangValidator"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

has_vulkan_headers() {
  [[ -f "$SOURCE/include/vulkan/include/vulkan/vulkan.h" ]] ||
    [[ -f "$SOURCE/include/vulkan/vulkan/vulkan.h" ]]
}

# doitsujin/dxvk#5559 — Clang 22 / libc++ rejects empty std::tuple()
# with piecewise_construct. Harmless on older compilers.
patch_dxvk2_source() {
  python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "src/dxvk/dxvk_pipemanager.cpp"
text = path.read_text()
old = """    auto iter = m_shaderLibraries.emplace(
      std::piecewise_construct,
      std::tuple(),
      std::tuple(m_device, this, key));"""
new = """    auto iter = m_shaderLibraries.emplace(
      std::piecewise_construct,
      std::tuple(key),
      std::tuple(m_device, this, key));"""
if old in text:
    path.write_text(text.replace(old, new, 1))
PY
}

prepare_source() {
  if [[ -f "$SOURCE/meson.build" ]] && has_vulkan_headers; then
    echo "Using existing DXVK2 source: $SOURCE"
    return 0
  fi
  run mkdir -p "$(dirname "$SOURCE")"
  if [[ -d "$SOURCE/.git" ]]; then
    run git -C "$SOURCE" submodule update --init --recursive
    return 0
  fi
  if command -v git >/dev/null; then
    echo "Cloning doitsujin/dxvk v${DXVK2_VERSION} with submodules"
    run git clone --depth 1 --branch "v${DXVK2_VERSION}" --recurse-submodules \
      https://github.com/doitsujin/dxvk.git "$SOURCE"
    return 0
  fi
  [[ -f "$ARCHIVE" ]] || { echo "Missing DXVK2 source archive: $ARCHIVE" >&2; exit 1; }
  echo "Extracting $ARCHIVE (submodules may still be missing)" >&2
  run mkdir -p "$WORK/sources"
  run tar -xzf "$ARCHIVE" -C "$WORK/sources"
  if [[ -d "$WORK/sources/dxvk-${DXVK2_VERSION}" && ! -e "$SOURCE" ]]; then
    run mv "$WORK/sources/dxvk-${DXVK2_VERSION}" "$SOURCE"
  fi
}

if (( ! DRY_RUN )); then
  [[ -x "$TOOLCHAIN/bin/x86_64-w64-mingw32-clang" ]] ||
    { echo "Missing llvm-mingw toolchain: $TOOLCHAIN" >&2; exit 1; }
  [[ -x "$ROOT/.brew-x86/bin/meson" && -x "$ROOT/.brew-x86/bin/ninja" ]] ||
    { echo "Missing project-local meson/ninja under .brew-x86/bin" >&2; exit 1; }
  GLSLANG="$(find_glslang)" || {
    echo "Missing glslang; set GLSLANG_VALIDATOR to an executable." >&2
    exit 1
  }
  prepare_source
  has_vulkan_headers || {
    echo "DXVK2 source is missing Vulkan-Headers submodule under $SOURCE/include/vulkan" >&2
    exit 1
  }
  python3 "$SCRIPT_DIR/pin-dxvk-version.py" "$SOURCE"
  patch_dxvk2_source
else
  GLSLANG="${GLSLANG_VALIDATOR:-$ROOT/.brew-x86/bin/glslang}"
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
  local cross="$WORK/dxvk2-$bits.cross" build="$WORK/dxvk2-build.$bits"
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
    -Denable_d3d8=true
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

install_dxvk2_into_engine "$ENGINE"
if ((${#ALSO_ENGINES[@]})); then
  for also in "${ALSO_ENGINES[@]}"; do
    install_dxvk2_into_engine "$also"
  done
fi

echo "DXVK ${DXVK2_VERSION} installed in $ENGINE/lib/$DEST_NAME"
echo "Left untouched: $ENGINE/lib/dxvk"
