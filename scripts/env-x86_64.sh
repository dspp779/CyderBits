#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow Cyder.app to pre-set OGOM / WINE_INSTALL / ENTITLEMENTS_PLIST.
if [[ -z "${OGOM:-}" ]]; then
  export OGOM="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

export CX_VERSION="${CX_VERSION:-26}"
# Project-local x86_64 Homebrew. Ignore shell profile HOMEBREW_PREFIX=/opt/homebrew
# (arm64); Rosetta brew cannot install into that prefix.
if [[ -z "${HOMEBREW_PREFIX:-}" || "$HOMEBREW_PREFIX" == "/opt/homebrew" ]]; then
  export HOMEBREW_PREFIX="$OGOM/.brew-x86"
fi
export HOMEBREW_REPOSITORY="${HOMEBREW_REPOSITORY:-$HOMEBREW_PREFIX}"
export HOMEBREW_CELLAR="${HOMEBREW_CELLAR:-$HOMEBREW_PREFIX/Cellar}"
export BUILD_DIR="${OGOM_BUILD_DIR:-$OGOM/build}"
export LLVM_MINGW_NAME="llvm-mingw-20260616-ucrt-macos-universal"

case "$CX_VERSION" in
  25)
    export CYDER_ENGINE_CX_PREFIX="${CYDER_ENGINE_CX_PREFIX:-CX25}"
    export WINE_SRC="${WINE_SRC:-$BUILD_DIR/cx25/sources/wine}"
    export WINE_INSTALL="${WINE_INSTALL:-$OGOM/install/wine-cx25-x86_64}"
    ;;
  26)
    export CYDER_ENGINE_CX_PREFIX="${CYDER_ENGINE_CX_PREFIX:-CX26}"
    export WINE_SRC="${WINE_SRC:-$BUILD_DIR/cx26/sources/wine}"
    export WINE_INSTALL="${WINE_INSTALL:-$OGOM/install/wine-cx26-x86_64}"
    ;;
  *)
    echo "Unknown CX_VERSION: $CX_VERSION (expected 25 or 26)" >&2
    exit 1
    ;;
esac

if [[ -z "${LLVM_MINGW:-}" ]]; then
  for _candidate in \
    "$BUILD_DIR/$LLVM_MINGW_NAME" \
    "$OGOM/$LLVM_MINGW_NAME"; do
    if [[ -d "$_candidate/bin" ]]; then
      LLVM_MINGW="$_candidate"
      break
    fi
  done
  LLVM_MINGW="${LLVM_MINGW:-$BUILD_DIR/$LLVM_MINGW_NAME}"
fi
export LLVM_MINGW

export GRAPHICS_INSTALL="${GRAPHICS_INSTALL:-$OGOM/install/graphics-cx${CX_VERSION}-x86_64}"
export MEDIA_INSTALL="${MEDIA_INSTALL:-$OGOM/install/media-cx${CX_VERSION}-x86_64}"
export MOLTENVK_SRC="${MOLTENVK_SRC:-$BUILD_DIR/cx${CX_VERSION}/sources/moltenvk}"
export VKD3D_SRC="${VKD3D_SRC:-$BUILD_DIR/cx${CX_VERSION}/sources/vkd3d}"

export BLUECG_PREFIX="${BLUECG_PREFIX:-$OGOM/BlueCrossgateNew}"
export ENTITLEMENTS_PLIST="${ENTITLEMENTS_PLIST:-$OGOM/config/entitlements.plist}"
export CYDER_CROSSOVER_VERSION="${CYDER_CROSSOVER_VERSION:-26.3.0}"
# Product floor for the current CX26 Cyder engine is 10.15: Wine itself
# (bin/wine, ntdll.so, …) and libMoltenVK.dylib are built with this target.
# Disabling MoltenVK at runtime does not unlock older macOS for this artifact;
# a lower floor would require rebuilding Wine with a lower
# MACOSX_DEPLOYMENT_TARGET (configure historically mentions ~10.7). Apple
# Silicon still needs macOS 11+ for Rosetta 2.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"
export ARCH_CMD="arch -x86_64"

export PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:$PATH"
export PKG_CONFIG="$HOMEBREW_PREFIX/bin/pkg-config"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/zlib/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/bzip2/lib/pkgconfig"
unset PKG_CONFIG_LIBDIR

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_ASK=1
export NONINTERACTIVE=1
export CI=1

if [[ -d "$HOMEBREW_PREFIX" ]]; then
  export HOMEBREW_CACHE="$HOMEBREW_PREFIX/cache"
  export HOMEBREW_LOGS="$HOMEBREW_PREFIX/logs"
  export HOMEBREW_TEMP="$HOMEBREW_PREFIX/tmp"
  mkdir -p "$HOMEBREW_CACHE" "$HOMEBREW_LOGS" "$HOMEBREW_TEMP"

  _brew_lib_path="$HOMEBREW_PREFIX/lib"
  for _d in "$HOMEBREW_PREFIX"/opt/*/lib; do
    [[ -d "$_d" ]] || continue
    _brew_lib_path="$_brew_lib_path:$_d"
  done
  export DYLD_FALLBACK_LIBRARY_PATH="${_brew_lib_path}${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
  export DYLD_LIBRARY_PATH="${_brew_lib_path}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  unset _d _brew_lib_path _candidate
fi

# Run Homebrew under Rosetta with an isolated prefix (never /opt/homebrew).
brew_x86() {
  arch -x86_64 env \
    HOMEBREW_PREFIX="$HOMEBREW_PREFIX" \
    HOMEBREW_REPOSITORY="$HOMEBREW_REPOSITORY" \
    HOMEBREW_CELLAR="$HOMEBREW_CELLAR" \
    HOMEBREW_CACHE="${HOMEBREW_CACHE:-$HOMEBREW_PREFIX/cache}" \
    HOMEBREW_LOGS="${HOMEBREW_LOGS:-$HOMEBREW_PREFIX/logs}" \
    HOMEBREW_TEMP="${HOMEBREW_TEMP:-$HOMEBREW_PREFIX/tmp}" \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_ENV_HINTS=1 \
    HOMEBREW_NO_ASK=1 \
    NONINTERACTIVE=1 \
    CI=1 \
    PATH="$HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$HOMEBREW_PREFIX/bin/brew" "$@"
}

# Vendored tap: homebrew/ogom-local → .brew-x86/.../ogom/homebrew-local (ogom/local).
# gnutls drops homebrew-core's "older clang" GitLab .diff (HTTP 403 on fetch).
brew_x86_ensure_local_tap() {
  local src="$OGOM/homebrew/ogom-local"
  local dest="$HOMEBREW_PREFIX/Library/Taps/ogom/homebrew-local"
  [[ -f "$src/Formula/gnutls.rb" ]] || {
    echo "brew_x86_ensure_local_tap: missing $src/Formula/gnutls.rb" >&2
    return 1
  }
  mkdir -p "$dest/Formula"
  # Keep tap contents identical to the repo copy (no network `brew tap`).
  rsync -a --delete \
    --exclude '.git' \
    "$src/" "$dest/"
}

# Map short names to the vendored tap when installing runtime formulae.
brew_x86_runtime_formula() {
  case "$1" in
    gnutls | ogom/local/gnutls) printf '%s\n' "ogom/local/gnutls" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Cellar / opt leaf name for minos checks (strip tap prefix).
brew_x86_runtime_formula_leaf() {
  local f="$1"
  printf '%s\n' "${f##*/}"
}

