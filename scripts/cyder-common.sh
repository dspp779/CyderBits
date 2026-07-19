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

cyder_crossover_version() {
  printf '%s\n' "${CYDER_CROSSOVER_VERSION:-26.2.0}"
}

cyder_engine_version_label_trim() {
  local ver="$1"
  ver="${ver//$'\r'/}"
  ver="${ver#"${ver%%[![:space:]]*}"}"
  ver="${ver%"${ver##*[![:space:]]}"}"
  printf '%s\n' "$ver"
}

cyder_format_engine_version_from_wine() {
  local wine_bin="${1:-}"
  local wine_raw wine_ver cx_ver
  if [[ -n "${CYDER_ENGINE_VERSION_LABEL:-}" ]]; then
    cyder_engine_version_label_trim "$CYDER_ENGINE_VERSION_LABEL"
    return 0
  fi
  if [[ -z "$wine_bin" && -n "${WINE_INSTALL:-}" ]]; then
    wine_bin="$WINE_INSTALL/bin/wine"
  fi
  [[ -x "$wine_bin" ]] || return 1
  wine_raw="$(arch -x86_64 "$wine_bin" --version 2>/dev/null || true)"
  wine_ver="${wine_raw#wine-}"
  if [[ "$wine_ver" == *[Ss]ikarugir* ]]; then
    wine_ver="${wine_ver%% (Sikarugir)*}"
    wine_ver="${wine_ver%% (sikarugir)*}"
    printf 'wine sikarugir %s\n' "$wine_ver"
    return 0
  fi
  cx_ver="$(cyder_crossover_version)"
  printf 'wine crossover %s (wine %s)\n' "$cx_ver" "$wine_ver"
}

cyder_engine_version_slug_from_label() {
  local label="$1"
  local slug cx wine_ver tail
  label="$(cyder_engine_version_label_trim "$label")"
  if [[ "$label" == wine\ crossover\ * ]]; then
    cx="${label#wine crossover }"
    cx="${cx%% (wine *)}"
    wine_ver="${label#* (wine }"
    wine_ver="${wine_ver%)}"
    slug="crossover-${cx}-wine-${wine_ver}"
    slug="${slug// /-}"
    printf '%s\n' "$slug"
    return 0
  fi
  if [[ "$label" == wine\ sikarugir\ * || "$label" == wine\ Sikarugir\ * ]]; then
    tail="${label#wine sikarugir }"
    if [[ "$tail" == "$label" ]]; then
      tail="${label#wine Sikarugir }"
    fi
    slug="sikarugir-${tail}"
    slug="$(printf '%s' "$slug" | tr ' .()/' '-' | tr -s '-')"
    slug="${slug#-}"
    slug="${slug%-}"
    printf '%s\n' "$slug"
    return 0
  fi
  slug="$(printf '%s' "$label" | tr ' .()/' '-' | tr -s '-')"
  slug="${slug#-}"
  slug="${slug%-}"
  printf '%s\n' "$slug"
}

cyder_read_engine_version_file() {
  local engine_root="$1"
  local f="$engine_root/version"
  local ver=""
  [[ -f "$f" ]] || return 1
  ver="$(cyder_engine_version_label_trim "$(cat "$f")")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver"
}

cyder_write_engine_version_file() {
  local engine_root="$1"
  local ver="$2"
  ver="$(cyder_engine_version_label_trim "$ver")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver" >"$engine_root/version"
}

cyder_read_installed_engine_version() {
  local engine_root="$1"
  local ver=""
  if ver="$(cyder_read_engine_version_file "$engine_root" 2>/dev/null)"; then
    printf '%s\n' "$ver"
    return 0
  fi
  if [[ -f "$engine_root/.cyder-engine-version" ]]; then
    ver="$(cyder_engine_version_label_trim "$(cat "$engine_root/.cyder-engine-version")")"
    [[ -n "$ver" ]] || return 1
    printf '%s\n' "$ver"
    return 0
  fi
  return 1
}

cyder_engine_version_from_tarball() {
  local tarball="$1"
  local ver=""
  ver="$(tar -xOf "$tarball" wine-x86_64/version 2>/dev/null | head -1 || true)"
  ver="$(cyder_engine_version_label_trim "$ver")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver"
  return 0
}

cyder_bundled_engine_version_from_src() {
  local engine_src="$1"
  engine_src="$(cyder_abs_path "$engine_src")"
  if cyder_engine_is_tarball "$engine_src"; then
    if cyder_engine_version_from_tarball "$engine_src"; then
      return 0
    fi
    cyder_engine_version_from_archive "$engine_src"
    return 0
  fi
  if [[ -d "$engine_src" ]]; then
    if cyder_read_engine_version_file "$engine_src"; then
      return 0
    fi
    if [[ -x "$engine_src/bin/wine" ]]; then
      cyder_format_engine_version_from_wine "$engine_src/bin/wine"
      return 0
    fi
  fi
  if [[ -n "${CYDER_OGOM:-}" ]]; then
    cyder_bundled_engine_version "$CYDER_OGOM"
    return 0
  fi
  return 1
}

cyder_detect_engine_version() {
  local wine_bin="${1:-}"
  local label
  if [[ -n "${CYDER_ENGINE_VERSION:-}" ]]; then
    printf '%s\n' "$CYDER_ENGINE_VERSION"
    return 0
  fi
  label="$(cyder_format_engine_version_from_wine "$wine_bin")" || return 1
  cyder_engine_version_slug_from_label "$label"
}

cyder_detect_engine_version_label() {
  cyder_format_engine_version_from_wine "${1:-}"
}

cyder_reset_shared_prefix() {
  [[ -e "$CYDER_SHARED_PREFIX" ]] || return 0
  echo "Resetting shared bottle (engine version changed): $CYDER_SHARED_PREFIX" >&2
  cyder_remove_path "$CYDER_SHARED_PREFIX"
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
  ver="$(cyder_engine_version_label_trim "$(cat "$resources/engine-version.txt")")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver"
}

cyder_engine_tarball_path() {
  local resources="$1"
  local ver tar legacy archive_name
  if [[ -f "$resources/engine-archive.txt" ]]; then
    archive_name="$(tr -d '[:space:]' < "$resources/engine-archive.txt")"
    if [[ -n "$archive_name" && -f "$resources/$archive_name" ]]; then
      printf '%s\n' "$resources/$archive_name"
      return 0
    fi
  fi
  ver="$(cyder_read_engine_version "$resources")" || return 1
  tar="$resources/$(cyder_engine_archive_basename "$(cyder_engine_version_slug_from_label "$ver")")"
  if [[ -f "$tar" ]]; then
    printf '%s\n' "$tar"
    return 0
  fi
  legacy="$resources/$(cyder_engine_archive_basename_xz "$(cyder_engine_version_slug_from_label "$ver")")"
  if [[ -f "$legacy" ]]; then
    printf '%s\n' "$legacy"
    return 0
  fi
  # Legacy layouts keyed by old slug-style engine-version.txt
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
    CYDER_ENGINE_SRC="${CYDER_ENGINE_SRC:-$CYDER_OGOM/install/wine-cx26-x86_64}"
    CYDER_ENTITLEMENTS="${CYDER_ENTITLEMENTS:-$CYDER_OGOM/config/entitlements.plist}"
  fi
  CYDER_SUPPORT="${CYDER_SUPPORT:-$HOME/Library/Application Support/Cyder}"
  CYDER_RUNTIME_ROOT="${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}"
  CYDER_ENGINES="${CYDER_ENGINES:-$CYDER_RUNTIME_ROOT/Engines}"
  CYDER_ENGINE_NAME="wine-x86_64"
  CYDER_SHARED_PREFIX="${CYDER_SHARED_PREFIX:-$CYDER_SUPPORT/bottles/shared}"
  CYDER_LEGACY_ENGINES="${CYDER_LEGACY_ENGINES:-$CYDER_SUPPORT/Engines}"
  CYDER_LEGACY_SHARED_PREFIX="${CYDER_LEGACY_SHARED_PREFIX:-$CYDER_SUPPORT/SharedPrefix}"
  CYDER_BOOTSTRAP_MARKER="$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1"
  CYDER_FONT_MARKER="$CYDER_SHARED_PREFIX/.cyder-font-songti-v1"
  CYDER_DOWNLOADS="$CYDER_SUPPORT/downloads"
  CYDER_BUNDLE_ID="${CYDER_BUNDLE_ID:-local.cyder.app}"
  CYDER_TEMPLATE_REVISION="${CYDER_TEMPLATE_REVISION:-2}"
  export CYDER_TEMPLATE_REVISION
}

cyder_validate_runtime_path() {
  if [[ "$CYDER_ENGINES" == *[[:space:]]* ]]; then
    echo "Cyder runtime path must not contain whitespace: $CYDER_ENGINES" >&2
    return 1
  fi
}

cyder_migrate_legacy_layout() {
  CYDER_MIGRATED_ENGINE_VERSION=""
  cyder_validate_runtime_path || return 1

  local legacy_engine="$CYDER_LEGACY_ENGINES/$CYDER_ENGINE_NAME"
  local active_engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  if [[ "$legacy_engine" != "$active_engine" && ( -e "$legacy_engine" || -L "$legacy_engine" ) ]]; then
    if cyder_has_running_prefix "$CYDER_LEGACY_SHARED_PREFIX" || cyder_has_running_prefix "$CYDER_SHARED_PREFIX"; then
      echo "Close all Cyder games before migrating the Wine runtime." >&2
      return 1
    fi
    CYDER_MIGRATED_ENGINE_VERSION="$(cyder_read_installed_engine_version "$legacy_engine" 2>/dev/null || true)"
    echo "Removing legacy engine with unsafe path: $legacy_engine" >&2
    cyder_remove_path "$legacy_engine"
    rmdir "$CYDER_LEGACY_ENGINES" 2>/dev/null || true
  fi

  if [[ "$CYDER_LEGACY_SHARED_PREFIX" != "$CYDER_SHARED_PREFIX" && -e "$CYDER_LEGACY_SHARED_PREFIX" ]]; then
    if cyder_has_running_prefix "$CYDER_LEGACY_SHARED_PREFIX"; then
      echo "Close all Cyder games before migrating the shared bottle." >&2
      return 1
    fi
    if [[ ! -e "$CYDER_SHARED_PREFIX" ]]; then
      mkdir -p "$(dirname "$CYDER_SHARED_PREFIX")"
      echo "Migrating shared bottle -> $CYDER_SHARED_PREFIX" >&2
      mv "$CYDER_LEGACY_SHARED_PREFIX" "$CYDER_SHARED_PREFIX"
    else
      echo "Legacy SharedPrefix retained because bottles/shared already exists." >&2
    fi
  fi
}

cyder_load_saved_settings() {
  local settings="$CYDER_SUPPORT/settings.json"
  # Process-level values are authoritative. Native Cyder uses them for the
  # currently selected game's overrides; reloading the global settings file
  # here used to replace Retina=0/DPI=96 with the global Retina=1/DPI=192.
  local keep_msync=0 keep_esync=0 keep_retina=0 keep_dpi=0
  local keep_font=0 keep_smoothing=0 keep_power=0
  case "${CYDER_MSYNC-}" in 0|1) keep_msync=1 ;; esac
  case "${CYDER_ESYNC-}" in 0|1) keep_esync=1 ;; esac
  case "${CYDER_RETINA_MODE-}" in 0|1) keep_retina=1 ;; esac
  if [[ "${CYDER_DPI-}" =~ ^[0-9]+$ ]] && (( CYDER_DPI >= 72 && CYDER_DPI <= 480 )); then keep_dpi=1; fi
  case "${CYDER_FONT_PRESET-}" in songti|mingliu) keep_font=1 ;; esac
  case "${CYDER_FONT_SMOOTHING-}" in off|grayscale|cleartype-rgb|cleartype-bgr) keep_smoothing=1 ;; esac
  case "${CYDER_POWER_MODE-}" in normal|background) keep_power=1 ;; esac

  export CYDER_MSYNC="${CYDER_MSYNC:-1}"
  export CYDER_ESYNC="${CYDER_ESYNC:-0}"
  export CYDER_RETINA_MODE="${CYDER_RETINA_MODE:-1}"
  export CYDER_DPI="${CYDER_DPI:-192}"
  export CYDER_FONT_PRESET="${CYDER_FONT_PRESET:-songti}"
  export CYDER_FONT_SMOOTHING="${CYDER_FONT_SMOOTHING:-cleartype-rgb}"
  export CYDER_POWER_MODE="${CYDER_POWER_MODE:-normal}"
  [[ -f "$settings" ]] || return 0
  command -v plutil >/dev/null 2>&1 || return 0

  local value
  if [[ "$keep_msync" -eq 0 ]]; then
    value="$(plutil -extract msync raw -o - "$settings" 2>/dev/null || true)"
    case "$value" in true) export CYDER_MSYNC=1 ;; false) export CYDER_MSYNC=0 ;; esac
  fi
  if [[ "$keep_esync" -eq 0 ]]; then
    value="$(plutil -extract esync raw -o - "$settings" 2>/dev/null || true)"
    case "$value" in true) export CYDER_ESYNC=1 ;; false) export CYDER_ESYNC=0 ;; esac
  fi
  if [[ "$keep_retina" -eq 0 ]]; then
    value="$(plutil -extract retinaMode raw -o - "$settings" 2>/dev/null || true)"
    case "$value" in true) export CYDER_RETINA_MODE=1 ;; false) export CYDER_RETINA_MODE=0 ;; esac
  fi
  if [[ "$keep_dpi" -eq 0 ]]; then
    value="$(plutil -extract dpi raw -o - "$settings" 2>/dev/null || true)"
    [[ "$value" =~ ^[0-9]+$ ]] && export CYDER_DPI="$value"
  fi
  if [[ "$keep_font" -eq 0 ]]; then
    value="$(plutil -extract fontPreset raw -o - "$settings" 2>/dev/null || true)"
    [[ "$value" == songti || "$value" == mingliu ]] && export CYDER_FONT_PRESET="$value"
  fi
  if [[ "$keep_smoothing" -eq 0 ]]; then
    value="$(plutil -extract fontSmoothing raw -o - "$settings" 2>/dev/null || true)"
    case "$value" in off|grayscale|cleartype-rgb|cleartype-bgr) export CYDER_FONT_SMOOTHING="$value" ;; esac
  fi
  # Settings UI stores stable, user-facing names and the launcher contract
  # uses taskpolicy's process class. Keep the translation in one place so
  # CLI/Finder launches behave identically.
  if [[ "$keep_power" -eq 0 ]]; then
    value="$(plutil -extract powerMode raw -o - "$settings" 2>/dev/null || true)"
    case "$value" in
      standard) export CYDER_POWER_MODE=normal ;;
      energySaving) export CYDER_POWER_MODE=background ;;
      *) export CYDER_POWER_MODE=normal ;;
    esac
  fi
}

