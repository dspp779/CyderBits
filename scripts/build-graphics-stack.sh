#!/usr/bin/env bash
# Build MoltenVK (and optionally VKD3D) from CrossOver FOSS sources for x86_64 Wine.
#
# Phase 1 (default): MoltenVK only — enough for Wine configure / winevulkan / runtime dlopen.
# Phase 2 (--with-vkd3d): VKD3D PE build — not wired yet; see docs in this script's --help.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
INSTALL_DEPS=0
WITH_VKD3D=0
CX_VERSION="${CX_VERSION:-26}"
ARCHS="${ARCHS:-x86_64}"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build graphics dependencies from CrossOver FOSS sources (MoltenVK; VKD3D optional).

Installs into \$GRAPHICS_INSTALL (default: install/graphics-cx<ver>-x86_64/lib).

Options:
  --cx 25|26           CrossOver release (default: 26)
  --install-deps       Install MoltenVK build tools via .brew-x86 (cmake, python3)
  --with-vkd3d         Also build VKD3D from CX sources (not implemented yet)
  --archs ARCH         macOS arch for MoltenVK dylib (default: x86_64 for Rosetta Wine)
  --dry-run            Print commands without executing
  -h, --help           Show this help

Typical flow (after prepare-build-deps.sh / build-wine --prepare-only):

  bash scripts/build-graphics-stack.sh --cx 26 --install-deps
  bash scripts/build-graphics-stack.sh --cx 26

Then build Wine with CrossOver Vulkan:

  bash scripts/build-wine.sh --cx 26 --with-vulkan --vulkan-source crossover

Notes:
  - MoltenVK fetchDependencies may download upstream deps (network required).
  - Requires Xcode (xcodebuild). On Apple Silicon, MoltenVK is built under Rosetta
    as x86_64 to match the x86_64 Wine prefix.
  - VKD3D needs Wine PE toolchain integration; use --with-vkd3d only when phase 2 lands.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --with-vkd3d) WITH_VKD3D=1 ;;
    --cx)
      CX_VERSION="$2"
      shift
      ;;
    --archs)
      ARCHS="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

case "$CX_VERSION" in
  25 | 26) ;;
  *)
    echo "Unknown --cx value: $CX_VERSION (expected 25 or 26)" >&2
    exit 1
    ;;
esac

export CX_VERSION
source "$SCRIPT_DIR/env-x86_64.sh"

PREPARE_ARGS=(--cx "$CX_VERSION")
[[ "$DRY_RUN" -eq 1 ]] && PREPARE_ARGS+=(--dry-run)
"$SCRIPT_DIR/prepare-build-deps.sh" "${PREPARE_ARGS[@]}"

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  if [[ ! -x "$HOMEBREW_PREFIX/bin/brew" && "$DRY_RUN" -eq 0 ]]; then
    echo "Missing $HOMEBREW_PREFIX/bin/brew; run: bash scripts/build-wine.sh --bootstrap-brew" >&2
    exit 1
  fi
  # MoltenVK README: cmake + python3; ninja optional.
  run brew_x86 install cmake python3
fi

require_xcode() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ require xcodebuild"
    return 0
  fi
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found; install Xcode or Command Line Tools" >&2
    exit 1
  fi
}

moltenvk_dylib_path() {
  printf '%s/Package/Latest/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib\n' "$MOLTENVK_SRC"
}

build_moltenvk_crossover() {
  local dylib marker
  dylib="$(moltenvk_dylib_path)"
  marker="$GRAPHICS_INSTALL/lib/libMoltenVK.dylib"

  if [[ -f "$marker" && "$DRY_RUN" -eq 0 ]]; then
    echo "MoltenVK already installed at $marker"
    return 0
  fi

  [[ -d "$MOLTENVK_SRC" ]] || {
    echo "Missing $MOLTENVK_SRC; run prepare-build-deps first" >&2
    exit 1
  }

  require_xcode

  echo "Fetching MoltenVK external dependencies (may need network)..."
  run bash -c "cd '$MOLTENVK_SRC' && ./fetchDependencies --macos"

  echo "Building MoltenVK (arch=$ARCHS) from CrossOver snapshot..."
  run arch -x86_64 env \
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)" \
    xcodebuild build \
      -project "$MOLTENVK_SRC/MoltenVKPackaging.xcodeproj" \
      -scheme "MoltenVK Package (macOS only)" \
      -destination "generic/platform=macOS" \
      ARCHS="$ARCHS" \
      ONLY_ACTIVE_ARCH=NO \
      -quiet

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ install $dylib -> $GRAPHICS_INSTALL/lib/libMoltenVK.dylib"
    return 0
  fi

  [[ -f "$dylib" ]] || {
    echo "MoltenVK build failed: missing $dylib" >&2
    exit 1
  }

  run mkdir -p "$GRAPHICS_INSTALL/lib"
  run cp -p "$dylib" "$marker"
  run chmod 755 "$marker"

  local mvk_version=""
  if [[ -f "$MOLTENVK_SRC/MoltenVK/MoltenVK/API/mvk_config.h" ]]; then
    mvk_version="$(grep -E 'MVK_VERSION_STRING' "$MOLTENVK_SRC/MoltenVK/MoltenVK/API/mvk_config.h" \
      | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  fi
  cat > "$GRAPHICS_INSTALL/version" <<EOF
graphics crossover cx${CX_VERSION}
moltenvk ${mvk_version:-crossover-snapshot}
arch ${ARCHS}
source crossover-foss
EOF
  echo "Installed MoltenVK -> $marker"
}

build_vkd3d_crossover() {
  echo "VKD3D build from CrossOver sources is not implemented yet (phase 2)." >&2
  echo "Wine D3D12 needs vkd3d PE DLLs installed into the Wine prefix;" >&2
  echo "see sources/vkd3d/gitlab/build-mac in the CX tarball for CI reference." >&2
  exit 1
}

build_moltenvk_crossover

if [[ "$WITH_VKD3D" -eq 1 ]]; then
  build_vkd3d_crossover
fi

echo "Graphics stack build complete: $GRAPHICS_INSTALL"