# Homebrew bottles target macOS 14+ and stdenv injects the host
# -mmacosx-version-min. Runtime dylibs bundled into the Wine engine must stay
# at the product floor (MACOSX_DEPLOYMENT_TARGET, default 10.15).
#
# Trick: HOMEBREW_CC=llvm_clang makes the superenv shim invoke
# $HOMEBREW_PREFIX/opt/llvm/bin/clang{,++}. We stage thin wrappers there that
# strip any higher -mmacosx-version-min and force the product floor. Build-only
# formulae (autoconf, bison, meson, …) can keep using bottles via brew_x86.
#
# Set OGOM_BREW_RUNTIME_FORCE=1 to rebuild even when cellar dylibs already
# report minos ≤ the product floor.
brew_x86_install_runtime() {
  local target="${MACOSX_DEPLOYMENT_TARGET:-10.15}"
  local wrap_bin="$HOMEBREW_PREFIX/opt/llvm/bin"
  local marker="# ogom-macos-deployment-wrapper target=${target}"
  local name real formula leaf
  local -a formulae=()
  local -a ordered=()
  local -a missing=()
  local -a reinstall=()
  local -a skip=()
  local -a install_names=()
  local need_local_tap=0

  [[ $# -gt 0 ]] || {
    echo "brew_x86_install_runtime: no formulae given" >&2
    return 1
  }

  for formula in "$@"; do
    case "$formula" in
      gnutls | ogom/local/gnutls) need_local_tap=1 ;;
    esac
  done
  if [[ "$need_local_tap" -eq 1 ]]; then
    brew_x86_ensure_local_tap
  fi

  _ogom_version_gt() {
    local a="$1" b="$2"
    local IFS=.
    local -a aa ba
    read -r -a aa <<<"$a"
    read -r -a ba <<<"$b"
    local i av bv
    for i in 0 1 2; do
      av="${aa[i]:-0}"
      bv="${ba[i]:-0}"
      if ((10#$av > 10#$bv)); then return 0; fi
      if ((10#$av < 10#$bv)); then return 1; fi
    done
    return 1
  }

  _ogom_formula_needs_rebuild() {
    local f leaf lib minos
    f="$1"
    leaf="$(brew_x86_runtime_formula_leaf "$f")"
    local libdir="$HOMEBREW_PREFIX/opt/$leaf/lib"
    [[ "${OGOM_BREW_RUNTIME_FORCE:-0}" == "1" ]] && return 0
    [[ -d "$libdir" ]] || return 0
    local found=0
    for lib in "$libdir"/*.dylib; do
      [[ -f "$lib" ]] || continue
      # Prefer ABI-versioned dylibs (libfoo.N.dylib / libfoo.N.M.dylib).
      case "$(basename "$lib")" in
        *.[0-9]*.dylib) ;;
        *) continue ;;
      esac
      found=1
      minos="$(otool -l "$lib" 2>/dev/null | awk '/minos/{print $2; exit}')"
      [[ -n "$minos" ]] || return 0
      if _ogom_version_gt "$minos" "$target"; then
        return 0
      fi
    done
    # No versioned dylibs (e.g. ca-certificates) — treat as OK if installed.
    [[ "$found" -eq 1 ]] && return 1
    return 1
  }

  install_names=()
  for formula in "$@"; do
    install_names+=("$(brew_x86_runtime_formula "$formula")")
  done

  # Expand to a topological install order, including runtime deps that end up
  # in the Wine unix lib tree (gnutls → nettle/gmp/…, freetype → libpng, …).
  while IFS= read -r formula; do
    [[ -n "$formula" ]] || continue
    ordered+=("$(brew_x86_runtime_formula "$formula")")
  done < <(brew_x86 deps --union --topological "${install_names[@]}" 2>/dev/null || true)
  for formula in "${install_names[@]}"; do
    ordered+=("$formula")
  done
  # De-dupe while preserving order (leaf name: prefer ogom/local/gnutls over gnutls).
  formulae=()
  for formula in "${ordered[@]}"; do
    leaf="$(brew_x86_runtime_formula_leaf "$formula")"
    local seen=0
    local existing existing_leaf
    for existing in "${formulae[@]+"${formulae[@]}"}"; do
      existing_leaf="$(brew_x86_runtime_formula_leaf "$existing")"
      if [[ "$existing_leaf" == "$leaf" ]]; then
        seen=1
        break
      fi
    done
    [[ "$seen" -eq 0 ]] && formulae+=("$formula")
  done

  mkdir -p "$wrap_bin"
  for name in clang clang++; do
    case "$name" in
      clang++) real=/usr/bin/clang++ ;;
      *) real=/usr/bin/clang ;;
    esac
    # Preserve a non-wrapper binary if a real llvm keg is present.
    if [[ -e "$wrap_bin/$name" ]] && ! grep -q "ogom-macos-deployment-wrapper" "$wrap_bin/$name" 2>/dev/null; then
      if [[ ! -e "$wrap_bin/$name.ogom-bak" ]]; then
        mv "$wrap_bin/$name" "$wrap_bin/$name.ogom-bak"
      fi
    fi
    cat > "$wrap_bin/$name" <<EOF
#!/bin/bash
${marker}
set -euo pipefail
TARGET=${target}
args=()
for a in "\$@"; do
  case "\$a" in
    -mmacosx-version-min=*) continue ;;
    -Wl,-macosx_version_min,*) continue ;;
  esac
  args+=("\$a")
done
export MACOSX_DEPLOYMENT_TARGET="\$TARGET"
exec ${real} -arch x86_64 -mmacosx-version-min="\$TARGET" "\${args[@]}"
EOF
    chmod +x "$wrap_bin/$name"
  done

  # Bottled automake for /usr/local hardcodes aclocal search paths; rewrite
  # them for the project prefix so gmp/gnutls autoreconf works.
  if [[ -x "$HOMEBREW_PREFIX/opt/automake/bin/aclocal" ]]; then
    local am_cellar
    am_cellar="$(cd "$HOMEBREW_PREFIX/opt/automake" && pwd -P)"
    for am_tool in "$am_cellar"/bin/aclocal "$am_cellar"/bin/automake; do
      [[ -f "$am_tool" ]] || continue
      if grep -q '/usr/local/share/aclocal' "$am_tool" 2>/dev/null; then
        sed -i.bak "s|/usr/local/share/aclocal|${HOMEBREW_PREFIX}/share/aclocal|g" "$am_tool"
      fi
    done
    mkdir -p "$HOMEBREW_PREFIX/share"
    if [[ -d "$HOMEBREW_PREFIX/opt/automake/share/aclocal-1.18" ]]; then
      ln -sfn "$HOMEBREW_PREFIX/opt/automake/share/aclocal-1.18" \
        "$HOMEBREW_PREFIX/share/aclocal-1.18"
    fi
  fi

  for formula in "${formulae[@]}"; do
    if brew_x86 list --versions "$formula" >/dev/null 2>&1; then
      if _ogom_formula_needs_rebuild "$formula"; then
        reinstall+=("$formula")
      else
        skip+=("$formula")
      fi
    else
      missing+=("$formula")
    fi
  done

  if [[ ${#skip[@]} -gt 0 ]]; then
    echo "brew_x86_install_runtime: already ≤${target}, skip: ${skip[*]}"
  fi

  local brew_runtime=(
    arch -x86_64 env
    HOMEBREW_PREFIX="$HOMEBREW_PREFIX"
    HOMEBREW_REPOSITORY="$HOMEBREW_REPOSITORY"
    HOMEBREW_CELLAR="$HOMEBREW_CELLAR"
    HOMEBREW_CACHE="${HOMEBREW_CACHE:-$HOMEBREW_PREFIX/cache}"
    HOMEBREW_LOGS="${HOMEBREW_LOGS:-$HOMEBREW_PREFIX/logs}"
    HOMEBREW_TEMP="${HOMEBREW_TEMP:-$HOMEBREW_PREFIX/tmp}"
    HOMEBREW_NO_AUTO_UPDATE=1
    HOMEBREW_NO_ANALYTICS=1
    HOMEBREW_NO_ENV_HINTS=1
    HOMEBREW_NO_ASK=1
    NONINTERACTIVE=1
    CI=1
    MACOSX_DEPLOYMENT_TARGET="$target"
    HOMEBREW_CC=llvm_clang
    PATH="$HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "$HOMEBREW_PREFIX/bin/brew"
  )

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "brew_x86_install_runtime: install from source (${target}): ${missing[*]}"
    "${brew_runtime[@]}" install --build-from-source "${missing[@]}"
  fi
  if [[ ${#reinstall[@]} -gt 0 ]]; then
    echo "brew_x86_install_runtime: reinstall from source (${target}): ${reinstall[*]}"
    # Reinstall one-by-one so a single patch/download failure cannot abort the
    # whole runtime set; callers can retry the failed leaf.
    local status=0
    for formula in "${reinstall[@]}"; do
      if ! "${brew_runtime[@]}" reinstall --build-from-source "$formula"; then
        echo "brew_x86_install_runtime: FAILED $formula" >&2
        status=1
      fi
    done
    return "$status"
  fi
  return 0
}
