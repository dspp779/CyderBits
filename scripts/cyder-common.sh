#!/usr/bin/env bash
# Shared paths and helpers for Cyder shell launcher.
set -euo pipefail

CYDER_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_rosetta_sh="$CYDER_COMMON_DIR/cyder-ensure-rosetta.sh"
if [[ -f "$_rosetta_sh" ]]; then
  # shellcheck source=cyder-ensure-rosetta.sh
  source "$_rosetta_sh"
fi
unset _rosetta_sh

cyder_engine_artifacts_dir() {
  local root="${OGOM:-$(cd "$CYDER_COMMON_DIR/.." && pwd)}"
  printf '%s\n' "${CYDER_ENGINE_ARTIFACTS_DIR:-$root/dist/artifacts}"
}

cyder_detect_engine_version() {
  local wine_bin="${1:-}"
  local cx wine_ver
  if [[ -n "${CYDER_ENGINE_VERSION:-}" ]]; then
    printf '%s\n' "$CYDER_ENGINE_VERSION"
    return 0
  fi
  if [[ -z "$wine_bin" && -n "${WINE_INSTALL:-}" ]]; then
    wine_bin="$WINE_INSTALL/bin/wine"
  fi
  [[ -x "$wine_bin" ]] || return 1
  cx="${CYDER_ENGINE_CX_PREFIX:-CX26}"
  wine_ver="$(arch -x86_64 "$wine_bin" --version 2>/dev/null | sed 's/^wine-//')"
  [[ -n "$wine_ver" ]] || return 1
  printf '%s-%s\n' "$cx" "$wine_ver"
}

cyder_engine_archive_basename() {
  local ver="$1"
  printf 'engine-%s.tar.zst\n' "$ver"
}

cyder_engine_archive_basename_xz() {
  local ver="$1"
  printf 'engine-wine-x86_64-%s.tar.xz\n' "$ver"
}

cyder_engine_archive_path() {
  local ver="$1"
  local dir="${2:-$(cyder_engine_artifacts_dir)}"
  printf '%s/%s' "$dir" "$(cyder_engine_archive_basename "$ver")"
}

cyder_engine_archive_path_xz() {
  local ver="$1"
  local dir="${2:-$(cyder_engine_artifacts_dir)}"
  printf '%s/%s' "$dir" "$(cyder_engine_archive_basename_xz "$ver")"
}

cyder_engine_archive_path_for_format() {
  local ver="$1"
  local dir="${2:-$(cyder_engine_artifacts_dir)}"
  local format="${3:-xz}"
  case "$format" in
    zst | zstd) cyder_engine_archive_path "$ver" "$dir" ;;
    xz) cyder_engine_archive_path_xz "$ver" "$dir" ;;
    *)
      echo "Unknown engine archive format: $format" >&2
      return 1
      ;;
  esac
}

cyder_read_engine_version() {
  local resources="$1"
  local ver=""
  [[ -f "$resources/engine-version.txt" ]] || return 1
  ver="$(tr -d '[:space:]' < "$resources/engine-version.txt")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver"
}

cyder_engine_tarball_path() {
  local resources="$1"
  local ver tar legacy
  ver="$(cyder_read_engine_version "$resources")" || return 1
  tar="$resources/$(cyder_engine_archive_basename "$ver")"
  if [[ -f "$tar" ]]; then
    printf '%s\n' "$tar"
    return 0
  fi
  legacy="$resources/$(cyder_engine_archive_basename_xz "$ver")"
  if [[ -f "$legacy" ]]; then
    printf '%s\n' "$legacy"
    return 0
  fi
  return 1
}

cyder_default_engine_src() {
  local here="$1"
  local tar
  if tar="$(cyder_engine_tarball_path "$here" 2>/dev/null)"; then
    printf '%s\n' "$tar"
    return 0
  fi
  if [[ -d "$here/engine-payload" ]]; then
    printf '%s\n' "$here/engine-payload"
    return 0
  fi
  return 1
}

