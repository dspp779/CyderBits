#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
BOOTSTRAP_BREW=0
INSTALL_DEPS=0
CONFIGURE_ONLY=0
PREPARE_ONLY=0
CX_VERSION="${CX_VERSION:-26}"
JOBS="$(sysctl -n hw.ncpu)"

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
    --cx)
      CX_VERSION="$2"
      shift
      ;;
    --jobs)
      JOBS="$2"
      shift
      ;;
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [options]

Build CrossOver Wine for macOS x86_64 (Rosetta).

Options:
  --cx 25|26         CrossOver release (default: 26)
  --prepare-only     Extract archives from tools/archives/ and exit
  --bootstrap-brew   Install project-local x86_64 Homebrew
  --install-deps     Install build dependencies via .brew-x86
  --configure-only   Run configure without make/install
  --jobs N           Parallel make jobs (default: CPU count)
  --dry-run          Print commands without executing
  -h, --help         Show this help
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
}

if [[ "$BOOTSTRAP_BREW" -eq 1 ]]; then
  bootstrap_brew
fi

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  if [[ ! -x "$HOMEBREW_PREFIX/bin/brew" && "$DRY_RUN" -eq 0 ]]; then
    echo "Missing $HOMEBREW_PREFIX/bin/brew; run with --bootstrap-brew first" >&2
    exit 1
  fi
  run arch -x86_64 "$HOMEBREW_PREFIX/bin/brew" install -y autoconf bison flex pkgconf freetype gettext gnutls zlib bzip2
fi

# Sanitize PATH so configure/make never pick /opt/homebrew (arm64) pkg-config/libs.
BUILD_PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# keg-only formulae ship .pc under opt/*/lib/pkgconfig
PKG_PC_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/zlib/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/bzip2/lib/pkgconfig"

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
run arch -x86_64 env \
  PATH="$BUILD_PATH" \
  BISON="$HOMEBREW_PREFIX/opt/bison/bin/bison" \
  PKG_CONFIG="$HOMEBREW_PREFIX/bin/pkg-config" \
  PKG_CONFIG_PATH="$PKG_PC_PATH" \
  ../configure -C \
    --enable-win64 \
    --enable-archs=i386,x86_64 \
    --with-mingw=llvm-mingw \
    --prefix="$WINE_INSTALL"

if [[ "$CONFIGURE_ONLY" -eq 0 ]]; then
  run arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$PKG_PC_PATH" make -j"$JOBS"
  run arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$PKG_PC_PATH" make install
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ $SCRIPT_DIR/bundle-wine-dylibs.sh"
  else
    "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$WINE_INSTALL"
  fi
fi
