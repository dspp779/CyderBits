#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
BOOTSTRAP_BREW=0
INSTALL_DEPS=0
CONFIGURE_ONLY=0
PREPARE_ONLY=0
CX_VERSION="${CX_VERSION:-26}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
VULKAN_MODE=without
VULKAN_SOURCE=homebrew
BUILD_TESTS=0

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --bootstrap-brew) BOOTSTRAP_BREW=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --configure-only) CONFIGURE_ONLY=1 ;;
    --prepare-only) PREPARE_ONLY=1 ;;
    --with-tests) BUILD_TESTS=1 ;;
    --cx)
      CX_VERSION="$2"
      shift
      ;;
    --jobs)
      JOBS="$2"
      shift
      ;;
    --with-vulkan)
      VULKAN_MODE=with
      ;;
    --without-vulkan)
      VULKAN_MODE=without
      ;;
    --vulkan-source)
      VULKAN_SOURCE="$2"
      shift
      ;;
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [options]

Build CrossOver Wine for macOS x86_64 (Rosetta).

Options:
  --cx 25|26         CrossOver release (default: 26)
  --prepare-only     Extract archives from tools/archives/ and exit
  --with-tests       Build Wine regression-test executables (off for runtime builds)
  --bootstrap-brew   Install project-local x86_64 Homebrew
  --install-deps     Install build dependencies via .brew-x86
  --with-vulkan      Enable Vulkan (Wine configure autodetects MoltenVK)
  --without-vulkan   Disable Vulkan (Wine ./configure --without-vulkan)
  --vulkan-source SRC
                     With --with-vulkan: homebrew (default) or crossover
                     crossover: use install from build-graphics-stack.sh
  --configure-only   Run configure without make/install
  --jobs N           Parallel make jobs (default: CPU count)
  --dry-run          Print commands without executing
  -h, --help         Show this help

Vulkan examples:
  bash scripts/build-wine.sh --install-deps --without-vulkan
  bash scripts/build-wine.sh --install-deps --with-vulkan --vulkan-source homebrew
  bash scripts/build-graphics-stack.sh --cx 26 --install-deps && \\
    bash scripts/build-graphics-stack.sh --cx 26
  bash scripts/build-wine.sh --with-vulkan --vulkan-source crossover
  bash scripts/build-media-stack.sh --cx 26
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
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

case "$VULKAN_SOURCE" in
  homebrew | crossover) ;;
  *)
    echo "Unknown --vulkan-source: $VULKAN_SOURCE (expected homebrew or crossover)" >&2
    exit 1
    ;;
esac

if [[ "$VULKAN_MODE" == "without" && "$VULKAN_SOURCE" != "homebrew" ]]; then
  echo "--vulkan-source is only valid with --with-vulkan" >&2
  exit 1
fi

export CX_VERSION
source "$SCRIPT_DIR/env-x86_64.sh"

PREPARE_ARGS=(--cx "$CX_VERSION")
[[ "$DRY_RUN" -eq 1 ]] && PREPARE_ARGS+=(--dry-run)
"$SCRIPT_DIR/prepare-build-deps.sh" "${PREPARE_ARGS[@]}"


if [[ "$PREPARE_ONLY" -eq 1 ]]; then
  exit 0
fi

bootstrap_brew() {
  if [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    echo "Homebrew already present at $HOMEBREW_PREFIX"
    return 0
  fi

  run mkdir -p "$HOMEBREW_PREFIX"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ curl -L https://github.com/Homebrew/brew/tarball/master | tar xz --strip-components=1 -C $HOMEBREW_PREFIX"
    return 0
  fi

  curl -L https://github.com/Homebrew/brew/tarball/master \
    | tar xz --strip-components=1 -C "$HOMEBREW_PREFIX"
  # Ensure brew metadata points at the project prefix, not /opt/homebrew.
  brew_x86 update --force --quiet 2>/dev/null || true
}

if [[ "$BOOTSTRAP_BREW" -eq 1 ]]; then
  bootstrap_brew
fi

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  if [[ ! -x "$HOMEBREW_PREFIX/bin/brew" && "$DRY_RUN" -eq 0 ]]; then
    echo "Missing $HOMEBREW_PREFIX/bin/brew; run with --bootstrap-brew first" >&2
    exit 1
  fi
  DEPS=(autoconf bison flex pkgconf freetype gettext gnutls zlib bzip2)
  if [[ "$VULKAN_MODE" == "with" ]]; then
    case "$VULKAN_SOURCE" in
      homebrew)
        DEPS+=(molten-vk vulkan-headers)
        ;;
      crossover)
        DEPS+=(cmake python3)
        ;;
    esac
  fi
  run brew_x86 install "${DEPS[@]}"
  if [[ "$VULKAN_MODE" == "with" && "$VULKAN_SOURCE" == "crossover" ]]; then
    echo "CrossOver Vulkan: run build-graphics-stack.sh after deps (cmake/python3 installed)."
    echo "  bash scripts/build-graphics-stack.sh --cx $CX_VERSION"
  fi