cyder_resources_has_bundled_engine() {
  local here="$1"
  cyder_default_engine_src "$here" >/dev/null 2>&1
}

cyder_bundled_engine_version() {
  local here="$1"
  cyder_read_engine_version "$here" 2>/dev/null || true
}

cyder_resolve_libarchive_src() {
  if [[ -n "${CYDER_LIBARCHIVE_SRC:-}" && -d "$CYDER_LIBARCHIVE_SRC/bin" ]]; then
    printf '%s\n' "$CYDER_LIBARCHIVE_SRC"
    return 0
  fi
  local root="${CYDER_OGOM:-${OGOM:-}}"
  if [[ -n "$root" ]]; then
    if [[ -d "$root/addons/libarchive/bin" ]]; then
      printf '%s\n' "$root/addons/libarchive"
      return 0
    fi
    if [[ -d "$root/tools/libarchive/bin" ]]; then
      printf '%s\n' "$root/tools/libarchive"
      return 0
    fi
  fi
  return 1
}

cyder_init_paths() {
  local here="$1"
  if cyder_resources_has_bundled_engine "$here"; then
    CYDER_OGOM="$here"
    CYDER_SCRIPTS="${CYDER_SCRIPTS:-$here/ogom-scripts}"
    CYDER_ENGINE_SRC="${CYDER_ENGINE_SRC:-$(cyder_default_engine_src "$here")}"
    CYDER_ENTITLEMENTS="${CYDER_ENTITLEMENTS:-$here/entitlements.plist}"
    CYDER_APP="${CYDER_APP:-$(cd "$here/.." && pwd)}"
    if [[ -z "${CYDER_LIBARCHIVE_SRC:-}" ]]; then
      CYDER_LIBARCHIVE_SRC="$(cyder_resolve_libarchive_src 2>/dev/null || true)"
    fi
  else
    CYDER_OGOM="$(cd "$here/.." && pwd)"
    CYDER_SCRIPTS="${CYDER_SCRIPTS:-$CYDER_OGOM/scripts}"
    CYDER_ENGINE_SRC="${CYDER_ENGINE_SRC:-$CYDER_OGOM/install/wine-x86_64}"
    CYDER_ENTITLEMENTS="${CYDER_ENTITLEMENTS:-$CYDER_OGOM/config/entitlements.plist}"
  fi
  CYDER_SUPPORT="${CYDER_SUPPORT:-$HOME/Library/Application Support/Cyder}"
  CYDER_ENGINES="$CYDER_SUPPORT/Engines"
  CYDER_ENGINE_NAME="wine-x86_64"
  CYDER_SHARED_PREFIX="${CYDER_SHARED_PREFIX:-$CYDER_SUPPORT/SharedPrefix}"
  CYDER_BOOTSTRAP_MARKER="$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1"
  CYDER_FONT_MARKER="$CYDER_SHARED_PREFIX/.cyder-font-songti-v1"
  CYDER_DOWNLOADS="$CYDER_SUPPORT/downloads"
  CYDER_BUNDLE_ID="${CYDER_BUNDLE_ID:-local.cyder.app}"
}

cyder_engine_is_installed() {
  [[ -f "$CYDER_ENGINES/$CYDER_ENGINE_NAME/bin/wine" ]]
}

cyder_bootstrap_is_done() {
  [[ -f "$CYDER_BOOTSTRAP_MARKER" ]]
}

cyder_engine_needs_install() {
  local engine_src="$1"
  local dest="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  local marker="$dest/bin/wine"
  local version_marker="$dest/.cyder-engine-version"
  local bundled_version="" installed_version=""

  engine_src="$(cyder_abs_path "$engine_src")"
  if cyder_engine_is_tarball "$engine_src"; then
    bundled_version="$(cyder_engine_version_from_archive "$engine_src")"
  elif [[ -n "${CYDER_OGOM:-}" ]]; then
    bundled_version="$(cyder_bundled_engine_version "$CYDER_OGOM")"
  fi
  if [[ -f "$version_marker" ]]; then
    installed_version="$(tr -d '[:space:]' < "$version_marker")"
  fi
  if [[ ! -f "$marker" ]]; then
    return 0
  fi
  if [[ -n "$bundled_version" && "$installed_version" != "$bundled_version" ]]; then
    return 0
  fi
  return 1
}