cyder_find_taskpolicy() {
  if [[ -n "${CYDER_TASKPOLICY_BIN:-}" && -x "$CYDER_TASKPOLICY_BIN" ]]; then
    printf '%s\n' "$CYDER_TASKPOLICY_BIN"
    return 0
  fi
  command -v taskpolicy 2>/dev/null || return 1
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
  local bundled_version="" installed_version=""

  engine_src="$(cyder_abs_path "$engine_src")"
  bundled_version="$(cyder_bundled_engine_version_from_src "$engine_src" 2>/dev/null || true)"
  if [[ -f "$marker" ]]; then
    installed_version="$(cyder_read_installed_engine_version "$dest" 2>/dev/null || true)"
  fi
  if [[ ! -f "$marker" ]]; then
    return 0
  fi
  if [[ -n "$bundled_version" && "$installed_version" != "$bundled_version" ]]; then
    return 0
  fi
  return 1
}

# Fast readiness check for direct EXE launches. Do not inspect/decompress the
# bundled archive here; installation and upgrade paths are the only callers
# that need cyder_bundled_engine_version_from_src().
cyder_engine_is_ready_for_launch() {
  local engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  local expected installed
  cyder_validate_runtime_path || return 1
  [[ -x "$engine/bin/wine" && -f "$CYDER_BOOTSTRAP_MARKER" ]] || return 1
  expected="$(cyder_bundled_engine_version "$CYDER_OGOM" 2>/dev/null || true)"
  installed="$(cyder_read_installed_engine_version "$engine" 2>/dev/null || true)"
  [[ -z "$expected" || "$installed" == "$expected" ]]
}