fi

# Sanitize PATH so configure/make never pick /opt/homebrew (arm64) pkg-config/libs.
BUILD_PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# keg-only formulae ship .pc under opt/*/lib/pkgconfig
PKG_PC_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/zlib/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/bzip2/lib/pkgconfig"

require_moltenvk_homebrew() {
  local lib
  for lib in \
    "$HOMEBREW_PREFIX/opt/molten-vk/lib/libMoltenVK.dylib" \
    "$HOMEBREW_PREFIX/lib/libMoltenVK.dylib"; do
    if [[ -f "$lib" ]]; then
      return 0
    fi
  done
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ require libMoltenVK.dylib in $HOMEBREW_PREFIX"
    return 0
  fi
  echo "Missing x86_64 libMoltenVK.dylib in $HOMEBREW_PREFIX." >&2
  echo "Re-run: bash scripts/build-wine.sh --install-deps --with-vulkan --vulkan-source homebrew" >&2
  exit 1
}

require_moltenvk_crossover() {
  local lib="$GRAPHICS_INSTALL/lib/libMoltenVK.dylib"
  if [[ -f "$lib" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ require $lib from build-graphics-stack.sh"
    return 0
  fi
  echo "Missing $lib" >&2
  echo "Build CrossOver MoltenVK first:" >&2
  echo "  bash scripts/build-graphics-stack.sh --cx $CX_VERSION --install-deps" >&2
  echo "  bash scripts/build-graphics-stack.sh --cx $CX_VERSION" >&2
  exit 1
}

# Homebrew bzip2 is keg-only and may not install a .pc file; freetype2.pc needs it.
ensure_bzip2_pc() {
  local pc="$HOMEBREW_PREFIX/lib/pkgconfig/bzip2.pc"
  local prefix="$HOMEBREW_PREFIX/opt/bzip2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ ensure $pc"
    return 0
  fi
  if [[ -f "$pc" || -f "$prefix/lib/pkgconfig/bzip2.pc" ]]; then
    return 0
  fi
  if [[ ! -d "$prefix" ]]; then
    echo "Missing $prefix; re-run with --install-deps" >&2
    exit 1
  fi
  mkdir -p "$HOMEBREW_PREFIX/lib/pkgconfig"
  cat > "$pc" <<EOF
prefix=$prefix
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
EOF
  echo "wrote $pc (homebrew bzip2 is keg-only without a .pc)"
}

require_x86_dep() {
  local pc="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ require pkg-config $pc via $HOMEBREW_PREFIX"
    return 0
  fi
  if [[ ! -x "$HOMEBREW_PREFIX/bin/pkg-config" ]]; then
    echo "Missing $HOMEBREW_PREFIX/bin/pkg-config; re-run with --install-deps" >&2
    exit 1
  fi
  if ! arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$PKG_PC_PATH" \
      "$HOMEBREW_PREFIX/bin/pkg-config" --exists "$pc"; then
    echo "Missing x86_64 $pc in $HOMEBREW_PREFIX (not /opt/homebrew)." >&2
    arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$PKG_PC_PATH" \
      "$HOMEBREW_PREFIX/bin/pkg-config" --exists --print-errors "$pc" 2>&1 || true
    echo "Re-run: bash scripts/build-wine.sh --install-deps" >&2
    exit 1
  fi
}

ensure_bzip2_pc
require_x86_dep freetype2
CONFIGURE_VULKAN_FLAG=()
if [[ "$VULKAN_MODE" == "without" ]]; then
  CONFIGURE_VULKAN_FLAG=(--without-vulkan)
fi

VULKAN_LIB_PATHS=()
VULKAN_PKG_PC_PATH="$PKG_PC_PATH"

if [[ "$VULKAN_MODE" == "with" ]]; then
  case "$VULKAN_SOURCE" in
    homebrew)
      require_moltenvk_homebrew
      VULKAN_LIB_PATHS+=("$HOMEBREW_PREFIX/opt/molten-vk/lib" "$HOMEBREW_PREFIX/lib")
      if [[ -d "$HOMEBREW_PREFIX/opt/molten-vk/lib/pkgconfig" ]]; then
        VULKAN_PKG_PC_PATH="$HOMEBREW_PREFIX/opt/molten-vk/lib/pkgconfig:$VULKAN_PKG_PC_PATH"
      fi
      ;;
    crossover)
      require_moltenvk_crossover
      VULKAN_LIB_PATHS+=("$GRAPHICS_INSTALL/lib")
      ;;
  esac
