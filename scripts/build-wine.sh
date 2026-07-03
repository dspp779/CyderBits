#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

DRY_RUN=0
BOOTSTRAP_BREW=0
INSTALL_DEPS=0
CONFIGURE_ONLY=0
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
    --jobs)
      JOBS="$2"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

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
  run arch -x86_64 "$HOMEBREW_PREFIX/bin/brew" install autoconf bison flex pkg-config freetype gettext gnutls
fi

run mkdir -p "$OGOM/install" "$WINE_SRC/build64"
# Dry-run only prints mkdir; still create dirs so subsequent cd works.
mkdir -p "$OGOM/install" "$WINE_SRC/build64"

cd "$WINE_SRC"
run ./tools/make_requests
run ./tools/make_specfiles
run ./tools/make_makefiles
run arch -x86_64 env PATH="$HOMEBREW_PREFIX/bin:$PATH" autoreconf -f

cd "$WINE_SRC/build64"
run arch -x86_64 env \
  PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH" \
  BISON="$HOMEBREW_PREFIX/opt/bison/bin/bison" \
  PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig" \
  ../configure -C --enable-win64 --with-mingw=llvm-mingw --prefix="$WINE_INSTALL"

if [[ "$CONFIGURE_ONLY" -eq 0 ]]; then
  run arch -x86_64 env PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH" make -j"$JOBS"
  run arch -x86_64 env PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH" make install
fi