# Resolve the installed engine without opening the bundled archive when the
# app's sidecar version file already proves that the installed copy is current.
# Explicit/non-bundled engine sources still go through the archive-aware path.
cyder_resolve_shared_engine() {
  local engine_src="$1"
  local engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  local bundled_src="" expected="" installed=""
  engine_src="$(cyder_abs_path "$engine_src")"
  bundled_src="$(cyder_default_engine_src "$CYDER_OGOM" 2>/dev/null || true)"
  if [[ -n "$bundled_src" ]]; then
    bundled_src="$(cyder_abs_path "$bundled_src")"
  fi
  if [[ -n "$bundled_src" && "$engine_src" == "$bundled_src" && -x "$engine/bin/wine" ]]; then
    expected="$(cyder_bundled_engine_version "$CYDER_OGOM" 2>/dev/null || true)"
    installed="$(cyder_read_installed_engine_version "$engine" 2>/dev/null || true)"
    if [[ -n "$expected" && "$installed" == "$expected" ]]; then
      cyder_migrate_legacy_layout || return $?
      if [[ ! -f "$engine/.cyder-engine-signed" ]]; then
        cyder_sign_installed_engine "$engine" || return $?
      fi
      echo "Shared engine current (sidecar): $engine" >&2
      printf '%s\n' "$engine"
      return 0
    fi
  fi
  cyder_ensure_shared_engine "$engine_src"
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

cyder_diagnostic_stage() {
  local stage="$1"
  if declare -F cyder_set_stage >/dev/null 2>&1; then
    cyder_set_stage "$stage"
  elif [[ -n "${CYDER_DIAGNOSTIC_SESSION_ID:-}" ]]; then
    export CYDER_DIAGNOSTIC_STAGE="$stage"
    printf 'diagnostic event=stage session=%s stage=%s\n' \
      "$CYDER_DIAGNOSTIC_SESSION_ID" "$stage" >&2
  fi
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
  mkdir -p "$(dirname "$dest")"
  staging="$(mktemp -d "$(dirname "$dest")/.cyder-engine-staging.XXXXXX")"
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
  local staging
  local bundled="$engine_src/lib/wine/x86_64-unix/libfreetype.6.dylib"
  if [[ ! -f "$bundled" || -L "$bundled" ]]; then
    local bundle_sh="$CYDER_SCRIPTS/bundle-wine-dylibs.sh"
    if [[ -f "$bundle_sh" ]]; then
      cyder_run bash "$bundle_sh" "$engine_src"
    fi
  fi
  mkdir -p "$(dirname "$dest")"
  staging="$(mktemp -d "$(dirname "$dest")/.cyder-engine-staging.XXXXXX")"
  cyder_run rsync -a "$engine_src/" "$staging/"
  if ! cyder_read_engine_version_file "$staging" >/dev/null 2>&1; then
    if [[ -x "$staging/bin/wine" ]]; then
      local ver
      ver="$(cyder_format_engine_version_from_wine "$staging/bin/wine" 2>/dev/null || true)"
      [[ -n "$ver" ]] && cyder_write_engine_version_file "$staging" "$ver"
    fi
  fi
  rm -f "$staging/.cyder-engine-version"
  cyder_remove_path "$dest"
  mv "$staging" "$dest"
}

cyder_sign_installed_engine() {
  local dest="$1"
  local sign_sh="$CYDER_SCRIPTS/sign-wine.sh"
  local env_sh="$CYDER_SCRIPTS/env-x86_64.sh"
  [[ -f "$sign_sh" ]] || {
    echo "Wine signing helper is missing: $sign_sh" >&2
    return 1
  }
  if [[ -f "$env_sh" ]]; then
    cyder_run bash -c "source \"$env_sh\" && WINE_INSTALL=\"$dest\" ENTITLEMENTS_PLIST=\"$CYDER_ENTITLEMENTS\" bash \"$sign_sh\" --root \"$dest\""
  else
    cyder_run bash "$sign_sh" --root "$dest" --entitlements "$CYDER_ENTITLEMENTS"
  fi
  printf 'signed\n' >"$dest/.cyder-engine-signed"
}

cyder_ensure_shared_engine() {
  local engine_src="$1"
  local dest="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  local marker="$dest/bin/wine"
  local bundled_version="" installed_version=""
  engine_src="$(cyder_abs_path "$engine_src")"
  cyder_migrate_legacy_layout || exit 1

  bundled_version="$(cyder_bundled_engine_version_from_src "$engine_src" 2>/dev/null || true)"
  if [[ -f "$marker" ]]; then
    installed_version="$(cyder_read_installed_engine_version "$dest" 2>/dev/null || true)"
    if [[ -z "$bundled_version" || "$installed_version" == "$bundled_version" ]]; then
      echo "Shared engine present: $dest" >&2
      if [[ ! -f "$dest/.cyder-engine-signed" ]]; then
        cyder_sign_installed_engine "$dest" || exit 1
      fi
      echo "$dest"
      return 0
    fi
    echo "Upgrading shared engine ($installed_version -> $bundled_version) -> $dest" >&2
    cyder_reset_shared_prefix
  else
    echo "Installing shared engine -> $dest" >&2
    if [[ -n "$bundled_version" && -e "$CYDER_SHARED_PREFIX" &&
          ( -z "$CYDER_MIGRATED_ENGINE_VERSION" ||
            "$CYDER_MIGRATED_ENGINE_VERSION" != "$bundled_version" ) ]]; then
      cyder_reset_shared_prefix
    fi
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
  if [[ -z "$bundled_version" && -x "$dest/bin/wine" ]]; then
    bundled_version="$(cyder_format_engine_version_from_wine "$dest/bin/wine" 2>/dev/null || true)"
  fi
  if [[ -n "$bundled_version" ]]; then
    cyder_write_engine_version_file "$dest" "$bundled_version"
    rm -f "$dest/.cyder-engine-version"
  fi
  cyder_sign_installed_engine "$dest" || exit 1
  echo "$dest"
}

cyder_init_bottle() {
  local wine_bin="$1"
  local bottle="$2"
  CYDER_OPERATION_ERROR_KIND=""
  CYDER_OPERATION_ERROR_CODE=""
  export CYDER_OPERATION_ERROR_KIND CYDER_OPERATION_ERROR_CODE
  local wineserver="${wine_bin%/wine}/wineserver"
  if [[ -f "$bottle/system.reg" ]]; then
    echo "Bottle exists: $bottle" >&2
    return 0
  fi
  echo "Creating bottle: $bottle" >&2
  mkdir -p "$bottle"
  local log_dir="$CYDER_SUPPORT/Logs/operations"
  local log_file="$log_dir/wineboot-$(date '+%Y%m%d-%H%M%S')-$$.log"
  mkdir -p "$log_dir"
  # Keep operation history bounded without ever removing the stable
  # last-wineboot symlink (or the operation it currently references).
  local last_target=""
  if [[ -L "$CYDER_SUPPORT/Logs/last-wineboot.log" ]]; then
    last_target="$(readlink "$CYDER_SUPPORT/Logs/last-wineboot.log" 2>/dev/null || true)"
    last_target="${last_target##*/}"
  fi
  local old_log
  for old_log in "$log_dir"/wineboot-*.log; do
    [[ -f "$old_log" ]] || continue
    [[ "$(basename "$old_log")" == "$last_target" ]] && continue
    find "$old_log" -prune -mtime +30 -delete 2>/dev/null || true
  done
  : >"$log_file"
  local engine_version="${CYDER_ENGINE_VERSION_LABEL:-}"
  if [[ -z "$engine_version" ]]; then
    engine_version="$(cyder_format_engine_version_from_wine "$wine_bin" 2>/dev/null || true)"
  fi
  [[ -n "$engine_version" ]] || engine_version=unknown
  local os_version
  os_version="$(sw_vers -productVersion 2>/dev/null || uname -sr 2>/dev/null || true)"
  [[ -n "$os_version" ]] || os_version=unknown
  local cpu_arch
  cpu_arch="$(uname -m 2>/dev/null || true)"
  [[ -n "$cpu_arch" ]] || cpu_arch=unknown
  {
    echo "operation=wineboot"
    echo "wine=$wine_bin"
    echo "prefix=$bottle"
    echo "engine_version=$engine_version"
    echo "os_version=$os_version"
    echo "cpu_arch=$cpu_arch"
    echo "started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
  } >>"$log_file"
  ln -sfn "operations/$(basename "$log_file")" "$CYDER_SUPPORT/Logs/last-wineboot.log"
  local status=0 timed_out=0
  local timeout="${CYDER_WINEBOOT_TIMEOUT:-120}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=120
  (( timeout > 0 )) || timeout=1
  # Run wineboot asynchronously so a hung Wine process cannot leave Cyder's
  # first-launch preparation dialog open forever. The timeout is deliberately
  # implemented with Bash primitives; macOS does not ship GNU timeout.
  (
    cyder_wine_locale_exports
    export WINEPREFIX="$bottle" WINESERVER="$wineserver"
    # Build the base prefix deterministically. Wine may otherwise discover
    # cached Mono/Gecko installers and modify "pristine" during wineboot.
    # Golden installs the pinned, checksummed versions explicitly afterwards.
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
    cyder_run arch -x86_64 "$wine_bin" wineboot -u >>"$log_file" 2>&1
  ) &
  local wineboot_pid=$!
  local deadline=$((SECONDS + timeout))
  while kill -0 "$wineboot_pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      timed_out=1
      kill -TERM "$wineboot_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$wineboot_pid" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  if (( timed_out )); then
    wait "$wineboot_pid" 2>/dev/null || true
    status=124
    CYDER_OPERATION_ERROR_KIND=timeout
    CYDER_OPERATION_ERROR_CODE=CYD-WINEBOOT-TIMEOUT
  else
    wait "$wineboot_pid" || status=$?
    if (( status >= 128 )); then
      CYDER_OPERATION_ERROR_KIND=signal
      CYDER_OPERATION_ERROR_CODE=CYD-WINEBOOT-SIGNAL
    elif (( status != 0 )); then
      CYDER_OPERATION_ERROR_KIND=exit
      CYDER_OPERATION_ERROR_CODE=CYD-WINEBOOT-EXIT
    fi
  fi
  # `wineboot` may return before wineserver has flushed system.reg/user.reg.
  # Checking artifacts at that point produces a false CYD-WINEBOOT-ARTIFACT
  # on real CrossOver engines. Give the flush its own bounded wait, then
  # inspect the completed prefix.
  if (( status == 0 )) && [[ -x "$wineserver" ]]; then
    local wineserver_wait_timeout="${CYDER_WINESERVER_WAIT_TIMEOUT:-30}"
    [[ "$wineserver_wait_timeout" =~ ^[0-9]+$ ]] || wineserver_wait_timeout=30
    (( wineserver_wait_timeout > 0 )) || wineserver_wait_timeout=1
    local wineserver_deadline=$((SECONDS + wineserver_wait_timeout))
    echo "success_wait=wineserver -w" >>"$log_file"
    (
      cyder_wine_locale_exports
      export WINEPREFIX="$bottle" WINESERVER="$wineserver"
      cyder_run arch -x86_64 "$wineserver" -w >>"$log_file" 2>&1
    ) &
    local wineserver_wait_pid=$!
    while kill -0 "$wineserver_wait_pid" 2>/dev/null; do
      if (( SECONDS >= wineserver_deadline )); then
        timed_out=1
        kill -TERM "$wineserver_wait_pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$wineserver_wait_pid" 2>/dev/null || true
        break
      fi
      sleep 1
    done
    if (( timed_out )); then
      wait "$wineserver_wait_pid" 2>/dev/null || true
      status=124
      CYDER_OPERATION_ERROR_KIND=timeout
      CYDER_OPERATION_ERROR_CODE=CYD-WINEBOOT-TIMEOUT
    else
      wait "$wineserver_wait_pid" || status=$?
      if (( status != 0 )); then
        CYDER_OPERATION_ERROR_KIND=exit
        CYDER_OPERATION_ERROR_CODE=CYD-WINEBOOT-EXIT
      fi
    fi
  fi
  if (( status == 0 )); then
    local missing=()
    [[ -f "$bottle/system.reg" ]] || missing+=(system.reg)
    [[ -f "$bottle/user.reg" ]] || missing+=(user.reg)
    [[ -d "$bottle/drive_c" ]] || missing+=(drive_c)
    [[ -f "$bottle/drive_c/windows/system32/kernel32.dll" || \
       -f "$bottle/drive_c/windows/syswow64/kernel32.dll" ]] || missing+=(kernel32.dll)
    if (( ${#missing[@]} > 0 )); then
      status=125
      CYDER_OPERATION_ERROR_KIND=artifact-missing
      CYDER_OPERATION_ERROR_CODE=CYD-WINEBOOT-ARTIFACT
      echo "missing_artifacts=${missing[*]}" >>"$log_file"
    fi
  fi
  # Any failed wineboot can leave a partially initialized wineserver behind,
  # not only a timeout. Always clean it before returning an error so the next
  # attempt starts with a fresh session.
  if (( status != 0 )) && [[ -x "$wineserver" ]]; then
    echo "failure_cleanup=wineserver -k" >>"$log_file"
    WINEPREFIX="$bottle" arch -x86_64 "$wineserver" -k >>"$log_file" 2>&1 || true
    echo "failure_cleanup=wineserver -w" >>"$log_file"
    WINEPREFIX="$bottle" arch -x86_64 "$wineserver" -w >>"$log_file" 2>&1 || true
  fi
  echo "exit_status=$status" >>"$log_file"
  echo "result=${CYDER_OPERATION_ERROR_KIND:-success}" >>"$log_file"
  echo "error_code=${CYDER_OPERATION_ERROR_CODE:-}" >>"$log_file"
  cat "$log_file" >&2
  if [[ "$status" -ne 0 ]]; then
    return "$status"
  fi
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

cyder_health_check_prefix() {
  local wine_bin="$1"
  local prefix="${2:-$CYDER_SHARED_PREFIX}"
  local wineserver="${wine_bin%/wine}/wineserver"
  [[ -x "$wine_bin" ]] || { echo "missing wine binary: $wine_bin" >&2; return 1; }
  [[ -f "$prefix/system.reg" && -f "$prefix/user.reg" ]] || {
    echo "prefix registry files are missing: $prefix" >&2
    return 1
  }
  [[ -f "$prefix/drive_c/windows/system32/kernel32.dll" || \
     -f "$prefix/drive_c/windows/syswow64/kernel32.dll" ]] || {
    echo "prefix kernel32.dll is missing: $prefix" >&2
    return 1
  }
  if cyder_has_running_prefix "$prefix"; then
    echo "health probe skipped: prefix is in use: $prefix" >&2
    return 0
  fi
  local log_dir="$CYDER_SUPPORT/Logs/operations"
  local log_file="$log_dir/health-check-$(date '+%Y%m%d-%H%M%S')-$$.log"
  mkdir -p "$log_dir"
  : >"$log_file"
  {
    echo "operation=health-check"
    echo "wine=$wine_bin"
    echo "prefix=$prefix"
    echo "probe=cmd /c exit 0"
    echo "started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
  } >>"$log_file"
  ln -sfn "operations/$(basename "$log_file")" "$CYDER_SUPPORT/Logs/last-health-check.log"
  local status=0
  if (
    cyder_wine_locale_exports
    export WINEPREFIX="$prefix" WINESERVER="$wineserver"
    cyder_run arch -x86_64 "$wine_bin" cmd /c exit 0 >>"$log_file" 2>&1
  ); then
    status=0
  else
    status=$?
  fi
  # The probe is read-only from Cyder's perspective, but it starts a
  # wineserver. Leaving that server alive would lock in a non-MSync session
  # and make the next MSync launch fail with bootstrap_look_up.
  (
    cyder_wine_locale_exports
    export WINEPREFIX="$prefix" WINESERVER="$wineserver"
    arch -x86_64 "$wineserver" -k >>"$log_file" 2>&1 || true
    arch -x86_64 "$wineserver" -w >>"$log_file" 2>&1 || true
  )
  echo "exit_status=$status" >>"$log_file"
  cat "$log_file" >&2
  return "$status"
}

cyder_rebuild_shared_prefix() {
  local wine_bin="$1" engine_root="$2"
  cyder_has_running_prefix "$CYDER_SHARED_PREFIX" && {
    echo "Cannot rebuild prefix while a Wine process is running." >&2
    return 2
  }
  local parent staging backup backup_root prefix_name active_prefix
  active_prefix="$CYDER_SHARED_PREFIX"
  parent="$(dirname "$active_prefix")"
  prefix_name="$(basename "$active_prefix")"
  backup_root="$CYDER_SUPPORT/backups"
  staging="$parent/.rebuild-${prefix_name}-$$"
  backup="$backup_root/${prefix_name}-$(date '+%Y%m%d-%H%M%S')-$$"

  # Refuse to operate on an unexpected symlink or an already-running rebuild.
  # This keeps a stale/attacker-controlled path from being moved into the
  # active bottle location.
  [[ ! -L "$active_prefix" ]] || {
    echo "Cannot rebuild a symlinked shared prefix: $active_prefix" >&2
    return 2
  }
  [[ ! -e "$staging" && ! -L "$staging" ]] || {
    echo "A prefix rebuild is already in progress: $staging" >&2
    return 2
  }
  [[ ! -e "$backup" && ! -L "$backup" ]] || {
    echo "Backup path already exists; refusing to overwrite: $backup" >&2
    return 2
  }
  mkdir -p "$parent" "$backup_root"

  local had_previous=0
  if [[ -e "$active_prefix" ]]; then
    had_previous=1
  fi

  cyder_rebuild_restore_previous() {
    local reason="$1"
    cyder_remove_path "$active_prefix"
    if [[ "$had_previous" -eq 1 && -e "$backup" ]]; then
      mv "$backup" "$active_prefix"
      echo "Prefix rebuild rolled back ($reason); previous environment restored." >&2
    else
      echo "Prefix rebuild rolled back ($reason); no previous environment was available." >&2
    fi
  }

  cyder_prepare_pristine_template "$wine_bin" "$engine_root" || return $?
  cyder_prepare_golden_template "$wine_bin" "$engine_root" || return $?
  cyder_profile_backend_load || return $?
  if ! cyder_profile_clone_bottle "$CYDER_SUPPORT/templates/golden" "$staging"; then
    echo "Prefix rebuild failed while cloning Golden; no active data was changed." >&2
    return 1
  fi
  if [[ "$had_previous" -eq 1 ]]; then
    if ! mv "$active_prefix" "$backup"; then
      echo "Prefix rebuild failed while creating backup: $backup" >&2
      return 1
    fi
  fi
  if ! mv "$staging" "$active_prefix"; then
    echo "Prefix rebuild failed while publishing staging prefix: $active_prefix" >&2
    if [[ "$had_previous" -eq 1 && -e "$backup" && ! -e "$active_prefix" ]]; then
      mv "$backup" "$active_prefix" || true
    fi
    return 1
  fi
  printf 'revision=%s\n' "$CYDER_TEMPLATE_REVISION" >"$CYDER_BOOTSTRAP_MARKER"
  if ! cyder_health_check_prefix "$wine_bin" "$active_prefix"; then
    cyder_rebuild_restore_previous "health check failed"
    return 1
  fi
  unset -f cyder_rebuild_restore_previous
  echo "Prefix rebuild completed successfully: $active_prefix" >&2
}

cyder_ensure_shared_prefix() {
  local wine_bin="$1"
  cyder_init_bottle "$wine_bin" "$CYDER_SHARED_PREFIX"
}

# Load the shell profile backend lazily so normal launcher paths do not pay for
# profile helpers until bootstrap actually needs template lifecycle handling.
cyder_profile_backend_load() {
  if ! declare -F cyder_profile_publish_template >/dev/null 2>&1; then
    local profile_sh="$CYDER_SCRIPTS/cyder-profile.sh"
    [[ -f "$profile_sh" ]] || {
      echo "Cyder profile backend is missing: $profile_sh" >&2
      return 1
    }
    # shellcheck source=cyder-profile.sh
    source "$profile_sh"
  fi
}

cyder_stop_prefix_wineserver() {
  local wine_bin="$1" prefix="$2"
  local wineserver="${wine_bin%/wine}/wineserver"
  [[ -x "$wineserver" ]] || return 0
  WINEPREFIX="$prefix" arch -x86_64 "$wineserver" -k || true
  WINEPREFIX="$prefix" arch -x86_64 "$wineserver" -w || true
}

cyder_profile_has_live_sessions() {
  local prefix="$1" dir file pid
  dir="$(cyder_session_dir "$prefix")"
  [[ -d "$dir" ]] || return 1
  for file in "$dir"/*.session; do
    [[ -f "$file" ]] || continue
    pid="$(sed -n 's/^pid=//p' "$file" | head -1)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      echo "active Cyder profile session prevents template publish (pid=$pid)" >&2
      return 0
    fi
    rm -f "$file"
  done
  return 1
}

cyder_template_engine_version() {
  local wine_bin="$1" version
  version="${CYDER_ENGINE_VERSION_LABEL:-}"
  if [[ -z "$version" ]]; then
    version="$(cyder_format_engine_version_from_wine "$wine_bin" 2>/dev/null || true)"
  fi
  [[ -n "$version" ]] || version=unknown
  printf '%s\n' "$version"
}

cyder_prepare_pristine_template() {
  local wine_bin="$1" engine_root="$2"
  cyder_profile_backend_load || return $?
  local revision="${CYDER_TEMPLATE_REVISION:-1}"
  local engine_version
  engine_version="$(cyder_template_engine_version "$wine_bin")"
  cyder_profile_init_layout "$CYDER_SUPPORT"
  if cyder_profile_template_ready pristine "$CYDER_SUPPORT" "$revision" "$engine_version"; then
    return 0
  fi

  # Pristine is always produced in isolation. Shared is never a template
  # source, even on first run, so user state cannot flow back into Golden.
  local staging
  mkdir -p "$CYDER_SUPPORT/staging"
  staging="$(mktemp -d "$CYDER_SUPPORT/staging/.pristine-XXXXXX")"
  if ! cyder_init_bottle "$wine_bin" "$staging"; then
    rm -rf "$staging"
    echo "Failed to create pristine staging prefix: $staging" >&2
    return 1
  fi
  if ! cyder_profile_publish_template "$staging" pristine "$CYDER_SUPPORT" \
      "$revision" "$engine_version"; then
    rm -rf "$staging"
    echo "Failed to publish pristine template; existing shared/template state was left intact." >&2
    return 1
  fi
  rm -rf "$staging"
}

cyder_prepare_golden_template() {
  local wine_bin="$1" engine_root="$2"
  cyder_profile_backend_load || return $?
  local revision="${CYDER_TEMPLATE_REVISION:-2}"
  local engine_version
  engine_version="$(cyder_template_engine_version "$wine_bin")"
  cyder_profile_init_layout "$CYDER_SUPPORT"
  local golden="$CYDER_SUPPORT/templates/golden"
  if cyder_profile_template_ready golden "$CYDER_SUPPORT" "$revision" "$engine_version" \
      && [[ -f "$golden/.cyder-mono-10.4.1" \
         && -f "$golden/.cyder-gecko-2.47.4" \
         && -f "$golden/.cyder-golden-baseline-v2" ]]; then
    return 0
  fi

  local staging
  mkdir -p "$CYDER_SUPPORT/staging"
  staging="$(mktemp -d "$CYDER_SUPPORT/staging/.golden-XXXXXX")"
  rm -rf "$staging"
  if ! cyder_profile_clone_bottle "$CYDER_SUPPORT/templates/pristine" "$staging"; then
    echo "Failed to clone pristine prefix for Golden staging." >&2
    return 1
  fi

  local component status=0
  for component in install-wine-mono.sh install-wine-gecko.sh; do
    [[ -f "$CYDER_SCRIPTS/$component" ]] || {
      echo "Golden component installer is missing: $component" >&2
      status=1
      break
    }
    (
      export WINEPREFIX="$staging" WINE_INSTALL="$engine_root" CYDER_DOWNLOADS="$CYDER_DOWNLOADS"
      bash "$CYDER_SCRIPTS/$component"
    ) || { status=$?; break; }
  done
  if [[ "$status" -eq 0 && -f "$CYDER_SCRIPTS/install-libarchive-tar.sh" ]]; then
    (
      export WINEPREFIX="$staging" WINE_INSTALL="$engine_root"
      export OGOM="${CYDER_OGOM:-${OGOM:-}}"
      export CYDER_LIBARCHIVE_SRC="${CYDER_LIBARCHIVE_SRC:-$(cyder_resolve_libarchive_src)}"
      bash "$CYDER_SCRIPTS/install-libarchive-tar.sh" --prefix "$staging"
    ) || status=$?
  fi
  if [[ "$status" -eq 0 ]]; then
    (
      export WINEPREFIX="$staging" WINE_INSTALL="$engine_root"
      bash "$CYDER_SCRIPTS/cyder-apply-golden-settings.sh"
    ) || status=$?
  fi
  cyder_stop_prefix_wineserver "$wine_bin" "$staging" || status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "Golden staging failed and was retained for diagnostics: $staging" >&2
    return "$status"
  fi
  if ! cyder_health_check_prefix "$wine_bin" "$staging"; then
    echo "Golden staging health check failed and was retained: $staging" >&2
    return 1
  fi
  cyder_stop_prefix_wineserver "$wine_bin" "$staging" || return $?
  if ! cyder_profile_publish_template "$staging" golden "$CYDER_SUPPORT" \
      "$revision" "$engine_version"; then
    echo "Failed to publish Golden template; staging retained: $staging" >&2
    return 1
  fi
  rm -rf "$staging"
}

cyder_clone_golden_to_shared() {
  local wine_bin="$1"
  cyder_profile_backend_load || return $?
  local golden="$CYDER_SUPPORT/templates/golden"
  [[ -f "$golden/system.reg" && -f "$golden/.cyder-golden-baseline-v2" ]] || {
    echo "Golden template is incomplete: $golden" >&2
    return 1
  }
  [[ ! -e "$CYDER_SHARED_PREFIX" && ! -L "$CYDER_SHARED_PREFIX" ]] || {
    echo "Shared prefix destination already exists: $CYDER_SHARED_PREFIX" >&2
    return 1
  }
  CYDER_BOOTSTRAP_HEALTH_CHECKED=0
  cyder_profile_clone_bottle "$golden" "$CYDER_SHARED_PREFIX" || return $?
  printf 'revision=%s\n' "$CYDER_TEMPLATE_REVISION" >"$CYDER_BOOTSTRAP_MARKER"
  cyder_health_check_prefix "$wine_bin" "$CYDER_SHARED_PREFIX" || return $?
  CYDER_BOOTSTRAP_HEALTH_CHECKED=1
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
  WINEPREFIX="$CYDER_SHARED_PREFIX" WINE_INSTALL="$engine_root" bash "$font_sh" || return $?
  printf 'ok\n' >"$CYDER_FONT_MARKER"
}

# Settings entered from the game-library UI are keyed by the stable EXE ID.
# Keep the shell launch path in sync with the native AppKit path so Finder
# associations and --launch-exe receive the same per-game settings.
CYDER_GAME_ARGUMENTS=()
CYDER_GAME_SETTINGS_FOUND=0

cyder_load_game_settings() {
  local exe="$1"
  local profile_script="$CYDER_SCRIPTS/cyder-profile.sh"
  local settings_file="$CYDER_SUPPORT/settings.json"
  local profile_id game_json
  CYDER_GAME_ARGUMENTS=()
  CYDER_GAME_SETTINGS_FOUND=0

  [[ -x "$profile_script" && -f "$settings_file" ]] || return 0
  profile_id="$(bash "$profile_script" id "$exe" 2>/dev/null)" || return 0
  [[ "$profile_id" =~ ^profile-[0-9a-f]{24}$ ]] || return 0
  game_json="$(/usr/bin/plutil -extract "perProfile.$profile_id" json -o - "$settings_file" 2>/dev/null)" || return 0
  [[ -n "$game_json" ]] || return 0
  CYDER_GAME_SETTINGS_FOUND=1

  # Ruby is part of the supported macOS toolchain used by the project. The
  # scalar fallback below still applies registry settings on systems where it
  # is unavailable; custom environment variables/arguments are optional.
  if [[ -x /usr/bin/ruby ]]; then
    local kind key value
    while IFS=$'\t' read -r kind key value; do
      [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || continue
      case "$kind" in
        setting)
          case "$key" in
            msync) case "$value" in true) export CYDER_MSYNC=1 ;; false) export CYDER_MSYNC=0 ;; esac ;;
            esync) case "$value" in true) export CYDER_ESYNC=1 ;; false) export CYDER_ESYNC=0 ;; esac ;;
            retinaMode) case "$value" in true) export CYDER_RETINA_MODE=1 ;; false) export CYDER_RETINA_MODE=0 ;; esac ;;
            dpi) [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 72 && value <= 480 )) && export CYDER_DPI="$value" || true ;;
            fontPreset) [[ "$value" == songti || "$value" == mingliu ]] && export CYDER_FONT_PRESET="$value" || true ;;
            fontSmoothing) case "$value" in off|grayscale|cleartype-rgb|cleartype-bgr) export CYDER_FONT_SMOOTHING="$value" ;; esac ;;
            powerMode) case "$value" in standard) export CYDER_POWER_MODE=normal ;; energySaving) export CYDER_POWER_MODE=background ;; esac ;;
          esac
          ;;
        environment)
          [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && export "$key=$value"
          ;;
        argument)
          CYDER_GAME_ARGUMENTS+=("$key")
          ;;
      esac
    done < <(/usr/bin/ruby -rjson -e '
      rule = JSON.parse(STDIN.read)
      %w[msync esync retinaMode dpi fontPreset fontSmoothing powerMode].each do |key|
        puts "setting\t#{key}\t#{rule[key]}" if rule.key?(key) && !rule[key].nil?
      end
      (rule["environment"] || {}).each { |key, value| puts "environment\t#{key}\t#{value}" }
      (rule["arguments"] || []).each { |value| puts "argument\t#{value}" }
    ' <<<"$game_json")
  else
    local value
    value="$(/usr/bin/plutil -extract msync raw -o - - 2>/dev/null <<<"$game_json" || true)"
    case "$value" in true) export CYDER_MSYNC=1 ;; false) export CYDER_MSYNC=0 ;; esac
    value="$(/usr/bin/plutil -extract esync raw -o - - 2>/dev/null <<<"$game_json" || true)"
    case "$value" in true) export CYDER_ESYNC=1 ;; false) export CYDER_ESYNC=0 ;; esac
    value="$(/usr/bin/plutil -extract retinaMode raw -o - - 2>/dev/null <<<"$game_json" || true)"
    case "$value" in true) export CYDER_RETINA_MODE=1 ;; false) export CYDER_RETINA_MODE=0 ;; esac
    value="$(/usr/bin/plutil -extract dpi raw -o - - 2>/dev/null <<<"$game_json" || true)"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 72 && value <= 480 )) && export CYDER_DPI="$value" || true
  fi
}

cyder_prepare_game_launch_settings() {
  local wine_bin="$1"
  local engine_root="$2"
  local prefix="$3"
  local exe="$4"
  cyder_load_game_settings "$exe"
  [[ "$CYDER_GAME_SETTINGS_FOUND" -eq 1 ]] || return 0

  local prefix_was_running=0
  cyder_has_running_prefix "$prefix" && prefix_was_running=1
  cyder_apply_user_settings "$wine_bin" "$engine_root" "$prefix" || return $?
  local wineserver="$engine_root/bin/wineserver"
  if [[ "$prefix_was_running" -eq 0 && -x "$wineserver" ]]; then
    WINEPREFIX="$prefix" /usr/bin/arch -x86_64 "$wineserver" -k || true
    WINEPREFIX="$prefix" /usr/bin/arch -x86_64 "$wineserver" -w || true
  fi
}

cyder_apply_user_settings() {
  local wine_bin="$1"
  local engine_root="$2"
  local prefix="${3:-$CYDER_SHARED_PREFIX}"
  local settings_sh="$CYDER_SCRIPTS/cyder-apply-settings.sh"
  [[ -f "$settings_sh" ]] || return 0
  if [[ "${CYDER_FORCE_SETTINGS:-0}" != 1 ]] && cyder_has_running_prefix "$prefix"; then
    # EXE launches never run a Wine registry client against an active prefix.
    # Display and font registry settings need a fresh wineserver to take effect
    # anyway. Keep the saved rule and apply it on the next inactive launch.
    echo "Skipped Cyder registry settings: prefix is already running; changes are deferred until restart."
    return 0
  fi
  if [[ "${CYDER_FORCE_SETTINGS:-0}" != 1 && -f "$CYDER_SCRIPTS/cyder-edit-user-reg.sh" ]]; then
    WINEPREFIX="$prefix" bash "$CYDER_SCRIPTS/cyder-edit-user-reg.sh"
    return $?
  fi
  # The Wine registry client is reserved for Preferences > Advanced > Apply
  # All Settings, which explicitly sets CYDER_FORCE_SETTINGS=1.
  WINEPREFIX="$prefix" WINE_INSTALL="$engine_root" bash "$settings_sh"
}

cyder_stop_all_exes() {
  local wineserver="$CYDER_ENGINES/$CYDER_ENGINE_NAME/bin/wineserver"
  local legacy_wineserver="$CYDER_LEGACY_ENGINES/$CYDER_ENGINE_NAME/bin/wineserver"
  if [[ ! -x "$wineserver" && -x "$legacy_wineserver" ]]; then
    wineserver="$legacy_wineserver"
  fi
  if [[ ! -x "$wineserver" ]]; then
    echo "Cyder engine is not installed; no EXEs to stop." >&2
    return 0
  fi
  local prefix
  for prefix in "$CYDER_SHARED_PREFIX" "$CYDER_LEGACY_SHARED_PREFIX"; do
    [[ -d "$prefix" ]] || continue
    echo "Stopping all EXEs in $prefix" >&2
    WINEPREFIX="$prefix" arch -x86_64 "$wineserver" -k || true
  done
}

cyder_has_running_prefix() {
  local prefix="$1"
  [[ -d "$prefix" ]] || return 1
  local device inode socket_dir
  device="$(stat -f '%d' "$prefix" 2>/dev/null)" || return 1
  inode="$(stat -f '%i' "$prefix" 2>/dev/null)" || return 1
  printf -v device '%x' "$device"
  printf -v inode '%x' "$inode"
  socket_dir="/tmp/.wine-$(id -u)/server-$device-$inode"
  # Wine removes the socket when the prefix wineserver exits; the lock file may remain.
  [[ -S "$socket_dir/socket" ]]
}

cyder_has_running_exes() {
  cyder_has_running_prefix "$CYDER_SHARED_PREFIX" && return 0
  if [[ "$CYDER_LEGACY_SHARED_PREFIX" != "$CYDER_SHARED_PREFIX" ]]; then
    cyder_has_running_prefix "$CYDER_LEGACY_SHARED_PREFIX" && return 0
  fi
  return 1
}

cyder_bootstrap_shared_prefix() {
  local wine_bin="$1"
  local engine_root="$2"
  CYDER_BOOTSTRAP_HEALTH_CHECKED=0
  cyder_diagnostic_stage wineboot
  cyder_prepare_pristine_template "$wine_bin" "$engine_root" || return $?
  cyder_diagnostic_stage golden-setup
  cyder_prepare_golden_template "$wine_bin" "$engine_root" || return $?
  if [[ -f "$CYDER_BOOTSTRAP_MARKER" \
        && -f "$CYDER_SHARED_PREFIX/system.reg" \
        && -f "$CYDER_SHARED_PREFIX/.cyder-golden-baseline-v2" ]]; then
    return 0
  fi
  cyder_has_running_prefix "$CYDER_SHARED_PREFIX" && {
    echo "Cannot replace shared prefix while Wine is running." >&2
    return 75
  }
  if [[ -e "$CYDER_SHARED_PREFIX" ]]; then
    local old_shared="$CYDER_SUPPORT/backups/shared-bootstrap-$(date '+%Y%m%d-%H%M%S')-$$"
    mkdir -p "$CYDER_SUPPORT/backups"
    mv "$CYDER_SHARED_PREFIX" "$old_shared" || return $?
    if ! cyder_clone_golden_to_shared "$wine_bin"; then
      rm -rf "$CYDER_SHARED_PREFIX"
      mv "$old_shared" "$CYDER_SHARED_PREFIX" || true
      return 1
    fi
  else
    cyder_clone_golden_to_shared "$wine_bin" || return $?
  fi
}

cyder_run_wine_exe() {
  local wine_bin="$1"
  local exe="$2"
  local prefix="${3:-$CYDER_SHARED_PREFIX}"
  if [[ $# -ge 3 ]]; then
    shift 3
  else
    shift 2
  fi
  local -a game_args=("$@")
  local game_args_text="${game_args[*]-}"
  local wineserver="${wine_bin%/wine}/wineserver"
  # Keep the legacy direct path as the default.  Wine's ShellExecute-compatible
  # start.exe path is available for A/B testing with CYDER_WINE_START_MODE=start
  # but does not guarantee macOS frontmost activation.
  local start_mode="${CYDER_WINE_START_MODE:-direct}"
  local detach="${CYDER_WINE_DETACH:-0}"
  local pid_file="${CYDER_WINE_PID_FILE:-}"
  local session_id=""
  cyder_wine_locale_exports
  local capture_log="${CYDER_CAPTURE_WINE_LOG:-0}"
  local log_file="/dev/null"
  rm -f "$CYDER_SUPPORT/Logs/last-launch.log"
  if [[ "$capture_log" == 1 ]]; then
    local log_dir="$CYDER_SUPPORT/Logs"
    mkdir -p "$log_dir"
    log_file="$log_dir/launch-$(date '+%Y%m%d-%H%M%S')-$$.log"
    local latest_log="$log_dir/last-launch.log"
    : >"$log_file"
    ln -s "$(basename "$log_file")" "$latest_log"
    find "$log_dir" -maxdepth 1 -type f -name 'launch-*.log' -mtime +30 -delete 2>/dev/null || true
  fi
  if [[ "$detach" == 1 && -n "$pid_file" ]]; then
    mkdir -p "$(dirname "$pid_file")"
    rm -f "$pid_file" "${pid_file}.tmp"
  fi
  cyder_exec_game() {
    if [[ "$start_mode" == "start" ]]; then
      if (( ${#game_args[@]} > 0 )); then
        cyder_exec_wine "$wine_bin" start /wait /unix "$exe" "${game_args[@]}"
      else
        cyder_exec_wine "$wine_bin" start /wait /unix "$exe"
      fi
    elif (( ${#game_args[@]} > 0 )); then
      cyder_exec_wine "$wine_bin" "$exe" "${game_args[@]}"
    else
      cyder_exec_wine "$wine_bin" "$exe"
    fi
  }
  {
    local taskpolicy_bin=""
    taskpolicy_bin="$(cyder_find_taskpolicy || true)"
    if [[ "$start_mode" == "start" ]]; then
      if [[ "${CYDER_POWER_MODE:-normal}" == background && -n "$taskpolicy_bin" ]]; then
        echo "cmd=$taskpolicy_bin -c background /usr/bin/arch -x86_64 $wine_bin start /wait /unix $exe $game_args_text"
      else
        echo "cmd=arch -x86_64 $wine_bin start /wait /unix $exe $game_args_text"
      fi
    else
      if [[ "${CYDER_POWER_MODE:-normal}" == background && -n "$taskpolicy_bin" ]]; then
        echo "cmd=$taskpolicy_bin -c background /usr/bin/arch -x86_64 $wine_bin $exe $game_args_text"
      else
        echo "cmd=arch -x86_64 $wine_bin $exe $game_args_text"
      fi
    fi
    echo "power_mode=${CYDER_POWER_MODE:-normal}"
    echo "taskpolicy_available=$([[ -n "$taskpolicy_bin" ]] && echo true || echo false)"
    echo "WINEPREFIX=$prefix"
    echo "cwd=$(dirname "$exe")"
    echo
  } >>"$log_file"
  (
    export WINEPREFIX="$prefix" WINESERVER="$wineserver"
    if [[ "${CYDER_MSYNC:-0}" == 1 ]]; then
      export WINEMSYNC=1
      unset WINEESYNC
    elif [[ "${CYDER_ESYNC:-0}" == 1 ]]; then
      export WINEESYNC=1
      unset WINEMSYNC
    else
      unset WINEMSYNC
      unset WINEESYNC
    fi
    export PATH="${wine_bin%/wine}:$PATH"
    cd "$(dirname "$exe")"
    if [[ "${CYDER_SESSION_GUARD:-0}" != 0 ]]; then
      cyder_session_acquire "$prefix" "${CYDER_MSYNC:-0}" "${CYDER_ESYNC:-0}" "${CYDER_POWER_MODE:-normal}" || return $?
      session_id="$CYDER_SESSION_FILE"
    fi
    cyder_session_release_on_exit() {
      if [[ -n "${session_id:-}" ]]; then
        cyder_session_release "$prefix" "$session_id"
      fi
      return 0
    }
    trap cyder_session_release_on_exit EXIT INT TERM
    if [[ "$detach" == 1 && -n "$pid_file" ]]; then
      # Native Cyder only needs the Wine PID long enough to activate the Wine
      # application.  The Wine process is intentionally asynchronous here;
      # Finder-launched apps have no controlling Terminal, so no nohup is
      # required. stdout/stderr are discarded unless diagnostic capture was
      # explicitly enabled with CYDER_CAPTURE_WINE_LOG=1.
      cyder_exec_game >>"$log_file" 2>&1 &
      wine_pid=$!
      printf '%s\n' "$wine_pid" >"${pid_file}.tmp"
      mv -f "${pid_file}.tmp" "$pid_file"
      if [[ -n "${session_id:-}" ]]; then
        # The detached Wine process, rather than the short-lived wrapper,
        # owns the runtime session.  A waiter removes the registry entry when
        # Wine exits so a second incompatible launch remains blocked.
        sed -i '' "s/^pid=.*/pid=$wine_pid/" "$session_id" 2>/dev/null || \
          sed -i "s/^pid=.*/pid=$wine_pid/" "$session_id"
        (
          while kill -0 "$wine_pid" 2>/dev/null; do sleep 1; done
          cyder_session_release "$prefix" "$session_id"
        ) &
        session_id=""
      fi
    else
      # CLI launches keep Wine in the foreground so the caller owns the game
      # lifetime. Finder's native entry point opts into the detached branch.
      cyder_exec_game >>"$log_file" 2>&1
    fi
  )
}

# Execute Wine with the requested power policy.  `normal` intentionally does
# not invoke taskpolicy; background is applied to arch, the process which
# creates wineserver, so the policy is inherited by the Wine session.
cyder_exec_wine() {
  local wine_bin="$1"
  shift
  local mode="${CYDER_POWER_MODE:-normal}"
  local taskpolicy_bin=""
  taskpolicy_bin="$(cyder_find_taskpolicy || true)"
  if [[ "$mode" == background && -n "$taskpolicy_bin" ]]; then
    "$taskpolicy_bin" -c background /usr/bin/arch -x86_64 "$wine_bin" "$@"
  else
    if [[ "$mode" != normal && -z "$taskpolicy_bin" ]]; then
      echo "error: taskpolicy is unavailable; select Standard energy mode" >&2
      return 127
    fi
    /usr/bin/arch -x86_64 "$wine_bin" "$@"
  fi
}

# A bottle's wineserver is shared by all clients.  Keep a small, atomic
# session registry so incompatible sync/power settings cannot be mixed.
# Return status 75 when a live incompatible session is present.
cyder_session_dir() {
  printf '%s\n' "${1%/}/.cyder-runtime/sessions"
}

cyder_session_acquire() {
  local prefix="$1" msync="${2:-0}" esync="${3:-0}" power="${4:-normal}"
  local dir lock file pid existing mode attempts=0 max_attempts="${CYDER_SESSION_LOCK_ATTEMPTS:-250}" owner
  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || {
    echo "invalid CYDER_SESSION_LOCK_ATTEMPTS: $max_attempts" >&2
    return 2
  }
  local missing_pid_attempts=0
  dir="$(cyder_session_dir "$prefix")"
  mkdir -p "$dir"
  lock="${dir}/.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ ! "$owner" =~ ^[0-9]+$ ]]; then
      missing_pid_attempts=$((missing_pid_attempts + 1))
      if (( missing_pid_attempts >= 5 )); then
        rm -rf "$lock"
        continue
      fi
    else
      missing_pid_attempts=0
      if ! kill -0 "$owner" 2>/dev/null; then
        rm -rf "$lock"
        continue
      fi
    fi
    (( attempts++ >= max_attempts )) && {
      echo "timed out acquiring Cyder session lock" >&2
      return 75
    }
    sleep 0.02
  done
  if ! printf '%s\n' "$$" >"$lock/pid"; then
    rm -rf "$lock"
    echo "failed to initialize Cyder session lock" >&2
    return 1
  fi
  for file in "$dir"/*.session; do
    [[ -f "$file" ]] || continue
    pid="$(sed -n 's/^pid=//p' "$file" | head -1)"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$file"
      continue
    fi
    mode="$(sed -n 's/^mode=//p' "$file" | head -1)"
    existing="$(sed -n 's/^sync=//p' "$file" | head -1)"
    if [[ "$existing" != "msync=${msync};esync=${esync};power=${power}" ]]; then
      rm -rf "$lock"
      echo "incompatible Cyder bottle session (pid=$pid mode=$mode)" >&2
      return 75
    fi
  done
  file="$dir/$$-${RANDOM:-0}-$(date +%s).session"
  # Keep compatibility with the macOS system Bash, which does not provide
  # BASHPID. The launcher process remains alive for the whole Wine session.
  if ! printf 'pid=%s\nsync=msync=%s;esync=%s;power=%s\nmode=%s\n' \
      "$$" "$msync" "$esync" "$power" "$power" >"$file"; then
    rm -rf "$lock"
    echo "failed to write Cyder session state" >&2
    return 1
  fi
  rm -rf "$lock"
  CYDER_SESSION_FILE="$file"
  export CYDER_SESSION_FILE
}

cyder_session_release() {
  local prefix="$1" session="$2"
  [[ -n "$session" ]] && rm -f "$session"
}

cyder_bootstrap_error_dialog() {
  local log="$CYDER_SUPPORT/Logs/bootstrap-error.log"
  mkdir -p "$(dirname "$log")"
  echo "$1" >"$log"
  osascript -e 'display alert "Cyder 初始化失敗" message "請查看 ~/Library/Application Support/Cyder/Logs/bootstrap-error.log" as warning' 2>/dev/null || true
}