fi

if [[ ${#VULKAN_LIB_PATHS[@]} -gt 0 ]]; then
  for _vulkan_lib in "${VULKAN_LIB_PATHS[@]}"; do
    PKG_PC_PATH="$_vulkan_lib/pkgconfig:$PKG_PC_PATH"
    export LIBRARY_PATH="${_vulkan_lib}${LIBRARY_PATH:+:$LIBRARY_PATH}"
  done
  unset _vulkan_lib
fi

run mkdir -p "$OGOM/install" "$WINE_SRC/build64"
# Dry-run only prints mkdir; still create dirs so subsequent cd works.
mkdir -p "$OGOM/install" "$WINE_SRC/build64"

cd "$WINE_SRC"
# CrossOver tarball is not a git checkout; make_makefiles requires `git ls-files`.
# Regenerators are only needed when hacking the wine tree as a git worktree.
if [[ -e "$WINE_SRC/.git" || -n "${GIT_DIR:-}" ]]; then
  run ./tools/make_requests
  run ./tools/make_specfiles
  run ./tools/make_makefiles
  run arch -x86_64 env PATH="$BUILD_PATH" autoreconf -f
else
  echo "Non-git wine tree; skipping make_requests/make_specfiles/make_makefiles/autoreconf"
fi

cd "$WINE_SRC/build64"

CONFIGURE_CMD=(
  arch -x86_64 env
  PATH="$BUILD_PATH"
  BISON="$HOMEBREW_PREFIX/opt/bison/bin/bison"
  PKG_CONFIG="$HOMEBREW_PREFIX/bin/pkg-config"
  PKG_CONFIG_PATH="$VULKAN_PKG_PC_PATH"
  LIBRARY_PATH="${LIBRARY_PATH:-}"
  ../configure
  -C
  --enable-win64
  --enable-archs=i386,x86_64
  --with-mingw=llvm-mingw
  --prefix="$WINE_INSTALL"
)
if [[ "$BUILD_TESTS" -eq 0 ]]; then
  CONFIGURE_CMD+=(--disable-tests)
fi
if [[ ${#CONFIGURE_VULKAN_FLAG[@]} -gt 0 ]]; then
  CONFIGURE_CMD+=("${CONFIGURE_VULKAN_FLAG[@]}")
fi

echo "configure command:"
printf '  '
for arg in "${CONFIGURE_CMD[@]}"; do
  printf '%q ' "$arg"
done
printf '\n'

run "${CONFIGURE_CMD[@]}"

if [[ "$CONFIGURE_ONLY" -eq 0 ]]; then
  run arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$VULKAN_PKG_PC_PATH" LIBRARY_PATH="${LIBRARY_PATH:-}" make -j"$JOBS"
  run arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$VULKAN_PKG_PC_PATH" LIBRARY_PATH="${LIBRARY_PATH:-}" make install
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ GRAPHICS_INSTALL=${GRAPHICS_INSTALL:-} VULKAN_MODE=$VULKAN_MODE $SCRIPT_DIR/bundle-wine-dylibs.sh"
  else
    GRAPHICS_INSTALL="$GRAPHICS_INSTALL" MEDIA_INSTALL="$MEDIA_INSTALL" VULKAN_MODE="$VULKAN_MODE" \
      "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$WINE_INSTALL"
  fi
fi