cyder_run() {
  echo "+ $*" >&2
  "$@"
}

cyder_abs_path() {
  local p="$1"
  p="${p#file://}"
  p="${p/#\~/$HOME}"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd)
  elif [[ -f "$p" ]]; then
    echo "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  else
    echo "$p"
  fi
}

cyder_choose_exe() {
  local chosen
  if ! chosen="$(osascript -e 'set f to choose file with prompt "選擇 Windows 遊戲執行檔 (.exe)" of type {"com.microsoft.windows-executable", "exe", "public.executable"}
POSIX path of f' 2>/dev/null)"; then
    echo "已取消選檔" >&2
    exit 1
  fi
  printf '%s\n' "$chosen"
}

cyder_resolve_wine_locale() {
  bash "$CYDER_SCRIPTS/resolve-wine-locale.sh"
}

cyder_wine_locale_exports() {
  local loc
  loc="$(cyder_resolve_wine_locale)"
  export LANG="$loc" LC_ALL="$loc"
}

cyder_resolve_exe_from_args() {
  local a p ext
  for a in "$@"; do
    p="$(cyder_abs_path "$a")"
    ext="$(echo "${p##*.}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ext" == "exe" && -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

cyder_wine_bin_for_dry_run() {
  local engine_src="$1"
  local installed="$CYDER_ENGINES/$CYDER_ENGINE_NAME/bin/wine"
  if [[ -f "$installed" ]]; then
    echo "$installed"
  elif [[ -d "$engine_src" ]]; then
    echo "$(cyder_abs_path "$engine_src")/bin/wine"
  else
    echo "$installed"
  fi
}

cyder_engine_is_tarball() {
  local src="$1"
  [[ -f "$src" && ( "$src" == *.tar.xz || "$src" == *.tar.zst ) ]]
}

cyder_engine_version_from_archive() {
  local base="$1"
  base="$(basename "$base")"
  base="${base%.tar.zst}"
  base="${base%.tar.xz}"
  base="${base#engine-}"
  base="${base#wine-x86_64-}"
  printf '%s\n' "$base"
}

cyder_log_engine() {
  local log="$CYDER_SUPPORT/Logs/engine-install.log"
  mkdir -p "$(dirname "$log")"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$log"
}

cyder_remove_path() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  if rm -rf "$path" 2>/dev/null; then
    return 0
  fi
  xattr -cr "$path" 2>/dev/null || true
  chflags -R nouchg "$path" 2>/dev/null || true
  rm -rf "$path"
}

cyder_tarball_has_wine_root() {
  local tarball="$1"
  local first
  first="$(tar -tf "$tarball" 2>/dev/null | head -1 || true)"
  [[ "$first" == wine-x86_64/* || "$first" == wine-x86_64 ]]
}

cyder_find_zstd() {
  local candidate
  for candidate in "$(command -v zstd 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

cyder_tar_extract() {
  local tarball="$1"
  local dest_dir="$2"
  local err_file rc zstd_bin
  err_file="$(mktemp "${TMPDIR:-/tmp}/cyder-tar-err.XXXXXX")"
  if [[ "$tarball" == *.tar.xz ]]; then
    tar -xJf "$tarball" -C "$dest_dir" 2>"$err_file"
    rc=$?
  elif [[ "$tarball" == *.tar.zst ]] && zstd_bin="$(cyder_find_zstd 2>/dev/null || true)"; then
    cyder_log_engine "extract via zstd pipe: $zstd_bin"
    set +o pipefail
    "$zstd_bin" -d -c "$tarball" 2>"$err_file" | tar -xf - -C "$dest_dir" 2>>"$err_file"
    rc=${PIPESTATUS[1]}
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      rc=${PIPESTATUS[0]}
    fi
    set -o pipefail
  else
    tar -xf "$tarball" -C "$dest_dir" 2>"$err_file"
    rc=$?
  fi
  if [[ $rc -ne 0 && -s "$err_file" ]]; then
    cyder_log_engine "tar exit=$rc: $(tr '\n' '; ' <"$err_file")"
  fi
  rm -f "$err_file"
  return "$rc"
}

cyder_install_engine_from_tarball() {
  local tarball="$1"
  local dest="$2"
  local staging extracted_root archive_path read_path
  staging="$(mktemp -d "${TMPDIR:-/tmp}/cyder-engine-staging.XXXXXX")"
  cyder_log_engine "extract start tarball=$tarball dest=$dest staging=$staging"

  read_path="$tarball"
  if [[ "$tarball" == *.tar.zst ]]; then
    archive_path="$staging/archive.tar.zst"
  else
    archive_path="$staging/archive.tar.xz"
  fi

  try_extract() {
    local src="$1"
    if [[ "$tarball" == *.tar.xz ]]; then
      mkdir -p "$staging/tree"
      cyder_tar_extract "$src" "$staging/tree"
    else
      cyder_tar_extract "$src" "$staging"
    fi
  }

  if ! try_extract "$read_path"; then
    cyder_log_engine "direct extract failed; copying archive to $archive_path"
    find "$staging" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    if ! cp -f "$tarball" "$archive_path"; then
      cyder_log_engine "cp archive failed"
      cyder_remove_path "$staging"
      return 1
    fi
    xattr -cr "$archive_path" 2>/dev/null || true
    read_path="$archive_path"
    if ! try_extract "$read_path"; then
      cyder_log_engine "extract failed after archive copy"
      cyder_remove_path "$staging"
      return 1
    fi
  fi

  if [[ "$tarball" == *.tar.xz ]]; then
    if [[ -d "$staging/tree/wine-x86_64" ]]; then
      extracted_root="$staging/tree/wine-x86_64"
    else
      extracted_root="$staging/tree"
    fi
  elif [[ -d "$staging/wine-x86_64" ]]; then
    extracted_root="$staging/wine-x86_64"
  else
    extracted_root="$staging"
  fi

  if [[ ! -x "$extracted_root/bin/wine" ]]; then
    cyder_log_engine "extract failed: missing $extracted_root/bin/wine"
    cyder_remove_path "$staging"
    echo "Engine extract failed: missing $extracted_root/bin/wine" >&2
    return 1
  fi

  mkdir -p "$(dirname "$dest")"
  if [[ -d "$dest" ]]; then
    if ! cyder_remove_path "$dest"; then
      cyder_log_engine "remove failed: $dest"
      cyder_remove_path "$staging"
      echo "Engine install failed: cannot replace $dest (see engine-install.log)" >&2
      return 1
    fi
  fi

  if ! mv "$extracted_root" "$dest"; then
    cyder_log_engine "mv failed: $extracted_root -> $dest"
    cyder_remove_path "$staging"
    echo "Engine install failed: cannot move into $dest" >&2
    return 1
  fi
  rmdir "$staging" 2>/dev/null || cyder_remove_path "$staging"
  cyder_log_engine "extract ok dest=$dest"
}

cyder_install_engine_from_dir() {
  local engine_src="$1"
  local dest="$2"
  local bundled="$engine_src/lib/wine/x86_64-unix/libfreetype.6.dylib"
  if [[ ! -f "$bundled" || -L "$bundled" ]]; then
    local bundle_sh="$CYDER_SCRIPTS/bundle-wine-dylibs.sh"
    if [[ -f "$bundle_sh" ]]; then
      cyder_run bash "$bundle_sh" "$engine_src"
    fi
  fi
  rm -rf "$dest"
  mkdir -p "$dest"
  cyder_run rsync -a "$engine_src/" "$dest/"
}

cyder_sign_installed_engine() {
  local dest="$1"
  local sign_sh="$CYDER_SCRIPTS/sign-wine.sh"
  local env_sh="$CYDER_SCRIPTS/env-x86_64.sh"
  [[ -f "$sign_sh" ]] || return 0
  if [[ -f "$env_sh" ]]; then
    cyder_run bash -c "source \"$env_sh\" && WINE_INSTALL=\"$dest\" ENTITLEMENTS_PLIST=\"$CYDER_ENTITLEMENTS\" bash \"$sign_sh\" --root \"$dest\""
  else
    cyder_run bash "$sign_sh" --root "$dest" --entitlements "$CYDER_ENTITLEMENTS"
  fi
}

cyder_ensure_shared_engine() {
  local engine_src="$1"
  local dest="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  local marker="$dest/bin/wine"
  local version_marker="$dest/.cyder-engine-version"
  local bundled_version="" installed_version=""
  engine_src="$(cyder_abs_path "$engine_src")"

  if cyder_engine_is_tarball "$engine_src"; then
    bundled_version="$(cyder_engine_version_from_archive "$engine_src")"
  elif [[ -n "${CYDER_OGOM:-}" ]]; then
    bundled_version="$(cyder_bundled_engine_version "$CYDER_OGOM")"
  fi
  if [[ -f "$version_marker" ]]; then
    installed_version="$(tr -d '[:space:]' < "$version_marker")"
  fi

  if [[ -f "$marker" ]]; then
    if [[ -z "$bundled_version" || "$installed_version" == "$bundled_version" ]]; then
      echo "Shared engine present: $dest" >&2
      echo "$dest"
      return 0
    fi
    echo "Upgrading shared engine ($installed_version -> $bundled_version) -> $dest" >&2
  else
    echo "Installing shared engine -> $dest" >&2
  fi

  mkdir -p "$CYDER_ENGINES"
  if cyder_engine_is_tarball "$engine_src"; then
    cyder_install_engine_from_tarball "$engine_src" "$dest" || exit 1
  elif [[ -d "$engine_src" ]]; then
    cyder_install_engine_from_dir "$engine_src" "$dest"
  else
    echo "Missing engine source: $engine_src" >&2
    exit 1
  fi
  if [[ -n "$bundled_version" ]]; then
    printf '%s\n' "$bundled_version" >"$version_marker"
  fi
  cyder_sign_installed_engine "$dest"
  echo "$dest"
}

cyder_init_bottle() {
  local wine_bin="$1"
  local bottle="$2"
  local wineserver="${wine_bin%/wine}/wineserver"
  if [[ -f "$bottle/system.reg" ]]; then
    echo "Bottle exists: $bottle" >&2
    return 0
  fi
  echo "Creating bottle: $bottle" >&2
  mkdir -p "$bottle"
  (
    cyder_wine_locale_exports
    export WINEPREFIX="$bottle" WINEDLLOVERRIDES="mshtml=" WINESERVER="$wineserver"
    cyder_run arch -x86_64 "$wine_bin" wineboot -u
  )
  local dos="$bottle/dosdevices"
  mkdir -p "$dos"
  rm -f "$dos/c:" "$dos/z:"
  ln -sf ../drive_c "$dos/c:"
  ln -sf / "$dos/z:"
  (
    cyder_wine_locale_exports
    export WINEPREFIX="$bottle" WINESERVER="$wineserver"
    arch -x86_64 "$wineserver" -k 2>/dev/null || true
  )
}

cyder_ensure_shared_prefix() {
  local wine_bin="$1"
  cyder_init_bottle "$wine_bin" "$CYDER_SHARED_PREFIX"
}

cyder_ensure_font_replacements() {
  local wine_bin="${1:-}"
  local engine_root="${2:-}"
  local font_sh="$CYDER_SCRIPTS/install-cyder-font-replacements.sh"

  [[ -f "$CYDER_FONT_MARKER" ]] && return 0
  [[ -f "$font_sh" ]] || return 0

  if [[ -z "$wine_bin" ]]; then
    wine_bin="$CYDER_ENGINES/$CYDER_ENGINE_NAME/bin/wine"
  fi
  [[ -x "$wine_bin" ]] || return 0

  if [[ -z "$engine_root" ]]; then
    engine_root="$(cd "$(dirname "$wine_bin")/.." && pwd)"
  fi

  echo "Applying Songti TC font replacements..." >&2
  WINEPREFIX="$CYDER_SHARED_PREFIX" WINE_INSTALL="$engine_root" bash "$font_sh"
  printf 'ok\n' >"$CYDER_FONT_MARKER"
}

cyder_bootstrap_shared_prefix() {
  local wine_bin="$1"
  local engine_root="$2"
  cyder_ensure_shared_prefix "$wine_bin"
  cyder_ensure_font_replacements "$wine_bin" "$engine_root"
  if [[ -f "$CYDER_BOOTSTRAP_MARKER" ]]; then
    return 0
  fi
  local mono_sh="$CYDER_SCRIPTS/install-wine-mono.sh"
  if [[ -f "$mono_sh" ]]; then
    (
      export WINEPREFIX="$CYDER_SHARED_PREFIX"
      export WINE_INSTALL="$engine_root"
      export CYDER_DOWNLOADS="$CYDER_DOWNLOADS"
      bash "$mono_sh"
    )
  fi
  local tar_sh="$CYDER_SCRIPTS/install-libarchive-tar.sh"
  if [[ -f "$tar_sh" ]]; then
    (
      export WINEPREFIX="$CYDER_SHARED_PREFIX"
      export WINE_INSTALL="$engine_root"
      export OGOM="${CYDER_OGOM:-${OGOM:-}}"
      export CYDER_LIBARCHIVE_SRC="${CYDER_LIBARCHIVE_SRC:-$(cyder_resolve_libarchive_src)}"
      bash "$tar_sh" --prefix "$CYDER_SHARED_PREFIX"
    )
  fi
  local hires_sh="$CYDER_SCRIPTS/enable-mac-retina-hires.sh"
  if [[ -f "$hires_sh" ]]; then
    WINEPREFIX="$CYDER_SHARED_PREFIX" WINE_INSTALL="$engine_root" bash "$hires_sh"
  fi
  printf 'ok\n' >"$CYDER_BOOTSTRAP_MARKER"
}

cyder_run_wine_exe() {
  local wine_bin="$1"
  local exe="$2"
  local wineserver="${wine_bin%/wine}/wineserver"
  local engine_root
  engine_root="$(cd "$(dirname "$wine_bin")/.." && pwd)"
  cyder_ensure_font_replacements "$wine_bin" "$engine_root"
  cyder_wine_locale_exports
  local log_dir="$CYDER_SUPPORT/Logs"
  mkdir -p "$log_dir"
  local log_file="$log_dir/last-launch.log"
  {
    echo "cmd=arch -x86_64 $wine_bin $exe"
    echo "WINEPREFIX=$CYDER_SHARED_PREFIX"
    echo "cwd=$(dirname "$exe")"
    echo
  } >"$log_file"
  (
    export WINEPREFIX="$CYDER_SHARED_PREFIX" WINESERVER="$wineserver"
    export WINEMSYNC=1 WINEDLLOVERRIDES="mshtml="
    export PATH="${wine_bin%/wine}:$PATH"
    cd "$(dirname "$exe")"
    nohup arch -x86_64 "$wine_bin" "$exe" >>"$log_file" 2>&1 &
  )
}

cyder_bootstrap_error_dialog() {
  local log="$CYDER_SUPPORT/Logs/bootstrap-error.log"
  mkdir -p "$(dirname "$log")"
  echo "$1" >"$log"
  osascript -e 'display alert "Cyder 初始化失敗" message "請查看 ~/Library/Application Support/Cyder/Logs/bootstrap-error.log" as warning' 2>/dev/null || true
}
