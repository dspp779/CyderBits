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

_graphics_sh="$CYDER_COMMON_DIR/cyder-ensure-graphics.sh"
if [[ -f "$_graphics_sh" ]]; then
  # shellcheck source=cyder-ensure-graphics.sh
  source "$_graphics_sh"
fi
unset _graphics_sh

_migrate_graphics_sh="$CYDER_COMMON_DIR/cyder-migrate-graphics-prefix.sh"
if [[ -f "$_migrate_graphics_sh" ]]; then
  # shellcheck source=cyder-migrate-graphics-prefix.sh
  source "$_migrate_graphics_sh"
fi
unset _migrate_graphics_sh

cyder_engine_artifacts_dir() {
  local root="${OGOM:-$(cd "$CYDER_COMMON_DIR/.." && pwd)}"
  printf '%s\n' "${CYDER_ENGINE_ARTIFACTS_DIR:-$root/dist/artifacts}"
}

cyder_crossover_version() {
  printf '%s\n' "${CYDER_CROSSOVER_VERSION:-26.3.0}"
}

# Prefer MingLiU when the Mac already has it; otherwise Songti TC.
cyder_detect_default_mingliu_target() {
  cyder_detect_default_font_preset
}

cyder_detect_default_font_preset() {
  local dir item lower
  if command -v fc-list >/dev/null 2>&1; then
    if fc-list 2>/dev/null | grep -qiE 'MingLiU|PMingLiU|細明體|新細明體'; then
      printf 'mingliu\n'
      return 0
    fi
  fi
  for dir in "$HOME/Library/Fonts" /Library/Fonts /System/Library/Fonts \
    /System/Library/Fonts/Supplemental; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r item; do
      lower="$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')"
      case "$lower" in
        *mingliu* | *pmingliu* | *細明體* | *新細明體*)
          printf 'mingliu\n'
          return 0
          ;;
      esac
    done < <(find "$dir" -maxdepth 2 -type f 2>/dev/null || true)
  done
  printf 'songti\n'
}

cyder_font_target_is_valid() {
  case "$1" in
    mingliu|songti|pingfang) return 0 ;;
  esac
  return 1
}

# Wine Fonts\\Replacements face name for a target id.
cyder_font_face_for_target() {
  case "$1" in
    mingliu) printf 'MingLiU\n' ;;
    songti) printf 'Songti TC\n' ;;
    pingfang) printf 'PingFang TC\n' ;;
    *) printf 'Songti TC\n' ;;
  esac
}

# Map legacy fontPreset to mingliu/songti target pair (stdout: two lines).
cyder_migrate_font_targets_from_preset() {
  case "${1:-}" in
    mingliu) printf '%s\n' mingliu songti ;;
    songti) printf '%s\n' songti songti ;;
    *) printf '%s\n' "$(cyder_detect_default_mingliu_target)" songti ;;
  esac
}

cyder_apply_font_targets_from_settings() {
  local settings="$1"
  local keep_mingliu="${2:-0}"
  local keep_songti="${3:-0}"
  local value preset migrated_ming migrated_song

  if [[ "$keep_mingliu" -eq 0 ]]; then
    value="$(plutil -extract fontMingLiuTarget raw -o - "$settings" 2>/dev/null || true)"
    if cyder_font_target_is_valid "$value"; then
      export CYDER_FONT_MINGLIU_TARGET="$value"
    fi
  fi
  if [[ "$keep_songti" -eq 0 ]]; then
    value="$(plutil -extract fontSongtiTarget raw -o - "$settings" 2>/dev/null || true)"
    if cyder_font_target_is_valid "$value"; then
      export CYDER_FONT_SONGTI_TARGET="$value"
    fi
  fi

  if [[ "$keep_mingliu" -eq 0 && -z "${CYDER_FONT_MINGLIU_TARGET:-}" ]] \
    || [[ "$keep_songti" -eq 0 && -z "${CYDER_FONT_SONGTI_TARGET:-}" ]]; then
    preset="$(plutil -extract fontPreset raw -o - "$settings" 2>/dev/null || true)"
    case "$preset" in songti|mingliu)
      IFS=$'\n' read -r migrated_ming migrated_song \
        < <(cyder_migrate_font_targets_from_preset "$preset")
      [[ "$keep_mingliu" -eq 0 && -z "${CYDER_FONT_MINGLIU_TARGET:-}" ]] \
        && export CYDER_FONT_MINGLIU_TARGET="$migrated_ming"
      [[ "$keep_songti" -eq 0 && -z "${CYDER_FONT_SONGTI_TARGET:-}" ]] \
        && export CYDER_FONT_SONGTI_TARGET="$migrated_song"
      ;;
    esac
  fi
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

# Engine archives built by older/special packaging flows may store the
# filesystem-safe slug in wine-x86_64/version while the app sidecar keeps the
# human-readable label.  Treat those representations as the same version so a
# successful extraction cannot leave document launches permanently reporting
# that the environment is not ready.
cyder_engine_versions_equal() {
  local left right left_slug right_slug
  left="$(cyder_engine_version_label_trim "${1:-}")"
  right="$(cyder_engine_version_label_trim "${2:-}")"
  [[ -n "$left" && -n "$right" ]] || return 1
  [[ "$left" == "$right" ]] && return 0
  left_slug="$(cyder_engine_version_slug_from_label "$left")"
  right_slug="$(cyder_engine_version_slug_from_label "$right")"
  [[ "$left_slug" == "$right" || "$left" == "$right_slug" || "$left_slug" == "$right_slug" ]]
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
  echo "Resetting shared bottle: $CYDER_SHARED_PREFIX" >&2
  cyder_remove_path "$CYDER_SHARED_PREFIX"
}

# Engine upgrades keep the shared bottle; clear the bootstrap marker so the next
# open re-runs provision (wineboot -u + baseline). Users can still wipe via
# Preferences → 重建 Windows 遊戲環境.
cyder_invalidate_shared_bootstrap_for_engine_upgrade() {
  if [[ -f "${CYDER_SHARED_PREFIX:-}/.cyder-bootstrap-v1" ]]; then
    echo "Engine upgrade: keeping shared bottle; clearing bootstrap marker for wineboot -u: $CYDER_SHARED_PREFIX" >&2
    rm -f "$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1"
  fi
  if [[ -n "${CYDER_SUPPORT:-}" && -e "$CYDER_SUPPORT/templates" ]]; then
    echo "Removing stale template bottles: $CYDER_SUPPORT/templates" >&2
    cyder_remove_path "$CYDER_SUPPORT/templates"
  fi
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
  local format="${3:-zst}"
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

cyder_read_bundled_engine_artifact_sha() {
  local resources="$1"
  local value=""
  [[ -f "$resources/engine-artifact-sha256.txt" ]] || return 1
  value="$(tr -d '[:space:]' <"$resources/engine-artifact-sha256.txt")"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$value"
}

cyder_bundled_engine_artifact_sha_from_src() {
  local engine_src="$1"
  local bundled_src=""
  [[ -n "${CYDER_OGOM:-}" ]] || return 1
  bundled_src="$(cyder_default_engine_src "$CYDER_OGOM" 2>/dev/null || true)"
  [[ -n "$bundled_src" ]] || return 1
  engine_src="$(cyder_abs_path "$engine_src")"
  bundled_src="$(cyder_abs_path "$bundled_src")"
  [[ "$engine_src" == "$bundled_src" ]] || return 1
  cyder_read_bundled_engine_artifact_sha "$CYDER_OGOM"
}

cyder_installed_engine_artifact_sha() {
  local engine_root="$1"
  local marker="$engine_root/.cyder-engine-artifact-sha256"
  local value=""
  [[ -f "$marker" ]] || return 1
  value="$(tr -d '[:space:]' <"$marker")"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$value"
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
    # `here` is the app's Resources directory when launched from the bundle.
    # Keep it explicit so graphics payload discovery does not construct the
    # invalid `$Contents/Contents/Resources` path from CYDER_APP.
    CYDER_RESOURCES="${CYDER_RESOURCES:-$here}"
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
  # Flavors (e.g. MapleStory OEM) may override engine / bottle names so they
  # do not collide with the regular Cyder wine-x86_64 + bottles/shared layout.
  CYDER_ENGINE_NAME="${CYDER_ENGINE_NAME:-wine-x86_64}"
  CYDER_BOTTLE_NAME="${CYDER_BOTTLE_NAME:-shared}"
  CYDER_PREFIX="${CYDER_PREFIX:-${CYDER_SHARED_PREFIX:-$CYDER_SUPPORT/bottles/$CYDER_BOTTLE_NAME}}"
  CYDER_SHARED_PREFIX="$CYDER_PREFIX"
  CYDER_LEGACY_ENGINES="${CYDER_LEGACY_ENGINES:-$CYDER_SUPPORT/Engines}"
  CYDER_LEGACY_SHARED_PREFIX="${CYDER_LEGACY_SHARED_PREFIX:-$CYDER_SUPPORT/SharedPrefix}"
  CYDER_BOOTSTRAP_MARKER="$CYDER_PREFIX/.cyder-bootstrap-v1"
  CYDER_FONT_MARKER="$CYDER_PREFIX/.cyder-font-songti-v1"
  # Global MSI/cache root (shared across bottles and isolated CYDER_SUPPORT).
  # Callers may still override via the environment.
  CYDER_DOWNLOADS="${CYDER_DOWNLOADS:-$HOME/Library/Application Support/Cyder/downloads}"
  CYDER_BUNDLE_ID="${CYDER_BUNDLE_ID:-local.cyder.app}"
  CYDER_TEMPLATE_REVISION="${CYDER_TEMPLATE_REVISION:-2}"
  export CYDER_TEMPLATE_REVISION
  cyder_configure_compatdb
}

cyder_resolve_compatdb_path() {
  [[ "${CYDER_COMPATDB:-1}" != 0 ]] || return 1

  if [[ -n "${CYDER_COMPATDB_PATH:-}" ]]; then
    local expected="${CYDER_COMPATDB_SHA256:-}"
    local actual=""
    if [[ "${CYDER_COMPATDB_ALLOW_UNSIGNED:-0}" == 1 &&
          "$expected" =~ ^[0-9a-f]{64}$ &&
          -f "$CYDER_COMPATDB_PATH" ]]; then
      actual="$(/usr/bin/shasum -a 256 "$CYDER_COMPATDB_PATH" 2>/dev/null | awk '{print $1}')"
    fi
    if [[ -n "$actual" && "$actual" == "$expected" ]]; then
      printf '%s\n' "$CYDER_COMPATDB_PATH"
      return 0
    fi
  fi

  local current_file="$CYDER_RUNTIME_ROOT/CompatDB/current"
  local version=""
  if [[ "${CYDER_COMPATDB_ALLOW_UNSIGNED:-0}" == 1 && -f "$current_file" ]]; then
    IFS= read -r version <"$current_file" || true
    if [[ "$version" =~ ^[0-9a-f]{64}$ ]]; then
      local updated="$CYDER_RUNTIME_ROOT/CompatDB/$version/compatdb.cdb"
      local actual=""
      if [[ -f "$updated" ]]; then
        actual="$(/usr/bin/shasum -a 256 "$updated" 2>/dev/null | awk '{print $1}')"
      fi
      if [[ "$actual" == "$version" ]]; then
        printf '%s\n' "$updated"
        return 0
      fi
    fi
  fi

  local candidate
  for candidate in \
    "$CYDER_OGOM/CompatDB/compatdb.cdb" \
    "$CYDER_OGOM/compatdb/compiled/compatdb.cdb"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

cyder_compatdb_is_bundled() {
  local path="$1" candidate
  for candidate in \
    "$CYDER_OGOM/CompatDB/compatdb.cdb" \
    "$CYDER_OGOM/compatdb/compiled/compatdb.cdb"; do
    [[ "$path" == "$candidate" && -f "$candidate" ]] && return 0
  done
  return 1
}

cyder_read_compatdb_pin() {
  local pin="$1" kind path digest actual=""
  [[ -f "$pin" && ! -L "$pin" ]] || return 1
  kind="$(sed -n 's/^kind=//p' "$pin" | head -1)"
  path="$(sed -n 's/^path=//p' "$pin" | head -1)"
  digest="$(sed -n 's/^sha256=//p' "$pin" | head -1)"
  [[ -n "$path" && -f "$path" ]] || return 1

  if [[ "$kind" == bundled ]] && cyder_compatdb_is_bundled "$path"; then
    printf '%s\n' "$path"
    return 0
  fi
  if [[ "$kind" == unsigned &&
        "${CYDER_COMPATDB_ALLOW_UNSIGNED:-0}" == 1 &&
        "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    actual="$(/usr/bin/shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')"
    if [[ "$actual" == "$digest" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  fi
  return 1
}

cyder_write_compatdb_pin() {
  local pin="$1" path="$2" kind=unsigned digest=""
  [[ "$path" != *$'\n'* ]] || return 1
  if cyder_compatdb_is_bundled "$path"; then
    kind=bundled
  else
    [[ "${CYDER_COMPATDB_ALLOW_UNSIGNED:-0}" == 1 ]] || return 1
    digest="$(/usr/bin/shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
  printf 'kind=%s\nsha256=%s\npath=%s\n' "$kind" "$digest" "$path" >"$pin"
}

cyder_export_compatdb_selection() {
  local path="$1" digest=""
  export CYDER_COMPATDB_PATH="$path"
  if cyder_compatdb_is_bundled "$path"; then
    unset CYDER_COMPATDB_SHA256
  else
    digest="$(/usr/bin/shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')"
    if [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
      export CYDER_COMPATDB_SHA256="$digest"
    else
      unset CYDER_COMPATDB_SHA256
    fi
  fi
}

cyder_configure_compatdb() {
  local prefix="${1:-$CYDER_PREFIX}"
  local compatdb="" pin_dir="$prefix/.cyder-runtime" pin="$prefix/.cyder-runtime/compatdb.path"

  if cyder_has_running_prefix "$prefix"; then
    compatdb="$(cyder_read_compatdb_pin "$pin" 2>/dev/null || true)"
    if [[ -n "$compatdb" ]]; then
      cyder_export_compatdb_selection "$compatdb"
      return 0
    fi
    compatdb=""
  fi

  compatdb="$(cyder_resolve_compatdb_path 2>/dev/null || true)"
  if [[ -n "$compatdb" ]]; then
    cyder_export_compatdb_selection "$compatdb"
    if [[ -d "$prefix" && ! -L "$prefix" && ! -L "$pin_dir" ]]; then
      local tmp
      mkdir -p "$pin_dir"
      tmp="$pin.tmp.$$"
      if cyder_write_compatdb_pin "$tmp" "$compatdb"; then
        mv -f "$tmp" "$pin"
      else
        rm -f "$tmp"
      fi
    fi
  else
    unset CYDER_COMPATDB_PATH
    unset CYDER_COMPATDB_SHA256
  fi
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
  # here used to replace Retina=0/DPI=96 with the global Retina preference.
  local keep_msync=0 keep_esync=0 keep_retina=0 keep_dpi=0
  local keep_mingliu=0 keep_songti=0 keep_smoothing=0 keep_power=0 keep_diagnostics=0
  local keep_maplestory_wz_cache=0 keep_wine_locale=0
  case "${CYDER_MSYNC-}" in 0|1) keep_msync=1 ;; esac
  case "${CYDER_ESYNC-}" in 0|1) keep_esync=1 ;; esac
  case "${CYDER_RETINA_MODE-}" in 0|1) keep_retina=1 ;; esac
  if [[ "${CYDER_DPI-}" =~ ^[0-9]+$ ]] && (( CYDER_DPI >= 72 && CYDER_DPI <= 480 )); then keep_dpi=1; fi
  cyder_font_target_is_valid "${CYDER_FONT_MINGLIU_TARGET-}" && keep_mingliu=1
  cyder_font_target_is_valid "${CYDER_FONT_SONGTI_TARGET-}" && keep_songti=1
  case "${CYDER_FONT_PRESET-}" in songti|mingliu)
    [[ "$keep_mingliu" -eq 0 && "$keep_songti" -eq 0 ]] && keep_mingliu=1 && keep_songti=1
    ;;
  esac
  case "${CYDER_FONT_SMOOTHING-}" in off|grayscale|cleartype-rgb|cleartype-bgr) keep_smoothing=1 ;; esac
  case "${CYDER_POWER_MODE-}" in normal|background) keep_power=1 ;; esac
  case "${CYDER_WINE_DIAGNOSTICS-}" in quiet|errors|sync|unwind) keep_diagnostics=1 ;; esac
  case "${CYDER_MAPLESTORY_FILE_CACHE_PREFERENCE-}" in 0|1) keep_maplestory_wz_cache=1 ;; esac
  case "${CYDER_WINE_LOCALE-}" in
    system|zh_TW.UTF-8|zh_TW|ja_JP.UTF-8|ja_JP|ko_KR.UTF-8|ko_KR|en_US.UTF-8|en_US)
      keep_wine_locale=1
      ;;
  esac

  export CYDER_MSYNC="${CYDER_MSYNC:-0}"
  export CYDER_ESYNC="${CYDER_ESYNC:-0}"
  export CYDER_RETINA_MODE="${CYDER_RETINA_MODE:-1}"
  export CYDER_DPI="${CYDER_DPI:-192}"
  export CYDER_FONT_MINGLIU_TARGET="${CYDER_FONT_MINGLIU_TARGET:-$(cyder_detect_default_mingliu_target)}"
  export CYDER_FONT_SONGTI_TARGET="${CYDER_FONT_SONGTI_TARGET:-songti}"
  export CYDER_FONT_SMOOTHING="${CYDER_FONT_SMOOTHING:-cleartype-rgb}"
  export CYDER_POWER_MODE="${CYDER_POWER_MODE:-normal}"
  export CYDER_WINE_DIAGNOSTICS="${CYDER_WINE_DIAGNOSTICS:-quiet}"
  export CYDER_MAPLESTORY_FILE_CACHE_PREFERENCE="${CYDER_MAPLESTORY_FILE_CACHE_PREFERENCE:-1}"
  export CYDER_WINE_LOCALE="${CYDER_WINE_LOCALE:-system}"
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
  if [[ "$keep_mingliu" -eq 0 || "$keep_songti" -eq 0 ]]; then
    cyder_apply_font_targets_from_settings "$settings" "$keep_mingliu" "$keep_songti"
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
  if [[ "$keep_diagnostics" -eq 0 ]]; then
    value="$(plutil -extract wineDiagnostics raw -o - "$settings" 2>/dev/null || true)"
    case "$value" in
      quiet|errors|sync|unwind) export CYDER_WINE_DIAGNOSTICS="$value" ;;
      *) export CYDER_WINE_DIAGNOSTICS=quiet ;;
    esac
  fi
  if [[ "$keep_maplestory_wz_cache" -eq 0 ]]; then
    value="$(plutil -extract maplestoryWZCache raw -o - "$settings" 2>/dev/null || true)"
    case "$value" in
      true|1) export CYDER_MAPLESTORY_FILE_CACHE_PREFERENCE=1 ;;
      false|0) export CYDER_MAPLESTORY_FILE_CACHE_PREFERENCE=0 ;;
    esac
  fi
  if [[ "$keep_wine_locale" -eq 0 ]]; then
    value="$(plutil -extract wineLocale raw -o - "$settings" 2>/dev/null || true)"
    case "$value" in
      zh_TW) export CYDER_WINE_LOCALE=zh_TW.UTF-8 ;;
      ja_JP) export CYDER_WINE_LOCALE=ja_JP.UTF-8 ;;
      ko_KR) export CYDER_WINE_LOCALE=ko_KR.UTF-8 ;;
      en_US) export CYDER_WINE_LOCALE=en_US.UTF-8 ;;
      *) export CYDER_WINE_LOCALE=system ;;
    esac
  fi
  if [[ -z "${CYDER_GRAPHICS_BACKEND:-}" ]]; then
    value="$(plutil -extract graphicsBackend raw -o - "$settings" 2>/dev/null || true)"
    cyder_apply_graphics_preference "${value:-default}" "${CYDER_ENGINES:-}/${CYDER_ENGINE_NAME:-}"
  fi
  value="$(plutil -extract dxvkFrameRate raw -o - "$settings" 2>/dev/null || true)"
  case "$value" in
    sixty|60) export CYDER_DXVK_FRAME_RATE_PREFERENCE=60 ;;
    120|144) export CYDER_DXVK_FRAME_RATE_PREFERENCE="$value" ;;
    unlimited) export CYDER_DXVK_FRAME_RATE_PREFERENCE=unlimited ;;
  esac
  value="$(plutil -extract graphicsHud raw -o - "$settings" 2>/dev/null || true)"
  case "$value" in off|metal|dxvk) export CYDER_GRAPHICS_HUD_PREFERENCE="$value" ;; esac
  value="$(plutil -extract dxvkHudFrametimes raw -o - "$settings" 2>/dev/null || true)"
  case "$value" in
    true|1) export CYDER_DXVK_HUD_FRAMETIMES=1 ;;
    false|0) export CYDER_DXVK_HUD_FRAMETIMES=0 ;;
  esac
  cyder_apply_graphics_runtime_preferences
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
  local bundled_sha="" installed_sha=""

  engine_src="$(cyder_abs_path "$engine_src")"
  bundled_version="$(cyder_bundled_engine_version_from_src "$engine_src" 2>/dev/null || true)"
  if [[ -f "$marker" ]]; then
    installed_version="$(cyder_read_installed_engine_version "$dest" 2>/dev/null || true)"
  fi
  if [[ ! -f "$marker" ]]; then
    return 0
  fi
  if [[ -n "$bundled_version" ]] &&
     ! cyder_engine_versions_equal "$installed_version" "$bundled_version"; then
    return 0
  fi
  bundled_sha="$(cyder_bundled_engine_artifact_sha_from_src "$engine_src" 2>/dev/null || true)"
  if [[ -n "$bundled_sha" ]]; then
    installed_sha="$(cyder_installed_engine_artifact_sha "$dest" 2>/dev/null || true)"
    [[ "$installed_sha" == "$bundled_sha" ]] || return 0
  fi
  return 1
}

# Fast readiness check for direct EXE launches. Do not inspect/decompress the
# bundled archive here; installation and upgrade paths are the only callers
# that need cyder_bundled_engine_version_from_src().
cyder_engine_is_ready_for_launch() {
  local engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  local expected installed expected_sha installed_sha
  cyder_validate_runtime_path || return 1
  [[ -x "$engine/bin/wine" && -f "$CYDER_BOOTSTRAP_MARKER" ]] || return 1
  expected="$(cyder_bundled_engine_version "$CYDER_OGOM" 2>/dev/null || true)"
  installed="$(cyder_read_installed_engine_version "$engine" 2>/dev/null || true)"
  if [[ -n "$expected" ]] && ! cyder_engine_versions_equal "$installed" "$expected"; then
    return 1
  fi
  expected_sha="$(cyder_read_bundled_engine_artifact_sha "$CYDER_OGOM" 2>/dev/null || true)"
  if [[ -n "$expected_sha" ]]; then
    installed_sha="$(cyder_installed_engine_artifact_sha "$engine" 2>/dev/null || true)"
    [[ "$installed_sha" == "$expected_sha" ]] || return 1
  fi
  return 0
}

# Resolve the installed engine without opening the bundled archive when the
# app's sidecar version file already proves that the installed copy is current.
# Explicit/non-bundled engine sources still go through the archive-aware path.
cyder_resolve_shared_engine() {
  local engine_src="$1"
  local engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
  local bundled_src="" expected="" installed="" expected_sha="" installed_sha=""
  engine_src="$(cyder_abs_path "$engine_src")"
  bundled_src="$(cyder_default_engine_src "$CYDER_OGOM" 2>/dev/null || true)"
  if [[ -n "$bundled_src" ]]; then
    bundled_src="$(cyder_abs_path "$bundled_src")"
  fi
  if [[ -n "$bundled_src" && "$engine_src" == "$bundled_src" && -x "$engine/bin/wine" ]]; then
    expected="$(cyder_bundled_engine_version "$CYDER_OGOM" 2>/dev/null || true)"
    installed="$(cyder_read_installed_engine_version "$engine" 2>/dev/null || true)"
    expected_sha="$(cyder_read_bundled_engine_artifact_sha "$CYDER_OGOM" 2>/dev/null || true)"
    installed_sha="$(cyder_installed_engine_artifact_sha "$engine" 2>/dev/null || true)"
    if [[ -n "$expected" ]] && cyder_engine_versions_equal "$installed" "$expected" &&
       { [[ -z "$expected_sha" ]] || [[ "$installed_sha" == "$expected_sha" ]]; }; then
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
  export LANG="$loc" LC_ALL="$loc" LC_CTYPE="$loc"
}

# CrossOver engines ship a Perl wine frontend that refuses to
# run wineboot until $WINEPREFIX/cxbottle.conf exists. Retail Wine builds have
# no share/crossover/bottle_data template, so this is a no-op for them.
cyder_crossover_bottle_data_conf() {
  local wine_bin="$1"
  local engine_root conf
  [[ -n "$wine_bin" && -e "$wine_bin" ]] || return 1
  engine_root="$(cd "$(dirname "$wine_bin")/.." && pwd)"
  conf="$engine_root/share/crossover/bottle_data/cxbottle.conf"
  [[ -f "$conf" ]] || return 1
  printf '%s\n' "$conf"
}

# Seed a private-bottle cxbottle.conf before the first wineboot. CrossOver
# --create is disabled; copying the engine template and injecting WineArch /
# Template matches the CrossOver baseline.
cyder_seed_crossover_bottle_conf() {
  local wine_bin="$1"
  local bottle="$2"
  local base_conf dest
  base_conf="$(cyder_crossover_bottle_data_conf "$wine_bin" 2>/dev/null)" || return 0
  [[ -n "$base_conf" ]] || return 0
  dest="$bottle/cxbottle.conf"
  if [[ -r "$dest" ]]; then
    return 0
  fi
  mkdir -p "$bottle"
  cp "$base_conf" "$dest" || {
    echo "Failed to seed cxbottle.conf from $base_conf" >&2
    return 1
  }
  if ! grep -qE '^[[:space:]]*"WineArch"[[:space:]]*=' "$dest"; then
    /usr/bin/sed -i '' '/^\[Bottle\]$/a\
"WineArch" = "win64"
' "$dest"
  fi
  if ! grep -qE '^[[:space:]]*"Template"[[:space:]]*=' "$dest"; then
    /usr/bin/sed -i '' '/^\[Bottle\]$/a\
"Template" = "win10_64"
' "$dest"
  fi
  echo "Seeded CrossOver bottle metadata: $dest" >&2
}

cyder_wine_is_perl_script() {
  local path="$1" first_line=""
  [[ -f "$path" ]] || return 1
  IFS= read -r first_line <"$path" || true
  [[ "$first_line" == *perl* ]]
}

cyder_is_maplestory_executable() {
  local exe="$1" basename lower
  basename="${exe##*/}"
  lower="$(printf '%s' "$basename" | tr '[:upper:]' '[:lower:]')"
  [[ "$lower" == "maplestory.exe" ]]
}

cyder_apply_maplestory_wz_cache() {
  local exe="$1"
  if cyder_is_maplestory_executable "$exe"; then
    export CYDER_MAPLESTORY_FILE_CACHE="${CYDER_MAPLESTORY_FILE_CACHE_PREFERENCE:-1}"
  else
    export CYDER_MAPLESTORY_FILE_CACHE=0
  fi
}

cyder_wine_is_crossover_frontend() {
  local wine_bin="$1" resolved target engine_root launcher_wine
  [[ -n "$wine_bin" ]] || return 1
  resolved="$wine_bin"
  while [[ -L "$resolved" ]]; do
    target="$(readlink "$resolved")" || break
    if [[ "$target" == /* ]]; then
      resolved="$target"
    else
      resolved="$(cd "$(dirname "$resolved")" && pwd)/$target"
    fi
  done
  cyder_wine_is_perl_script "$resolved" && return 0
  engine_root="$(cd "$(dirname "$resolved")/.." 2>/dev/null && pwd)" || return 1
  launcher_wine="$engine_root/MapleStory Launcher/wine"
  cyder_wine_is_perl_script "$launcher_wine" && return 0
  return 1
}

# Locate a user-provided GPTK without redistributing it in Cyder.app. A copy
# installed from the Settings UI wins over CrossOver's bundled copy.
cyder_gptk_root_is_valid() {
  local root="$1"
  [[ -r "$root/external/libd3dshared.dylib" && -d "$root/external/D3DMetal.framework" ]]
}

cyder_preferred_gptk_root() {
  local installed="$CYDER_SUPPORT/runtime/apple_gptk"
  local crossover="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk"
  if cyder_gptk_root_is_valid "$installed"; then
    printf '%s\n' "$installed"
    return 0
  fi
  if cyder_gptk_root_is_valid "$crossover"; then
    printf '%s\n' "$crossover"
    return 0
  fi
  return 1
}

cyder_link_gptk_into_engine() {
  local engine_root="$1" gptk_root="$2"
  local lib64="$engine_root/lib64" link="$engine_root/lib64/apple_gptk"
  cyder_gptk_root_is_valid "$gptk_root" || return 1
  if [[ -L "$link" ]]; then
    local resolved
    resolved="$(cd "$(dirname "$link")" && cd "$(readlink "$link")" 2>/dev/null && pwd -P || true)"
    [[ "$resolved" == "$(cd "$gptk_root" && pwd -P)" ]] && return 0
    rm -f "$link"
  elif [[ -e "$link" ]]; then
    cyder_gptk_root_is_valid "$link"
    return $?
  fi
  mkdir -p "$lib64"
  ln -s "$gptk_root" "$link"
  cyder_gptk_root_is_valid "$link"
}

cyder_apply_gptk_launch_environment() {
  local engine_root="$1" gptk_root=""
  # Do not retain stale paths inherited from a parent process when GPTK was
  # removed or moved since the previous launch.
  unset CYDER_GPTK_ROOT CX_APPLEGPTK_LIBD3DSHARED_PATH
  gptk_root="$(cyder_preferred_gptk_root 2>/dev/null || true)"
  [[ -n "$gptk_root" ]] || return 0
  export CYDER_GPTK_ROOT="$gptk_root"
  export CX_APPLEGPTK_LIBD3DSHARED_PATH="$gptk_root/external/libd3dshared.dylib"
  if [[ -n "${DYLD_FRAMEWORK_PATH:-}" ]]; then
    export DYLD_FRAMEWORK_PATH="$gptk_root/external:$DYLD_FRAMEWORK_PATH"
  else
    export DYLD_FRAMEWORK_PATH="$gptk_root/external"
  fi
  cyder_link_gptk_into_engine "$engine_root" "$gptk_root" || {
    echo "Unable to link the selected GPTK into the Wine engine." >&2
    return 1
  }
}

# CrossOver's Perl frontend reloads [EnvironmentVariables] after the process
# environment. Mirror Cyder's graphics choices so cxbottle.conf cannot clear or
# replace the values selected for this launch.
cyder_sync_crossover_graphics_environment() {
  local prefix="$1" conf="$1/cxbottle.conf"
  [[ -f "$conf" && ! -L "$conf" ]] || return 0
  local tmp="${conf}.cyder-graphics.$$"
  /usr/bin/awk \
    -v backend="${CX_GRAPHICS_BACKEND:-}" \
    -v frame_rate="${DXVK_FRAME_RATE:-}" \
    -v dxvk_hud="${DXVK_HUD:-}" \
    -v metal_hud="${MTL_HUD_ENABLED:-}" \
    -v dxmt_config="${DXMT_CONFIG:-}" '
    function emit() {
      if (backend != "") print "\"CX_GRAPHICS_BACKEND\" = \"" backend "\""
      if (frame_rate != "") print "\"DXVK_FRAME_RATE\" = \"" frame_rate "\""
      if (dxvk_hud != "") print "\"DXVK_HUD\" = \"" dxvk_hud "\""
      if (metal_hud != "") print "\"MTL_HUD_ENABLED\" = \"" metal_hud "\""
      if (dxmt_config != "") print "\"DXMT_CONFIG\" = \"" dxmt_config "\""
    }
    BEGIN { in_environment = 0; found = 0 }
    /^\[EnvironmentVariables\]$/ {
      print
      emit()
      in_environment = 1
      found = 1
      next
    }
    /^\[/ { in_environment = 0 }
    in_environment && /^"(CX_GRAPHICS_BACKEND|DXVK_FRAME_RATE|DXVK_HUD|MTL_HUD_ENABLED|DXMT_CONFIG)"[[:space:]]*=/ { next }
    { print }
    END {
      if (!found) {
        print ""
        print "[EnvironmentVariables]"
        emit()
      }
    }
  ' "$conf" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  # cxbottle.conf contains launch preferences rather than credentials. Keep a
  # predictable mode with the BSD chmod shipped on every supported macOS.
  chmod 644 "$tmp"
  mv -f "$tmp" "$conf"
}

cyder_wine_frontend_args() {
  local wine_bin="${1:-}"
  local dll_overrides="${2:-${CYDER_WINE_DLL_OVERRIDES:-}}"
  local -a args=()
  if [[ -n "${CYDER_WINE_FRONTEND_ARGS:-}" ]]; then
    read -r -a args <<<"${CYDER_WINE_FRONTEND_ARGS}"
  elif cyder_wine_is_crossover_frontend "$wine_bin"; then
    args=(--wait-children --enable-alt-loader macdrv)
  fi
  if [[ -n "$dll_overrides" ]]; then
    local has_dll=0 arg
    for arg in "${args[@]}"; do
      [[ "$arg" == --dll ]] && has_dll=1 && break
    done
    if (( ! has_dll )); then
      args=(--dll "$dll_overrides" "${args[@]}")
    fi
  fi
  if ((${#args[@]})); then
    printf '%s\n' "${args[*]}"
  fi
  return 0
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

cyder_resolve_msi_from_args() {
  local a p ext
  for a in "$@"; do
    p="$(cyder_abs_path "$a")"
    ext="$(echo "${p##*.}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ext" == "msi" && -f "$p" ]]; then
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

# Optional macOS compatibility helpers (version compare and MoltenVK OS floor).
if [[ -n "${CYDER_SCRIPTS:-}" && -f "$CYDER_SCRIPTS/cyder-macos-compat.sh" ]]; then
  # shellcheck source=cyder-macos-compat.sh
  source "$CYDER_SCRIPTS/cyder-macos-compat.sh"
elif [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cyder-macos-compat.sh" ]]; then
  # shellcheck source=cyder-macos-compat.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cyder-macos-compat.sh"
fi

# UI-facing progress for long bootstrap/provision work. Written atomically so
# the Swift UI can update while the launcher runs.
# Usage: cyder_report_progress "label" [stage] [elapsed_ms]
# Writes a structured progress file when CYDER_PROGRESS_FILE is set:
#   stage=<id>
#   label=<message>
#   elapsed_ms=<n>
# stderr still prints the human label for CLI visibility. Plain single-arg
# callers remain supported (stage=general).
cyder_report_progress() {
  local message="$1"
  local stage="${2:-general}"
  local elapsed_ms="${3:-0}"
  echo "$message" >&2
  [[ -n "${CYDER_PROGRESS_FILE:-}" ]] || return 0
  local dir tmp
  dir="$(dirname "$CYDER_PROGRESS_FILE")"
  mkdir -p "$dir"
  tmp="$CYDER_PROGRESS_FILE.tmp.$$"
  {
    printf 'stage=%s\n' "$stage"
    printf 'label=%s\n' "$message"
    printf 'elapsed_ms=%s\n' "$elapsed_ms"
  } >"$tmp"
  mv -f "$tmp" "$CYDER_PROGRESS_FILE"
}

cyder_now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    awk -v t="$EPOCHREALTIME" 'BEGIN { printf "%d\n", t * 1000 }'
  else
    python3 -c 'import time; print(int(time.time() * 1000))'
  fi
}

cyder_bootstrap_timing_file() {
  if [[ -n "${CYDER_BOOTSTRAP_TIMING_FILE:-}" ]]; then
    printf '%s\n' "$CYDER_BOOTSTRAP_TIMING_FILE"
    return 0
  fi
  if [[ -n "${CYDER_SUPPORT:-}" ]]; then
    printf '%s\n' "$CYDER_SUPPORT/Logs/bootstrap-timing.jsonl"
    return 0
  fi
  return 1
}

cyder_bootstrap_substage_record() {
  local stage="$1" elapsed_ms="$2" status="$3"
  if [[ -n "${CYDER_DIAGNOSTIC_SESSION_ID:-}" || "${CYDER_DIAGNOSTIC_VERBOSE:-0}" == 1 ]]; then
    printf 'diagnostic event=bootstrap-substage session=%s stage=%s phase=end elapsed_ms=%s status=%s\n' \
      "${CYDER_DIAGNOSTIC_SESSION_ID:-cli}" "$stage" "$elapsed_ms" "$status" >&2
  fi
  local timing_file
  timing_file="$(cyder_bootstrap_timing_file 2>/dev/null)" || return 0
  local dir
  dir="$(dirname "$timing_file")"
  mkdir -p "$dir"
  printf '{"stage":"%s","elapsed_ms":%s,"status":%s,"session":"%s"}\n' \
    "$stage" "$elapsed_ms" "$status" "${CYDER_DIAGNOSTIC_SESSION_ID:-}" >>"$timing_file"
}

# Background jobs write "status end_ms" to a stamp when they finish so elapsed
# is not inflated by waiting until wineboot/reap.
cyder_bg_job_elapsed_ms() {
  local t0="$1" stamp="$2"
  local status_field end_ms now
  now="$(cyder_now_ms)"
  end_ms="$now"
  if [[ -f "$stamp" ]]; then
    read -r status_field end_ms <"$stamp" || true
  fi
  if [[ ! "$end_ms" =~ ^[0-9]+$ ]]; then
    end_ms="$now"
  fi
  if [[ "$t0" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((end_ms - t0))"
  else
    printf '0\n'
  fi
}

cyder_bg_job_status_from_stamp() {
  local stamp="$1" fallback="${2:-1}"
  local status_field end_ms
  if [[ -f "$stamp" ]]; then
    read -r status_field end_ms <"$stamp" || true
    if [[ "$status_field" =~ ^-?[0-9]+$ ]]; then
      printf '%s\n' "$status_field"
      return 0
    fi
  fi
  printf '%s\n' "$fallback"
}

cyder_bootstrap_substage_begin() {
  local stage="$1"
  CYDER_BOOTSTRAP_STAGE_STACK+=("$stage")
  CYDER_BOOTSTRAP_T0_STACK+=("$(cyder_now_ms)")
  cyder_diagnostic_stage "$stage"
  if [[ -n "${CYDER_DIAGNOSTIC_SESSION_ID:-}" || "${CYDER_DIAGNOSTIC_VERBOSE:-0}" == 1 ]]; then
    printf 'diagnostic event=bootstrap-substage session=%s stage=%s phase=begin\n' \
      "${CYDER_DIAGNOSTIC_SESSION_ID:-cli}" "$stage" >&2
  fi
}

cyder_bootstrap_substage_end() {
  local stage="$1" substage_status="${2:-0}"
  local stack_len="${#CYDER_BOOTSTRAP_STAGE_STACK[@]}"
  (( stack_len > 0 )) || return 0
  local top_idx=$((stack_len - 1))
  local active="${CYDER_BOOTSTRAP_STAGE_STACK[$top_idx]}"
  if [[ "$active" != "$stage" ]]; then
    echo "bootstrap substage end mismatch: expected $active got $stage" >&2
  fi
  local t0="${CYDER_BOOTSTRAP_T0_STACK[$top_idx]}"
  local now elapsed_ms=0
  now="$(cyder_now_ms)"
  if [[ "$now" =~ ^[0-9]+$ && "$t0" =~ ^[0-9]+$ ]]; then
    elapsed_ms=$((now - t0))
  fi
  if (( stack_len == 1 )); then
    CYDER_BOOTSTRAP_STAGE_STACK=()
    CYDER_BOOTSTRAP_T0_STACK=()
  else
    unset "CYDER_BOOTSTRAP_STAGE_STACK[$top_idx]"
    unset "CYDER_BOOTSTRAP_T0_STACK[$top_idx]"
    CYDER_BOOTSTRAP_STAGE_STACK=("${CYDER_BOOTSTRAP_STAGE_STACK[@]}")
    CYDER_BOOTSTRAP_T0_STACK=("${CYDER_BOOTSTRAP_T0_STACK[@]}")
  fi
  cyder_bootstrap_substage_record "$stage" "$elapsed_ms" "$substage_status"
}

# Lightweight post-provision check: confirm the bottle looks complete without
# starting another Wine process (the GUI skips a second probe when
# CYDER_BOOTSTRAP_HEALTH_CHECKED=1).
cyder_verify_prefix_baseline_artifacts() {
  local prefix="$1"
  [[ -f "$prefix/system.reg" && -f "$prefix/user.reg" ]] || {
    echo "prefix registry files are missing: $prefix" >&2
    return 1
  }
  [[ -f "$prefix/drive_c/windows/system32/kernel32.dll" || \
     -f "$prefix/drive_c/windows/syswow64/kernel32.dll" ]] || {
    echo "prefix kernel32.dll is missing: $prefix" >&2
    return 1
  }
  [[ -f "$prefix/.cyder-golden-baseline-v2" ]] || {
    echo "prefix golden baseline marker is missing: $prefix" >&2
    return 1
  }
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
  local -a candidates=("${CYDER_ZSTD:-}")
  [[ -n "${CYDER_OGOM:-}" ]] && candidates+=("$CYDER_OGOM/tools/zstd/zstd")
  candidates+=(
    "$CYDER_COMMON_DIR/../tools/zstd/zstd"
    "$(command -v zstd 2>/dev/null || true)"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)" "$(basename "$candidate")"
      return 0
    fi
  done
  return 1
}

cyder_find_cabextract() {
  local candidate
  local -a candidates=("${CYDER_CABEXTRACT:-}")
  [[ -n "${CYDER_OGOM:-}" ]] && candidates+=("$CYDER_OGOM/tools/cabextract/cabextract")
  candidates+=(
    "$CYDER_COMMON_DIR/../tools/cabextract/cabextract"
    "/opt/homebrew/bin/cabextract"
    "/usr/local/bin/cabextract"
    "$(command -v cabextract 2>/dev/null || true)"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" && -f "$candidate" ]]; then
      printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)" "$(basename "$candidate")"
      return 0
    fi
  done
  return 1
}


cyder_tar_extract() {
  local tarball="$1"
  local dest_dir="$2"
  local err_file rc zstd_bin pipe_status
  err_file="$(mktemp "${TMPDIR:-/tmp}/cyder-tar-err.XXXXXX")"
  if [[ "$tarball" == *.tar.xz ]]; then
    tar -xJf "$tarball" -C "$dest_dir" 2>"$err_file"
    rc=$?
  elif [[ "$tarball" == *.tar.zst ]] && zstd_bin="$(cyder_find_zstd 2>/dev/null || true)"; then
    cyder_log_engine "extract via zstd pipe: $zstd_bin"
    set +o pipefail
    "$zstd_bin" -d -c "$tarball" 2>"$err_file" | tar -xf - -C "$dest_dir" 2>>"$err_file"
    pipe_status=("${PIPESTATUS[@]}")
    rc=${pipe_status[1]}
    if [[ ${pipe_status[0]} -ne 0 ]]; then
      rc=${pipe_status[0]}
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

cyder_engine_signature_intact() {
  local dest="$1"
  local target="$dest/bin/wine"
  if [[ ! -f "$target" ]] || ! /usr/bin/file -b "$target" 2>/dev/null | grep -q 'Mach-O'; then
    target="$dest/bin/wineloader"
  fi
  [[ -f "$target" ]] || return 1
  /usr/bin/codesign --verify --strict "$target" >/dev/null 2>&1
}

cyder_sign_installed_engine() {
  local dest="$1"
  local sign_sh="$CYDER_SCRIPTS/sign-wine.sh"
  local env_sh="$CYDER_SCRIPTS/env-x86_64.sh"
  # Packaged artifacts are already signed; re-signing every Mach-O on first
  # install is the dominant cost of "準備遊戲執行元件".
  if cyder_engine_signature_intact "$dest"; then
    echo "Shared engine signatures intact; skipping resign: $dest" >&2
    printf 'signed\n' >"$dest/.cyder-engine-signed"
    return 0
  fi
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
  local bundled_sha="" installed_sha="" same_version=0
  engine_src="$(cyder_abs_path "$engine_src")"
  cyder_migrate_legacy_layout || exit 1

  bundled_version="$(cyder_bundled_engine_version_from_src "$engine_src" 2>/dev/null || true)"
  bundled_sha="$(cyder_bundled_engine_artifact_sha_from_src "$engine_src" 2>/dev/null || true)"
  if [[ -f "$marker" ]]; then
    installed_version="$(cyder_read_installed_engine_version "$dest" 2>/dev/null || true)"
    installed_sha="$(cyder_installed_engine_artifact_sha "$dest" 2>/dev/null || true)"
    if [[ -n "$bundled_version" ]] &&
       cyder_engine_versions_equal "$installed_version" "$bundled_version"; then
      same_version=1
    fi
    if [[ -z "$bundled_version" ]] ||
       { [[ "$same_version" -eq 1 ]] &&
         { [[ -z "$bundled_sha" ]] || [[ "$installed_sha" == "$bundled_sha" ]]; }; }; then
      echo "Shared engine present: $dest" >&2
      if [[ ! -f "$dest/.cyder-engine-signed" ]]; then
        cyder_sign_installed_engine "$dest" || exit 1
      fi
      echo "$dest"
      return 0
    fi
    if [[ "$same_version" -eq 1 ]]; then
      echo "Refreshing shared engine artifact ($bundled_version) -> $dest" >&2
    else
      echo "Upgrading shared engine ($installed_version -> $bundled_version) -> $dest" >&2
      cyder_invalidate_shared_bootstrap_for_engine_upgrade
    fi
  else
    echo "Installing shared engine -> $dest" >&2
    if [[ -n "$bundled_version" && -e "$CYDER_SHARED_PREFIX" ]]; then
      if [[ -z "$CYDER_MIGRATED_ENGINE_VERSION" ]] ||
         ! cyder_engine_versions_equal "$CYDER_MIGRATED_ENGINE_VERSION" "$bundled_version"; then
        cyder_invalidate_shared_bootstrap_for_engine_upgrade
      fi
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
  if [[ -n "$bundled_sha" ]]; then
    printf '%s\n' "$bundled_sha" >"$dest/.cyder-engine-artifact-sha256"
  fi
  echo "$dest"
}

cyder_init_bottle() {
  local wine_bin="$1"
  local bottle="$2"
  CYDER_OPERATION_ERROR_KIND=""
  CYDER_OPERATION_ERROR_CODE=""
  export CYDER_OPERATION_ERROR_KIND CYDER_OPERATION_ERROR_CODE
  local wineserver="${wine_bin%/wine}/wineserver"
  # Empty prefix: wineboot -i (faster cold init). Existing prefix: -u (engine upgrade).
  local wineboot_flag="-i"
  local wineboot_reason="create"
  if [[ -f "$bottle/system.reg" ]]; then
    # Prefer Preferences → 重建 Windows if the prefix is too broken to salvage.
    cyder_seed_crossover_bottle_conf "$wine_bin" "$bottle" || return $?
    echo "Updating bottle: $bottle" >&2
    wineboot_flag="-u"
    wineboot_reason="update"
  else
    echo "Creating bottle: $bottle" >&2
    mkdir -p "$bottle"
    # CrossOver Perl wine requires cxbottle.conf before wineboot.
    cyder_seed_crossover_bottle_conf "$wine_bin" "$bottle" || return $?
  fi
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
    echo "wineboot_flag=$wineboot_flag"
    echo "wineboot_reason=$wineboot_reason"
    echo "wine=$wine_bin"
    echo "prefix=$bottle"
    echo "engine_version=$engine_version"
    echo "os_version=$os_version"
    echo "cpu_arch=$cpu_arch"
    echo "started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
  } >>"$log_file"
  ln -sfn "operations/$(basename "$log_file")" "$CYDER_SUPPORT/Logs/last-wineboot.log"
  local status=0 timed_out=0 wineboot_t0_ms
  wineboot_t0_ms="$(cyder_now_ms)"
  local timeout="${CYDER_WINEBOOT_TIMEOUT:-120}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=120
  (( timeout > 0 )) || timeout=1
  local crossover_bottle=0
  if [[ -r "$bottle/cxbottle.conf" ]]; then
    crossover_bottle=1
  fi
  # Run wineboot asynchronously so a hung Wine process cannot leave Cyder's
  # first-launch preparation dialog open forever. The timeout is deliberately
  # implemented with Bash primitives; macOS does not ship GNU timeout.
  (
    cyder_wine_locale_exports
    export WINEPREFIX="$bottle" WINESERVER="$wineserver"
    # Point CX_BOTTLE at this prefix (including rebuild staging dirs). An outer
    # CX_BOTTLE aimed at an empty shared/ would make OEM wine look for conf
    # there and fail before wineboot.
    if (( crossover_bottle )); then
      export CX_BOTTLE="$bottle" WINEARCH="${WINEARCH:-win64}"
    fi
    # Build the base prefix deterministically. Wine may otherwise discover
    # cached Mono/Gecko installers and modify "pristine" during wineboot.
    # Golden installs the pinned, checksummed versions explicitly afterwards.
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
    cyder_run arch -x86_64 "$wine_bin" wineboot "$wineboot_flag" >>"$log_file" 2>&1
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
  # wineboot returns while wineserver is still in its short idle window (~3s).
  # Do not wait for wineserver exit or force -p; poll only on-disk wineboot
  # artifacts (drive_c + kernel32). system.reg/user.reg may flush later when
  # baseline verify stops the server.
  if (( status == 0 )); then
    local artifact_wait_timeout="${CYDER_WINESERVER_WAIT_TIMEOUT:-30}"
    [[ "$artifact_wait_timeout" =~ ^[0-9]+$ ]] || artifact_wait_timeout=30
    (( artifact_wait_timeout > 0 )) || artifact_wait_timeout=1
    local artifact_deadline=$((SECONDS + artifact_wait_timeout))
    local missing=()
    echo "success_wait=artifact-ready" >>"$log_file"
    cyder_bootstrap_substage_begin wineboot-artifact-wait
    while true; do
      missing=()
      [[ -d "$bottle/drive_c" ]] || missing+=(drive_c)
      [[ -f "$bottle/drive_c/windows/system32/kernel32.dll" || \
         -f "$bottle/drive_c/windows/syswow64/kernel32.dll" ]] || missing+=(kernel32.dll)
      if (( ${#missing[@]} == 0 )); then
        cyder_bootstrap_substage_end wineboot-artifact-wait 0
        break
      fi
      if (( SECONDS >= artifact_deadline )); then
        status=125
        CYDER_OPERATION_ERROR_KIND=artifact-missing
        CYDER_OPERATION_ERROR_CODE=CYD-WINEBOOT-ARTIFACT
        echo "missing_artifacts=${missing[*]}" >>"$log_file"
        cyder_bootstrap_substage_end wineboot-artifact-wait "$status"
        break
      fi
      sleep 0.1
    done
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
  local wineboot_duration_ms=0 wineboot_finished_ms
  wineboot_finished_ms="$(cyder_now_ms)"
  if [[ "$wineboot_finished_ms" =~ ^[0-9]+$ && "$wineboot_t0_ms" =~ ^[0-9]+$ ]]; then
    wineboot_duration_ms=$((wineboot_finished_ms - wineboot_t0_ms))
  fi
  echo "finished=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$log_file"
  echo "duration_ms=$wineboot_duration_ms" >>"$log_file"
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
  # Leave wineserver running after wineboot so later baseline steps (tar /
  # golden registry) can reuse it; cyder_verify_prefix_baseline_artifacts
  # stops it and flushes .reg.
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
  local parent active_prefix
  active_prefix="$CYDER_SHARED_PREFIX"
  parent="$(dirname "$active_prefix")"
  # Rebuild deliberately deletes the active bottle before provisioning. This
  # prevents stale CrossOver metadata or registry state from surviving.
  [[ ! -L "$active_prefix" ]] || {
    echo "Cannot rebuild a symlinked shared prefix: $active_prefix" >&2
    return 2
  }
  mkdir -p "$parent"
  # Ensure no wineserver holds files open under the bottle we are about to remove.
  cyder_stop_prefix_wineserver "$wine_bin" "$active_prefix" || true

  if [[ -e "$active_prefix" || -L "$active_prefix" ]]; then
    if ! cyder_remove_path "$active_prefix"; then
      echo "Prefix rebuild failed while deleting the active bottle: $active_prefix" >&2
      return 1
    fi
  fi
  echo "Rebuilding bottle from scratch: $active_prefix" >&2
  if ! cyder_provision_prefix_baseline "$wine_bin" "$engine_root" "$active_prefix"; then
    cyder_remove_path "$active_prefix"
    echo "Prefix rebuild failed while provisioning; no bottle remains." >&2
    return 1
  fi
  printf 'revision=%s\n' "${CYDER_TEMPLATE_REVISION:-1}" >"$CYDER_BOOTSTRAP_MARKER"
  echo "Prefix rebuild completed: $active_prefix" >&2
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

# Provision any Wine prefix with the current-engine baseline: wineboot,
# libarchive, and golden registry settings. Wine Mono / Gecko are left to
# Wine's own addon dialogs (mscoree / mshtml) when an app first needs them.
# Pre-1.0.0 shared/profile bottles use this directly; template publish/clone
# is deferred until 1.0.0.
cyder_provision_prefix_baseline() {
  local wine_bin="$1" engine_root="$2" prefix="$3"
  local component_status=0
  CYDER_BOOTSTRAP_HEALTH_CHECKED=0
  CYDER_BOOTSTRAP_STAGE_STACK=()
  CYDER_BOOTSTRAP_T0_STACK=()
  CYDER_PROVISION_DID_GRAPHICS=0

  local gfx_payload_pid="" gfx_payload_t0=0 gfx_payload_status=0
  local gfx_payload_log="" gfx_payload_stamp
  local dl_elapsed=0
  local log_dir="${CYDER_SUPPORT:-}/Logs"
  [[ -n "${CYDER_SUPPORT:-}" ]] && mkdir -p "$log_dir"
  gfx_payload_log="${log_dir:-/tmp}/graphics-payload-$$.log"
  gfx_payload_stamp="${gfx_payload_log}.stamp"

  cyder_provision_kill_downloads() {
    local pid
    for pid in "$gfx_payload_pid"; do
      [[ -n "$pid" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.2
    for pid in "$gfx_payload_pid"; do
      [[ -n "$pid" ]] || continue
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  }

  # DXVK/DXMT payload unpack does not need a bottle; overlap with wineboot.
  if declare -F cyder_install_graphics_payload >/dev/null 2>&1 &&
     declare -F cyder_graphics_source_dir >/dev/null 2>&1 &&
     cyder_graphics_source_dir >/dev/null 2>&1; then
    if [[ -n "${CYDER_DIAGNOSTIC_SESSION_ID:-}" || "${CYDER_DIAGNOSTIC_VERBOSE:-0}" == 1 ]]; then
      printf 'diagnostic event=bootstrap-substage session=%s stage=%s phase=begin\n' \
        "${CYDER_DIAGNOSTIC_SESSION_ID:-cli}" "graphics-payload" >&2
    fi
    gfx_payload_t0="$(cyder_now_ms)"
    rm -f "$gfx_payload_stamp"
    (
      set +e
      (
        set -euo pipefail
        source_dir="$(cyder_graphics_source_dir)"
        runtime_root="${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}"
        cyder_install_graphics_payload "$source_dir" "$runtime_root" dxvk
        cyder_install_graphics_payload "$source_dir" "$runtime_root" dxmt
      ) >"$gfx_payload_log" 2>&1
      status=$?
      printf '%s %s\n' "$status" "$(cyder_now_ms)" >"$gfx_payload_stamp"
      exit "$status"
    ) &
    gfx_payload_pid=$!
  fi

  cyder_report_progress "正在建立 Windows 環境…" "wineboot"
  cyder_bootstrap_substage_begin wineboot
  cyder_init_bottle "$wine_bin" "$prefix" || {
    component_status=$?
    cyder_bootstrap_substage_end wineboot "$component_status"
    cyder_provision_kill_downloads
    return "$component_status"
  }
  cyder_bootstrap_substage_end wineboot 0

  if [[ -f "$CYDER_SCRIPTS/install-libarchive-tar.sh" ]]; then
    if [[ -f "$prefix/drive_c/windows/syswow64/tar.exe" ]]; then
      cyder_report_progress "tar 解壓工具已就緒，略過安裝…" "tar-setup"
      cyder_bootstrap_substage_begin tar-setup
      cyder_bootstrap_substage_end tar-setup 0
    else
      cyder_report_progress "正在安裝 tar 解壓工具…" "tar-setup"
      cyder_bootstrap_substage_begin tar-setup
      (
        export WINEPREFIX="$prefix" WINE_INSTALL="$engine_root"
        export OGOM="${CYDER_OGOM:-${OGOM:-}}"
        export CYDER_LIBARCHIVE_SRC="${CYDER_LIBARCHIVE_SRC:-$(cyder_resolve_libarchive_src)}"
        bash "$CYDER_SCRIPTS/install-libarchive-tar.sh" --prefix "$prefix"
      ) || component_status=$?
      cyder_bootstrap_substage_end tar-setup "$component_status"
      (( component_status == 0 )) || return "$component_status"
    fi
  fi

  if [[ -f "$CYDER_SCRIPTS/cyder-apply-golden-settings.sh" ]]; then
    if [[ -f "$prefix/.cyder-golden-baseline-v2" ]]; then
      cyder_report_progress "預設設定已就緒，略過套用…" "golden-setup"
      cyder_bootstrap_substage_begin golden-setup
      cyder_bootstrap_substage_end golden-setup 0
    else
      cyder_report_progress "正在套用預設設定…" "golden-setup"
      cyder_bootstrap_substage_begin golden-setup
      (
        export WINEPREFIX="$prefix" WINE_INSTALL="$engine_root"
        bash "$CYDER_SCRIPTS/cyder-apply-golden-settings.sh"
      ) || component_status=$?
      cyder_bootstrap_substage_end golden-setup "$component_status"
      (( component_status == 0 )) || return "$component_status"
    fi
  fi

  cyder_report_progress "正在確認環境…" "verify"
  cyder_bootstrap_substage_begin verify
  cyder_stop_prefix_wineserver "$wine_bin" "$prefix" || component_status=$?
  # Skip a full wine cmd probe here: wineboot + component installs already
  # exercised the prefix. Artifact checks are enough; Cyder.app will not run a
  # second probe when healthChecked=1 is returned from bootstrap.
  if ! cyder_verify_prefix_baseline_artifacts "$prefix"; then
    echo "Baseline provision artifact check failed: $prefix" >&2
    component_status=1
  fi
  cyder_bootstrap_substage_end verify "$component_status"
  (( component_status == 0 )) || return "$component_status"

  if [[ -n "$gfx_payload_pid" ]]; then
    wait "$gfx_payload_pid" || true
    gfx_payload_status="$(cyder_bg_job_status_from_stamp "$gfx_payload_stamp" "1")"
    dl_elapsed="$(cyder_bg_job_elapsed_ms "$gfx_payload_t0" "$gfx_payload_stamp")"
    cyder_bootstrap_substage_record graphics-payload "$dl_elapsed" "$gfx_payload_status"
    gfx_payload_pid=""
    if (( gfx_payload_status != 0 )); then
      echo "Graphics payload unpack failed (see $gfx_payload_log)" >&2
      return "$gfx_payload_status"
    fi
  fi

  if declare -F cyder_graphics_link_engine_and_winemetal >/dev/null 2>&1 &&
     declare -F cyder_graphics_source_dir >/dev/null 2>&1 &&
     cyder_graphics_source_dir >/dev/null 2>&1; then
    cyder_report_progress "正在準備圖形元件…" "graphics-winemetal"
    cyder_bootstrap_substage_begin graphics-winemetal
    cyder_graphics_link_engine_and_winemetal \
      "${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}" \
      "${CYDER_ENGINES:-${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}/Engines}" \
      "$prefix" || component_status=$?
    cyder_bootstrap_substage_end graphics-winemetal "$component_status"
    (( component_status == 0 )) || return "$component_status"
    CYDER_PROVISION_DID_GRAPHICS=1
  fi

  CYDER_BOOTSTRAP_HEALTH_CHECKED=1
}

# Deprecated until 1.0.0 template bottles return. Kept for tests/helpers only;
# production bootstrap no longer publishes or clones these.
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

# Deprecated until 1.0.0. Prefer cyder_provision_prefix_baseline.
cyder_prepare_golden_template() {
  local wine_bin="$1" engine_root="$2"
  cyder_profile_backend_load || return $?
  local revision="${CYDER_TEMPLATE_REVISION:-2}"
  local engine_version
  engine_version="$(cyder_template_engine_version "$wine_bin")"
  cyder_profile_init_layout "$CYDER_SUPPORT"
  local golden="$CYDER_SUPPORT/templates/golden"
  if cyder_profile_template_ready golden "$CYDER_SUPPORT" "$revision" "$engine_version" \
      && [[ -f "$golden/.cyder-golden-baseline-v2" ]]; then
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

  if ! cyder_provision_prefix_baseline "$wine_bin" "$engine_root" "$staging"; then
    echo "Golden staging failed and was retained for diagnostics: $staging" >&2
    return 1
  fi
  if ! cyder_profile_publish_template "$staging" golden "$CYDER_SUPPORT" \
      "$revision" "$engine_version"; then
    echo "Failed to publish Golden template; staging retained: $staging" >&2
    return 1
  fi
  rm -rf "$staging"
}

# Deprecated until 1.0.0. Prefer cyder_provision_prefix_baseline into shared.
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

# Create or resolve a per-game bottle by provisioning a fresh baseline for the
# current engine (no template clone). Metadata still records baseTemplate as
# golden for schema compatibility until 1.0.0.
cyder_create_profile_prefix() {
  local wine_bin="$1" engine_root="$2" exe_path="$3"
  local base_template="${4:-golden}"
  cyder_profile_backend_load || return $?
  [[ -f "$exe_path" ]] || { echo "EXE does not exist: $exe_path" >&2; return 1; }
  [[ "$base_template" == pristine || "$base_template" == golden || "$base_template" == recommended ]] || {
    echo "template must be pristine, golden, or recommended: $base_template" >&2
    return 1
  }
  cyder_profile_init_layout "$CYDER_SUPPORT"
  local id bottle profile canonical
  id="$(cyder_profile_id_for_path "$exe_path")"
  bottle="$CYDER_SUPPORT/bottles/$id"
  profile="$CYDER_SUPPORT/profiles/$id"
  canonical="$(cyder_profile_canonical_path "$exe_path")"
  [[ ! -L "$profile" && ! -L "$bottle" ]] || {
    echo "profile or bottle symlink is not allowed: $id" >&2
    return 1
  }
  if [[ -f "$profile/profile.json" && -d "$bottle" ]]; then
    cyder_profile_resolve "$exe_path" "$CYDER_SUPPORT" >/dev/null || return 1
    printf '%s\n' "$bottle"
    return 0
  fi
  [[ ! -e "$bottle" && ! -e "$profile" ]] || {
    echo "incomplete profile already exists: $id" >&2
    return 1
  }
  if ! cyder_provision_prefix_baseline "$wine_bin" "$engine_root" "$bottle"; then
    cyder_remove_path "$bottle"
    echo "Profile bottle provision failed: $bottle" >&2
    return 1
  fi
  # Profile bottles are provisioned independently from the shared prefix. Keep
  # the DXMT winemetal PE in sync here as well, so a newly-created profile can
  # use the same runtime backend on its first launch.
  if declare -F cyder_graphics_source_dir >/dev/null 2>&1 &&
     cyder_graphics_source_dir >/dev/null 2>&1; then
    cyder_ensure_graphics "$bottle" || {
      cyder_remove_path "$bottle"
      echo "Profile graphics payload setup failed: $bottle" >&2
      return 1
    }
  fi
  if ! mkdir "$profile" || ! cyder_profile_write_metadata "$profile" "$id" "$canonical" "$base_template"; then
    cyder_remove_path "$bottle"
    cyder_remove_path "$profile"
    echo "profile metadata publish failed; profile rolled back" >&2
    return 1
  fi
  printf '%s\n' "$bottle"
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
# Finder associations and the internal shell launch path receive the same
# per-game settings.
CYDER_GAME_ARGUMENTS=()
CYDER_GAME_SETTINGS_FOUND=0

cyder_game_environment_key_is_allowed() {
  local key="$1"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "$key" in
    BASH_ENV|ENV|IFS|PATH|HOME|TMPDIR|SHELLOPTS|BASHOPTS|CDPATH|GLOBIGNORE) return 1 ;;
    DYLD_*|LD_*) return 1 ;;
    WINEPREFIX|WINESERVER|WINEARCH|WINEDEBUG|CX_ROOT|CX_BOTTLE|CX_APPLEGPTK_LIBD3DSHARED_PATH) return 1 ;;
    CYDER_SUPPORT|CYDER_RUNTIME_ROOT|CYDER_ENGINES|CYDER_ENGINE_NAME|CYDER_ENGINE_SRC|CYDER_SCRIPTS|CYDER_APP|CYDER_MAPLESTORY_FILE_CACHE|CYDER_MAPLESTORY_FILE_CACHE_PREFERENCE) return 1 ;;
    CYDER_WINE_*|CYDER_SESSION_*|CYDER_DIAGNOSTIC_*|CYDER_TEST_*|CYDER_RESULT_FILE|CYDER_PROGRESS_FILE) return 1 ;;
    CYDER_GPTK_ROOT|CYDER_GRAPHICS_*|CYDER_GAME_ARGUMENTS) return 1 ;;
  esac
  return 0
}

cyder_is_maplestory_graphics_executable() {
  local exe="$1" basename lower
  basename="${exe##*/}"
  lower="$(printf '%s' "$basename" | tr '[:upper:]' '[:lower:]')"
  [[ "$lower" == "maplestory.exe" || "$lower" == "maplestory_classic.exe" ]]
}

cyder_engine_has_dxmt_payload() {
  local engine_root="$1"
  [[ -r "$engine_root/lib/dxmt/x86_64-windows/d3d11.dll" \
     && -r "$engine_root/lib/dxmt/x86_64-windows/dxgi.dll" \
     && -r "$engine_root/lib/dxmt/x86_64-windows/winemetal.dll" \
     && -r "$engine_root/lib/dxmt/i386-windows/d3d11.dll" \
     && -r "$engine_root/lib/dxmt/i386-windows/dxgi.dll" \
     && -r "$engine_root/lib/dxmt/i386-windows/winemetal.dll" \
     && -r "$engine_root/lib/dxmt/x86_64-unix/winemetal.so" ]]
}

cyder_engine_has_dxvk_payload() {
  local engine_root="$1"
  local moltenvk_a="$engine_root/lib/wine/x86_64-unix/libMoltenVK.dylib"
  local moltenvk_b="$engine_root/lib64/libMoltenVK.dylib"
  [[ -r "$engine_root/lib/dxvk/x86_64-windows/d3d11.dll" \
     && -r "$engine_root/lib/dxvk/x86_64-windows/dxgi.dll" \
     && ( -r "$moltenvk_a" || -r "$moltenvk_b" ) ]]
}

cyder_dxvk_launch_allowed() {
  local engine_root="$1"
  cyder_engine_has_dxvk_payload "$engine_root"
}

cyder_dxmt_launch_allowed() {
  local engine_root="$1"
  declare -F cyder_macos_at_least >/dev/null 2>&1 \
    && cyder_macos_at_least 15 0 \
    && cyder_engine_has_dxmt_payload "$engine_root"
}

cyder_d3dmetal_launch_allowed() {
  local engine_root="$1"
  declare -F cyder_macos_at_least >/dev/null 2>&1 \
    && cyder_macos_at_least 14 0 \
    && cyder_preferred_gptk_root >/dev/null 2>&1
}

cyder_maplestory_auto_graphics_backend() {
  local exe="$1" engine_root="$2"
  cyder_is_maplestory_graphics_executable "$exe" || return 1

  # Prefer DXMT on macOS 15+; DXVK remains the compatibility path on older
  # macOS and the fallback when the current engine lacks a usable DXMT payload.
  if cyder_dxmt_launch_allowed "$engine_root"; then
    printf 'dxmt\n'
    return 0
  fi
  if cyder_dxvk_launch_allowed "$engine_root"; then
    printf 'dxvk\n'
    return 0
  fi
  return 1
}

cyder_apply_graphics_preference() {
  local preference="$1"
  local engine_root="${2:-${CYDER_ENGINES:-}/${CYDER_ENGINE_NAME:-}}"
  case "$preference" in
    default|auto|"")
      # A leftover "auto" (pre-dxmt settings.json) is treated as
      # "default" rather than kept as a distinct preference.
      export CYDER_GRAPHICS_PREFERENCE=default
      export CYDER_GRAPHICS_AUTO_POLICY=1
      unset CYDER_GRAPHICS_BACKEND CX_GRAPHICS_BACKEND
      ;;
    wined3d)
      export CYDER_GRAPHICS_PREFERENCE=wined3d
      export CYDER_GRAPHICS_AUTO_POLICY=0
      export CYDER_GRAPHICS_BACKEND=wined3d CX_GRAPHICS_BACKEND=wined3d
      ;;
    d3dmetal)
      if cyder_d3dmetal_launch_allowed "$engine_root"; then
        export CYDER_GRAPHICS_PREFERENCE=d3dmetal
        export CYDER_GRAPHICS_AUTO_POLICY=0
        export CYDER_GRAPHICS_BACKEND=d3dmetal CX_GRAPHICS_BACKEND=d3dmetal
      else
        echo "D3DMetal is unavailable (requires macOS 14+ and GPTK); using default graphics backend." >&2
        export CYDER_GRAPHICS_PREFERENCE=default
        export CYDER_GRAPHICS_AUTO_POLICY=0
        unset CYDER_GRAPHICS_BACKEND CX_GRAPHICS_BACKEND
      fi
      ;;
    dxvk)
      if cyder_engine_has_dxvk_payload "$engine_root"; then
        export CYDER_GRAPHICS_PREFERENCE=dxvk
        export CYDER_GRAPHICS_AUTO_POLICY=0
        export CYDER_GRAPHICS_BACKEND=dxvk CX_GRAPHICS_BACKEND=dxvk
      else
        echo "DXVK is unavailable (engine lib/dxvk is missing); using default graphics backend." >&2
        export CYDER_GRAPHICS_PREFERENCE=default
        export CYDER_GRAPHICS_AUTO_POLICY=0
        unset CYDER_GRAPHICS_BACKEND CX_GRAPHICS_BACKEND
      fi
      ;;
    dxmt)
      if cyder_dxmt_launch_allowed "$engine_root"; then
        export CYDER_GRAPHICS_PREFERENCE=dxmt
        export CYDER_GRAPHICS_AUTO_POLICY=0
        export CYDER_GRAPHICS_BACKEND=dxmt CX_GRAPHICS_BACKEND=dxmt
      else
        echo "DXMT is unavailable (requires macOS 15+ and engine lib/dxmt); using default graphics backend." >&2
        export CYDER_GRAPHICS_PREFERENCE=default
        export CYDER_GRAPHICS_AUTO_POLICY=0
        unset CYDER_GRAPHICS_BACKEND CX_GRAPHICS_BACKEND
      fi
      ;;
    *)
      echo "Unsupported graphics backend '$preference'; using default graphics backend." >&2
      export CYDER_GRAPHICS_PREFERENCE=default
      export CYDER_GRAPHICS_AUTO_POLICY=0
      unset CYDER_GRAPHICS_BACKEND CX_GRAPHICS_BACKEND
      ;;
  esac
}

cyder_resolve_effective_graphics_backend() {
  local engine_root="$1"
  local exe="${2:-}"
  local preference="${CYDER_GRAPHICS_PREFERENCE:-${CYDER_GRAPHICS_BACKEND:-default}}"
  if [[ "$preference" == default || "$preference" == auto || -z "$preference" ]] \
    && [[ "${CYDER_GRAPHICS_AUTO_POLICY:-1}" == 1 ]] \
    && cyder_is_maplestory_graphics_executable "$exe"; then
    preference="$(cyder_maplestory_auto_graphics_backend "$exe" "$engine_root" || true)"
    preference="${preference:-default}"
  fi
  cyder_apply_graphics_preference "$preference" "$engine_root"
  cyder_apply_graphics_runtime_preferences
}

cyder_graphics_frame_rate_fps() {
  case "${CYDER_DXVK_FRAME_RATE_PREFERENCE:-60}" in
    sixty|60) printf '%s\n' 60 ;;
    120) printf '%s\n' 120 ;;
    144) printf '%s\n' 144 ;;
    *) printf '%s\n' "" ;;
  esac
}

# Keep other DXMT_CONFIG keys; replace or strip d3d11.preferredMaxFrameRate.
cyder_dxmt_config_set_frame_rate() {
  local fps="${1:-}"
  local existing="${DXMT_CONFIG:-}"
  local part key out=""
  local IFS=';'
  # shellcheck disable=SC2086
  for part in $existing; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -n "$part" ]] || continue
    key="${part%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    [[ "$key" == "d3d11.preferredmaxframerate" ]] && continue
    if [[ -n "$out" ]]; then
      out="$out;$part"
    else
      out="$part"
    fi
  done
  if [[ -n "$fps" ]]; then
    if [[ -n "$out" ]]; then
      out="$out;d3d11.preferredMaxFrameRate=$fps"
    else
      out="d3d11.preferredMaxFrameRate=$fps"
    fi
  fi
  if [[ -n "$out" ]]; then
    export DXMT_CONFIG="${out};"
  else
    unset DXMT_CONFIG
  fi
}

cyder_apply_graphics_runtime_preferences() {
  local preference="${CYDER_GRAPHICS_PREFERENCE:-${CYDER_GRAPHICS_BACKEND:-default}}"
  local backend="${CYDER_GRAPHICS_BACKEND:-default}"
  local hud="${CYDER_GRAPHICS_HUD_PREFERENCE:-off}"
  local fps

  unset DXVK_FRAME_RATE DXVK_HUD MTL_HUD_ENABLED
  fps="$(cyder_graphics_frame_rate_fps)"
  if [[ -n "$fps" ]] \
     && [[ "$backend" == dxvk ]] \
     && [[ "$preference" == dxvk ]]; then
    export DXVK_FRAME_RATE="$fps"
  fi
  if [[ "$backend" == dxmt && "$preference" == dxmt ]]; then
    cyder_dxmt_config_set_frame_rate "$fps"
  fi

  case "$hud" in
    metal)
      export MTL_HUD_ENABLED=1 DXVK_HUD=0
      ;;
    dxvk)
      if [[ "$preference" == dxvk ]]; then
        if [[ "${CYDER_DXVK_HUD_FRAMETIMES:-1}" == 0 ]]; then
          export DXVK_HUD=fps
        else
          export DXVK_HUD=fps,frametimes
        fi
      else
        export DXVK_HUD=0
      fi
      ;;
    off|*)
      export DXVK_HUD=0
      ;;
  esac
}

cyder_apply_steam_compatibility_arguments() {
  local exe="$1"
  shift
  CYDER_STEAM_ARGUMENTS=("$@")

  [[ "${CYDER_STEAM_COMPAT:-1}" != 0 ]] || return 0
  [[ "$(basename "$exe" | tr '[:upper:]' '[:lower:]')" == "steam.exe" ]] || return 0

  # Modern Steam renders its CEF UI in child HWNDs.  On macOS/Wine the DOM can
  # remain interactive while Chromium's compositor surface is never presented,
  # producing an all-black window.  Steam's system compositor avoids that
  # off-screen presentation path.  Keep the sandbox switch because Wine cannot
  # provide Chromium's native Windows sandbox.
  local required existing
  for required in -system-composer -no-cef-sandbox; do
    existing=0
    # Bash 3.2 + set -u treats "${empty[@]}" as unbound; guard before iterating.
    if (( ${#CYDER_STEAM_ARGUMENTS[@]} > 0 )); then
      local argument
      for argument in "${CYDER_STEAM_ARGUMENTS[@]}"; do
        if [[ "$argument" == "$required" ]]; then
          existing=1
          break
        fi
      done
    fi
    [[ "$existing" -eq 1 ]] || CYDER_STEAM_ARGUMENTS+=("$required")
  done
}

cyder_load_game_settings() {
  local exe="$1"
  local engine_root="${2:-${CYDER_ENGINES:-}/${CYDER_ENGINE_NAME:-}}"
  local profile_script="$CYDER_SCRIPTS/cyder-profile.sh"
  local settings_file="$CYDER_SUPPORT/settings.json"
  local profile_id game_json launch_request="${CYDER_TEST_SETTINGS_REQUEST:-}"
  CYDER_GAME_ARGUMENTS=()
  CYDER_GAME_SETTINGS_FOUND=0

  [[ -x "$profile_script" ]] || return 0
  profile_id="$(bash "$profile_script" id "$exe" 2>/dev/null)" || return 0
  [[ "$profile_id" =~ ^profile-[0-9a-f]{24}$ ]] || return 0
  if [[ -n "$launch_request" ]]; then
    local request_dir expected_dir
    [[ -f "$launch_request" && ! -L "$launch_request" ]] || {
      echo "Invalid Cyder launch settings request: $launch_request" >&2
      return 1
    }
    request_dir="$(cd "$(dirname "$launch_request")" && pwd -P)" || return 1
    expected_dir="$CYDER_SUPPORT/launch-requests"
    mkdir -p "$expected_dir"
    expected_dir="$(cd "$expected_dir" && pwd -P)" || return 1
    [[ "$request_dir" == "$expected_dir" ]] || {
      echo "Cyder launch settings request is outside $expected_dir" >&2
      return 1
    }
    game_json="$(/bin/cat "$launch_request")" || return 1
    rm -f "$launch_request"
    unset CYDER_TEST_SETTINGS_REQUEST
  else
    [[ -f "$settings_file" ]] || return 0
    # Most EXEs use global settings and have no per-profile entry. Disable the
    # inherited ERR trap only for this optional lookup so an expected miss does
    # not report a false settings-apply failure.
    game_json="$(
      trap - ERR
      /usr/bin/plutil -extract "perProfile.$profile_id" json -o - "$settings_file" 2>/dev/null
    )" || return 0
  fi
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
            fontMingLiuTarget) cyder_font_target_is_valid "$value" && export CYDER_FONT_MINGLIU_TARGET="$value" || true ;;
            fontSongtiTarget) cyder_font_target_is_valid "$value" && export CYDER_FONT_SONGTI_TARGET="$value" || true ;;
            fontPreset)
              case "$value" in songti|mingliu)
                IFS=$'\n' read -r _ming _song < <(cyder_migrate_font_targets_from_preset "$value")
                export CYDER_FONT_MINGLIU_TARGET="$_ming"
                export CYDER_FONT_SONGTI_TARGET="$_song"
                ;;
              esac
              ;;
            fontSmoothing) case "$value" in off|grayscale|cleartype-rgb|cleartype-bgr) export CYDER_FONT_SMOOTHING="$value" ;; esac ;;
            powerMode) case "$value" in standard) export CYDER_POWER_MODE=normal ;; energySaving) export CYDER_POWER_MODE=background ;; esac ;;
            graphicsBackend)
              cyder_apply_graphics_preference "$value" "$engine_root"
              ;;
            dxvkFrameRate)
              case "$value" in
                60|sixty) export CYDER_DXVK_FRAME_RATE_PREFERENCE=60 ;;
                120|144) export CYDER_DXVK_FRAME_RATE_PREFERENCE="$value" ;;
                unlimited) export CYDER_DXVK_FRAME_RATE_PREFERENCE=unlimited ;;
              esac
              ;;
          esac
          ;;
        environment)
          cyder_game_environment_key_is_allowed "$key" && export "$key=$value"
          ;;
        argument)
          CYDER_GAME_ARGUMENTS+=("$key")
          ;;
      esac
    done < <(/usr/bin/ruby -rjson -e '
      rule = JSON.parse(STDIN.read)
      %w[msync esync retinaMode dpi fontMingLiuTarget fontSongtiTarget fontPreset fontSmoothing powerMode graphicsBackend dxvkFrameRate].each do |key|
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
  cyder_load_game_settings "$exe" "$engine_root"
  cyder_apply_maplestory_wz_cache "$exe"
  cyder_resolve_effective_graphics_backend "$engine_root" "$exe"

  # Global display/font settings are loaded before the launcher reaches this
  # function.  They must still be applied when the EXE has no per-profile
  # entry; otherwise a newly provisioned prefix keeps the bootstrap Retina
  # Mode/DPI baseline until the user toggles the preference manually.

  local prefix_was_running=0
  cyder_has_running_prefix "$prefix" && prefix_was_running=1
  cyder_apply_user_settings "$wine_bin" "$engine_root" "$prefix" || return $?
  local wineserver="$engine_root/bin/wineserver"
  if [[ "$prefix_was_running" -eq 0 && -x "$wineserver" ]]; then
    WINEPREFIX="$prefix" /usr/bin/arch -x86_64 "$wineserver" -k || true
    WINEPREFIX="$prefix" /usr/bin/arch -x86_64 "$wineserver" -w || true
  fi
}

# MSI installers always target the shared prefix and must not load per-game
# profile settings.  Global display/font registry still applies when idle.
cyder_prepare_installer_launch_settings() {
  local wine_bin="$1"
  local engine_root="$2"
  local prefix="$3"
  cyder_load_saved_settings
  cyder_apply_user_settings "$wine_bin" "$engine_root" "$prefix" || return $?
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
  local prefix status=0
  for prefix in "$CYDER_SUPPORT/bottles"/* "$CYDER_LEGACY_SHARED_PREFIX"; do
    [[ -d "$prefix" && ! -L "$prefix" ]] || continue
    echo "Stopping all EXEs in $prefix" >&2
    cyder_stop_managed_prefix "$wineserver" "$prefix" || status=$?
  done
  return "$status"
}

# Stop one already-validated Cyder bottle. Unlike the older cleanup helper,
# this is a user-facing operation and must report wineserver failures.
cyder_stop_managed_prefix() {
  local wineserver="$1" prefix="$2" status=0 wait_status=0
  local timeout="${CYDER_STOP_WAIT_TIMEOUT:-15}" deadline waiter
  [[ -x "$wineserver" ]] || { echo "Cyder wineserver is unavailable: $wineserver" >&2; return 2; }
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=15
  WINEPREFIX="$prefix" arch -x86_64 "$wineserver" -k || status=$?
  WINEPREFIX="$prefix" arch -x86_64 "$wineserver" -w &
  waiter=$!
  deadline=$((SECONDS + timeout))
  while kill -0 "$waiter" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill -TERM "$waiter" 2>/dev/null || true
      wait "$waiter" 2>/dev/null || true
      echo "Timed out waiting for Wine processes in $prefix" >&2
      return 75
    fi
    sleep 0.1
  done
  wait "$waiter" || wait_status=$?
  (( wait_status == 0 )) || status=$wait_status
  return "$status"
}

# Open Wine's own task manager without keeping the native menu action blocked.
# All stdio is detached so a caller using a pipe or Process.waitUntilExit also
# returns as soon as the task manager has been dispatched.
cyder_open_prefix_taskmgr() {
  local wine_bin="$1" prefix="$2"
  local wineserver="${wine_bin%/wine}/wineserver"
  local session_file sync=""
  [[ -x "$wine_bin" ]] || { echo "Cyder Wine is unavailable: $wine_bin" >&2; return 2; }
  mkdir -p "$CYDER_SUPPORT/Logs"
  (
    export WINEPREFIX="$prefix" WINESERVER="$wineserver"
    # A Wine client must use the same synchronization protocol as the active
    # bottle server. Prefer the live session contract because per-game launch
    # settings can differ from the currently saved global preference.
    for session_file in "$(cyder_session_dir "$prefix")"/*.session; do
      [[ -f "$session_file" && ! -L "$session_file" ]] || continue
      sync="$(sed -n 's/^sync=//p' "$session_file" | head -1)"
      [[ -n "$sync" ]] && break
    done
    [[ -n "$sync" ]] || sync="msync=${CYDER_MSYNC:-0};esync=${CYDER_ESYNC:-0};power=${CYDER_POWER_MODE:-normal}"
    case "$sync" in
      msync=1\;esync=0\;*) export WINEMSYNC=1; unset WINEESYNC ;;
      msync=0\;esync=1\;*) export WINEESYNC=1; unset WINEMSYNC ;;
      *) unset WINEMSYNC WINEESYNC ;;
    esac
    if [[ -f "$prefix/cxbottle.conf" ]] || cyder_wine_is_crossover_frontend "$wine_bin"; then
      export CX_BOTTLE="$prefix" CX_ROOT="$(cd "$(dirname "$wine_bin")/.." && pwd -P)" WINEARCH=win64
    fi
    cd "$prefix"
    cyder_exec_wine "$wine_bin" taskmgr
  ) </dev/null >>"$CYDER_SUPPORT/Logs/taskmgr.log" 2>&1 &
}

# Wine stores the per-prefix server socket under $TMPDIR (macOS LaunchServices
# uses /var/folders/.../T) with /tmp as fallback. Check both, and treat a live
# Cyder session pid as in-use even if the socket path differs.
cyder_prefix_has_live_session_pids() {
  local prefix="$1" dir file pid
  dir="$(cyder_session_dir "$prefix")"
  [[ -d "$dir" ]] || return 1
  for file in "$dir"/*.session; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    pid="$(sed -n 's/^pid=//p' "$file" | head -1)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

cyder_has_running_prefix() {
  local prefix="$1"
  [[ -d "$prefix" ]] || return 1
  local resolved device inode socket_dir tmp_root uid
  resolved="$(cd "$prefix" && pwd -P)" || resolved="$prefix"
  device="$(stat -f '%d' "$resolved" 2>/dev/null)" || return 1
  inode="$(stat -f '%i' "$resolved" 2>/dev/null)" || return 1
  printf -v device '%x' "$device"
  printf -v inode '%x' "$inode"
  uid="$(id -u)"
  for tmp_root in /tmp ${TMPDIR:+"$TMPDIR"}; do
    [[ -n "$tmp_root" ]] || continue
    socket_dir="${tmp_root%/}/.wine-${uid}/server-${device}-${inode}"
    # Wine removes the socket when the prefix wineserver exits; the lock file may remain.
    [[ -S "$socket_dir/socket" ]] && return 0
  done
  cyder_prefix_has_live_session_pids "$resolved" && return 0
  if [[ "$resolved" != "$prefix" ]]; then
    cyder_prefix_has_live_session_pids "$prefix"
    return $?
  fi
  return 1
}

cyder_has_running_exes() {
  local prefix
  for prefix in "$CYDER_SUPPORT/bottles"/* "$CYDER_LEGACY_SHARED_PREFIX"; do
    [[ -d "$prefix" && ! -L "$prefix" ]] || continue
    cyder_has_running_prefix "$prefix" && return 0
  done
  return 1
}

# True when the shared bottle is fully ready for the current engine. CrossOver
# engines also require a readable cxbottle.conf; a half-built bottle without it
# is treated as not ready so bootstrap/rebuild can replace it.
cyder_shared_prefix_is_ready() {
  local wine_bin="${1:-}"
  [[ -f "$CYDER_BOOTSTRAP_MARKER" ]] || return 1
  [[ -f "$CYDER_SHARED_PREFIX/system.reg" ]] || return 1
  [[ -f "$CYDER_SHARED_PREFIX/.cyder-golden-baseline-v2" ]] || return 1
  if [[ -n "$wine_bin" ]] && cyder_crossover_bottle_data_conf "$wine_bin" >/dev/null 2>&1; then
    [[ -r "$CYDER_SHARED_PREFIX/cxbottle.conf" ]] || return 1
  fi
  return 0
}

cyder_prepare_graphics_prefix() {
  local wine_bin="$1" engine_root="$2" prefix="${3:-$CYDER_SHARED_PREFIX}"

  # Bundled Cyder opens install/update the runtime payload before inspecting an
  # existing bottle. Source check keeps development/bootstrap fixtures usable
  # when no app graphics payload has been packaged.
  if declare -F cyder_graphics_source_dir >/dev/null 2>&1 &&
     cyder_graphics_source_dir >/dev/null 2>&1; then
    cyder_ensure_graphics "$prefix" || return $?
  fi
  if declare -F cyder_migrate_graphics_prefix >/dev/null 2>&1; then
    if cyder_has_running_prefix "$prefix"; then
      echo "Deferred graphics DLL migration: prefix is in use: $prefix"
      return 0
    fi
    cyder_migrate_graphics_prefix "$wine_bin" "$engine_root" "$prefix"
  fi
}

cyder_bootstrap_shared_prefix() {
  local wine_bin="$1"
  local engine_root="$2"
  CYDER_BOOTSTRAP_HEALTH_CHECKED=0
  # Graphics/winemetal belong after the prefix exists (Phase C). Do not prepare
  # graphics against a missing or incomplete bottle here.
  if cyder_shared_prefix_is_ready "$wine_bin"; then
    return 0
  fi
  cyder_has_running_prefix "$CYDER_SHARED_PREFIX" && {
    echo "Cannot replace shared prefix while Wine is running." >&2
    return 75
  }
  if [[ -e "$CYDER_SHARED_PREFIX" ]]; then
    local parent old_shared staging
    parent="$(dirname "$CYDER_SHARED_PREFIX")"
    old_shared="$parent/.bootstrap-previous-$(basename "$CYDER_SHARED_PREFIX")-$$"
    staging="$parent/.bootstrap-staging-$(basename "$CYDER_SHARED_PREFIX")-$$"
    [[ ! -e "$staging" && ! -L "$staging" && ! -e "$old_shared" && ! -L "$old_shared" ]] || {
      echo "Bootstrap staging path already exists." >&2
      return 1
    }
    # Incomplete bottle (e.g. missing OEM cxbottle.conf): replace entirely.
    echo "Replacing incomplete bottle with a fresh prefix: $CYDER_SHARED_PREFIX" >&2
    if ! cyder_provision_prefix_baseline "$wine_bin" "$engine_root" "$staging"; then
      cyder_remove_path "$staging"
      return 1
    fi
    if ! mv "$CYDER_SHARED_PREFIX" "$old_shared"; then
      cyder_remove_path "$staging"
      return 1
    fi
    if ! mv "$staging" "$CYDER_SHARED_PREFIX"; then
      cyder_remove_path "$staging"
      mv "$old_shared" "$CYDER_SHARED_PREFIX" || true
      return 1
    fi
    printf 'revision=%s\n' "${CYDER_TEMPLATE_REVISION:-1}" >"$CYDER_BOOTSTRAP_MARKER"
    # Rollback storage is temporary; never accumulate rebuilt bottles.
    cyder_remove_path "$old_shared"
  else
    cyder_provision_prefix_baseline "$wine_bin" "$engine_root" "$CYDER_SHARED_PREFIX" || return $?
    printf 'revision=%s\n' "${CYDER_TEMPLATE_REVISION:-1}" >"$CYDER_BOOTSTRAP_MARKER"
  fi

  # Phase C: DXMT winemetal + engine graphics links (payload may already have
  # overlapped wineboot inside provision). Skip when provision finished it.
  if [[ "${CYDER_PROVISION_DID_GRAPHICS:-0}" == 1 ]]; then
    return 0
  fi
  cyder_report_progress "正在準備圖形元件…" "graphics-ensure"
  if declare -F cyder_graphics_source_dir >/dev/null 2>&1 &&
     cyder_graphics_source_dir >/dev/null 2>&1; then
    cyder_bootstrap_substage_begin graphics-ensure
    if ! cyder_ensure_graphics "$CYDER_SHARED_PREFIX"; then
      local graphics_status=$?
      cyder_bootstrap_substage_end graphics-ensure "$graphics_status"
      return "$graphics_status"
    fi
    cyder_bootstrap_substage_end graphics-ensure 0
  fi
}

cyder_swift_bin() {
  if [[ -n "${CYDER_SWIFT:-}" && -x "${CYDER_SWIFT}" ]]; then
    printf '%s\n' "$CYDER_SWIFT"
    return 0
  fi
  local candidate="${CYDER_APP:-}/Contents/MacOS/CyderSwift"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

# Open a wait fifo and start CyderSwift --sentinel-connect.
# The supervisor keeps the write end on fd 3. Helper and Wine must not inherit
# it: an inherited RDWR fifo lets the helper keep itself alive forever.
# Sets CYDER_SENTINEL_PID and CYDER_SENTINEL_WATCH_FILE; leaves fd 3 as the write end.
cyder_sentinel_attach() {
  local prefix="$1" exe_path="$2"
  local swift wait_dir wait_fifo exe_name
  CYDER_SENTINEL_PID=""
  CYDER_SENTINEL_WATCH_FILE=""
  swift="$(cyder_swift_bin)" || return 1
  wait_dir="$(mktemp -d "${TMPDIR:-/tmp}/cyder-sentinel.XXXXXX")" || return 1
  wait_fifo="$wait_dir/wait"
  CYDER_SENTINEL_WATCH_FILE="$wait_dir/watch.pid"
  mkfifo "$wait_fifo" || {
    rm -rf "$wait_dir"
    return 1
  }
  exe_name="$(basename "${exe_path%.*}")"
  # Opening the fifo read/write does not block: this process is already both
  # ends. A write-only open would deadlock until the helper finished dyld.
  exec 3<>"$wait_fifo" || {
    rm -rf "$wait_dir"
    return 1
  }
  cyder_spawn_cyder_swift "$swift" --sentinel-connect \
    --prefix "$prefix" \
    --exe "$exe_name" \
    --fifo "$wait_fifo" \
    --pid-file "$CYDER_SENTINEL_WATCH_FILE" 3>&- &
  CYDER_SENTINEL_PID=$!
  return 0
}

cyder_sentinel_publish_pid() {
  local pid="$1"
  if [[ -n "${CYDER_SENTINEL_WATCH_FILE:-}" ]]; then
    printf '%s\n' "$pid" >"$CYDER_SENTINEL_WATCH_FILE"
  fi
}

cyder_sentinel_close_write() {
  exec 3>&- 2>/dev/null || true
}

# Quiet Wine launch logs keep a live tail cap on one inode so a long session
# cannot fill the disk. Non-quiet diagnostics skip this helper.
cyder_bounded_wine_log() {
  local log_file="$1"
  local max_bytes="${CYDER_WINE_LAUNCH_LOG_MAX_BYTES:-16777216}"
  [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || max_bytes=16777216
  /usr/bin/perl -e '
    use strict;
    use warnings;
    use Fcntl qw(O_RDWR O_CREAT SEEK_SET SEEK_END);
    use IO::Handle;

    my $file = $ARGV[0];
    my $max = int($ARGV[1]);
    $max = 1 if $max < 1;
    my $marker = "[Cyder] last-wine-launch.log truncated; showing newest output\n";
    my $payload_max = $max - length($marker);
    $payload_max = $max if $payload_max < 1;
    my $flush_every = $payload_max > 1024 * 1024 ? 1024 * 1024 : int($payload_max / 4) || 1;

    sysopen(my $fh, $file, O_RDWR | O_CREAT, 0644) or die "open $file: $!";
    binmode $fh;
    binmode STDIN;
    $fh->autoflush(1);
    seek $fh, 0, SEEK_END or die $!;
    my $size = tell $fh;
    my $ring = "";
    my $using_ring = 0;
    my $since_flush = 0;
    my $write_capped = sub {
      truncate $fh, 0 or die $!;
      seek $fh, 0, SEEK_SET or die $!;
      print $fh $marker;
      print $fh $ring;
    };

    if ($size >= $max) {
      my $start = $size > $payload_max ? $size - $payload_max : 0;
      seek $fh, $start, SEEK_SET or die $!;
      read $fh, $ring, $payload_max;
      $using_ring = 1;
      $write_capped->();
    }

    while (1) {
      my $n = read STDIN, my $buf, 65536;
      last unless $n;
      if (!$using_ring) {
        if ($size + $n <= $max) {
          print $fh $buf;
          $size += $n;
          next;
        }
        seek $fh, 0, SEEK_SET or die $!;
        my $existing = "";
        read $fh, $existing, $size if $size > 0;
        $ring = $existing . $buf;
        $ring = substr($ring, -$payload_max) if length($ring) > $payload_max;
        $using_ring = 1;
        $write_capped->();
        $since_flush = 0;
        next;
      }
      $ring .= $buf;
      $ring = substr($ring, -$payload_max) if length($ring) > $payload_max;
      $since_flush += $n;
      if ($since_flush >= $flush_every) {
        $write_capped->();
        $since_flush = 0;
      }
    }
    $write_capped->() if $using_ring;
  ' -- "$log_file" "$max_bytes"
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
  local target_kind="${CYDER_LAUNCH_TARGET_KIND:-exe}"
  local -a game_args=("$@")
  CYDER_STEAM_ARGUMENTS=()
  if [[ "$target_kind" == "msi" ]]; then
    # MSI installs never participate in Steam argv rewriting or CompatDB.
    :
  else
    # cyder_init_paths may run before a new bottle exists. Re-select and pin the
    # database immediately before launch, when the final prefix is available.
    cyder_configure_compatdb "$prefix"
    if (( ${#game_args[@]} > 0 )); then
      cyder_apply_steam_compatibility_arguments "$exe" "${game_args[@]}"
    else
      cyder_apply_steam_compatibility_arguments "$exe"
    fi
    game_args=()
    if (( ${#CYDER_STEAM_ARGUMENTS[@]} > 0 )); then
      game_args=("${CYDER_STEAM_ARGUMENTS[@]}")
    fi
  fi
  # Login credentials often arrive through argv. Execute the original array,
  # but never copy argument values into persistent logs.
  local game_args_text="(no game arguments)"
  if [[ "$target_kind" == "msi" ]]; then
    game_args_text="(no msiexec arguments)"
  fi
  if (( ${#game_args[@]} > 0 )); then
    if [[ "$target_kind" == "msi" ]]; then
      game_args_text="<${#game_args[@]} msiexec arguments redacted>"
    else
      game_args_text="<${#game_args[@]} game arguments redacted>"
    fi
  fi
  if declare -F cyder_apply_moltenvk_os_floor >/dev/null 2>&1; then
    cyder_apply_moltenvk_os_floor
  fi
  local wineserver="${wine_bin%/wine}/wineserver"
  # Keep the legacy direct path as the default.  Wine's ShellExecute-compatible
  # start.exe path is available for A/B testing with CYDER_WINE_START_MODE=start
  # but does not guarantee macOS frontmost activation.
  local start_mode="${CYDER_WINE_START_MODE:-direct}"
  local detach="${CYDER_WINE_DETACH:-0}"
  local pid_file="${CYDER_WINE_PID_FILE:-}"
  local result_file="${CYDER_WINE_RESULT_FILE:-}"
  local activated_file="${CYDER_WINE_ACTIVATED_FILE:-}"
  local lifecycle_file="${CYDER_WINE_LIFECYCLE_FILE:-}"
  local session_id=""
  cyder_wine_locale_exports
  local capture_log="${CYDER_CAPTURE_WINE_LOG:-0}"
  local wine_diagnostics="${CYDER_WINE_DIAGNOSTICS:-quiet}"
  local wine_debug="-all"
  case "$wine_diagnostics" in
    errors)
      wine_debug="-all,err+all,+timestamp,+pid,+tid"
      capture_log=1
      ;;
    sync)
      wine_debug="-all,err+all,+timestamp,+pid,+tid,+sync"
      capture_log=1
      ;;
    unwind)
      wine_debug="-all,+timestamp,+pid,+tid,+seh,+unwind"
      capture_log=1
      ;;
    *)
      wine_diagnostics="quiet"
      ;;
  esac
  local engine_root canonical_prefix engine_version ntdll_sha256="unavailable"
  engine_root="$(cd "$(dirname "$wine_bin")/.." && pwd -P)"
  canonical_prefix="$(cd "$prefix" 2>/dev/null && pwd -P || printf '%s' "$prefix")"
  cyder_apply_gptk_launch_environment "$engine_root" || return $?
  if [[ -f "$prefix/cxbottle.conf" ]] || cyder_wine_is_crossover_frontend "$wine_bin"; then
    export CX_BOTTLE="$prefix" CX_ROOT="$engine_root" WINEARCH=win64
    cyder_sync_crossover_graphics_environment "$prefix" || return $?
  fi
  engine_version="$(head -n 1 "$engine_root/version" 2>/dev/null || true)"
  if [[ "$capture_log" == 1 && -f "$engine_root/lib/wine/x86_64-windows/ntdll.dll" ]]; then
    ntdll_sha256="$(/usr/bin/shasum -a 256 \
      "$engine_root/lib/wine/x86_64-windows/ntdll.dll" 2>/dev/null | awk '{print $1}')"
    [[ -n "$ntdll_sha256" ]] || ntdll_sha256="unavailable"
  fi
  local log_file="/dev/null"
  if [[ "$capture_log" == 1 ]]; then
    local log_dir="$CYDER_SUPPORT/Logs"
    local sessions_dir="$log_dir/sessions"
    local diagnostic_log="${CYDER_DIAGNOSTIC_LOG:-}"
    local latest_log="$log_dir/last-launch.log"
    mkdir -p "$sessions_dir"
    # Keep one stable Wine launch session. The Swift launcher prepares this
    # path before spawning the shell so its command header and this preamble
    # share the same file descriptor. Direct shell launches truncate it here.
    log_file="$sessions_dir/last-wine-launch.log"
    if [[ "$diagnostic_log" == "$log_file" ]]; then
      log_file="$diagnostic_log"
    else
      : >"$log_file"
    fi
    rm -f "$latest_log"
    rm -f "$log_dir/last-launch.log.gz"
    ln -sfn "sessions/last-wine-launch.log" "$latest_log"
  fi
  if [[ "$detach" == 1 && -n "$pid_file" ]]; then
    mkdir -p "$(dirname "$pid_file")"
    rm -f "$pid_file" "${pid_file}.tmp"
    if [[ -n "$result_file" ]]; then
      mkdir -p "$(dirname "$result_file")"
      rm -f "$result_file" "${result_file}.tmp"
    fi
    if [[ -n "$activated_file" ]]; then
      mkdir -p "$(dirname "$activated_file")"
      rm -f "$activated_file"
    fi
    if [[ -n "$lifecycle_file" ]]; then
      mkdir -p "$(dirname "$lifecycle_file")"
      rm -f "$lifecycle_file" "${lifecycle_file}.tmp"
    fi
  fi
  cyder_exec_game() {
    if [[ "$target_kind" == "msi" ]]; then
      if (( ${#game_args[@]} > 0 )); then
        cyder_exec_wine "$wine_bin" msiexec /i "$exe" "${game_args[@]}"
      else
        cyder_exec_wine "$wine_bin" msiexec /i "$exe"
      fi
    elif [[ "$start_mode" == "start" ]]; then
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
  cyder_exec_game_with_launch_log() {
    local launch_log="$1"
    local status=0 dir fifo log_pid
    if [[ "$launch_log" == /dev/null ]]; then
      cyder_exec_game >/dev/null 2>&1 3>&-
      return $?
    fi
    if [[ "$wine_diagnostics" != quiet ]]; then
      cyder_exec_game >>"$launch_log" 2>&1 3>&-
      return $?
    fi
    dir="$(mktemp -d "${TMPDIR:-/tmp}/cyder-winelog.XXXXXX")" || return 1
    fifo="$dir/log"
    if ! mkfifo "$fifo"; then
      rm -rf "$dir"
      return 1
    fi
    cyder_bounded_wine_log "$launch_log" <"$fifo" 3>&- &
    log_pid=$!
    cyder_exec_game >"$fifo" 2>&1 3>&- || status=$?
    wait "$log_pid" || true
    rm -rf "$dir"
    return "$status"
  }
  {
    local taskpolicy_bin=""
    taskpolicy_bin="$(cyder_find_taskpolicy || true)"
    local cmd_line=""
    if [[ "$target_kind" == "msi" ]]; then
      if [[ "${CYDER_POWER_MODE:-normal}" == background && -n "$taskpolicy_bin" ]]; then
        cmd_line="$taskpolicy_bin -c background /usr/bin/arch -x86_64 $wine_bin msiexec /i $exe $game_args_text"
      else
        cmd_line="/usr/bin/arch -x86_64 $wine_bin msiexec /i $exe $game_args_text"
      fi
    elif [[ "$start_mode" == "start" ]]; then
      if [[ "${CYDER_POWER_MODE:-normal}" == background && -n "$taskpolicy_bin" ]]; then
        cmd_line="$taskpolicy_bin -c background /usr/bin/arch -x86_64 $wine_bin start /wait /unix $exe $game_args_text"
      else
        cmd_line="/usr/bin/arch -x86_64 $wine_bin start /wait /unix $exe $game_args_text"
      fi
    else
      if [[ "${CYDER_POWER_MODE:-normal}" == background && -n "$taskpolicy_bin" ]]; then
        cmd_line="$taskpolicy_bin -c background /usr/bin/arch -x86_64 $wine_bin $exe $game_args_text"
      else
        cmd_line="/usr/bin/arch -x86_64 $wine_bin $exe $game_args_text"
      fi
    fi
    # CrossOver-style preamble so Logs/last-launch.log shows the exact command
    # and sync flags before Wine stdout/stderr.
    echo "***** $(date '+%Y-%m-%dT%H:%M:%SZ')"
    if [[ "$target_kind" == "msi" ]]; then
      echo "Running MSI installer: \"$exe\""
    else
      echo "Running command: \"$exe\""
    fi
    echo "Launch kind: ${CYDER_LAUNCH_KIND:-cli}"
    echo "Runtime: $engine_root"
    echo "Prefix: $canonical_prefix"
    echo "Engine version: ${engine_version:-unknown}"
    echo "NTDLL SHA-256: $ntdll_sha256"
    echo "Graphics preference: ${CYDER_GRAPHICS_PREFERENCE:-default}"
    echo "Graphics backend: ${CYDER_GRAPHICS_BACKEND:-default}"
    echo "GPTK root: ${CYDER_GPTK_ROOT:-<unset>}"
    echo "DXVK frame rate: ${DXVK_FRAME_RATE:-<unset>}"
    echo "DXMT config: ${DXMT_CONFIG:-<unset>}"
    echo "DXVK HUD: ${DXVK_HUD:-<unset>}"
    echo "Metal HUD: ${MTL_HUD_ENABLED:-<unset>}"
    if [[ "${CYDER_MSYNC:-0}" == 1 ]]; then
      echo "MSync: Enabled"
    else
      echo "MSync: Disabled"
    fi
    if [[ "${CYDER_ESYNC:-0}" == 1 ]]; then
      echo "ESync: Enabled"
    else
      echo "ESync: Disabled"
    fi
    echo "Power mode: ${CYDER_POWER_MODE:-normal}"
    echo "Wine diagnostics: $wine_diagnostics"
    echo "cwd: $(dirname "$exe")"
    echo
    echo "Command:"
    echo "$cmd_line"
    echo
    echo "Effective Wine environment:"
    echo "  WINEPREFIX=$prefix"
    echo "  CYDER_MSYNC=${CYDER_MSYNC:-0}"
    echo "  CYDER_ESYNC=${CYDER_ESYNC:-0}"
    echo "  CYDER_GRAPHICS_BACKEND=${CYDER_GRAPHICS_BACKEND:-<unset>}"
    echo "  CYDER_GRAPHICS_BACKEND_PATH=${CYDER_GRAPHICS_BACKEND_PATH:-<derived from engine>}"
    echo "  CYDER_GPTK_ROOT=${CYDER_GPTK_ROOT:-<unset>}"
    echo "  CYDER_WINE_DIAGNOSTICS=$wine_diagnostics"
    echo "  DXVK_FRAME_RATE=${DXVK_FRAME_RATE:-<unset>}"
    echo "  DXMT_CONFIG=${DXMT_CONFIG:-<unset>}"
    echo "  DXVK_HUD=${DXVK_HUD:-<unset>}"
    echo "  MTL_HUD_ENABLED=${MTL_HUD_ENABLED:-<unset>}"
    echo "  WINEDEBUG=$wine_debug"
    echo "  taskpolicy_available=$([[ -n "$taskpolicy_bin" ]] && echo true || echo false)"
    echo
  } >>"$log_file"
  (
    export WINEPREFIX="$prefix" WINESERVER="$wineserver" WINEDEBUG="$wine_debug"
    export CYDER_GRAPHICS_BACKENDS_ROOT="$(cd "$(dirname "$wine_bin")/.." && pwd)"
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
      # A detached supervisor remains the Wine process' parent so it can reap
      # the exact POSIX wait status.  PID and result files are per launch and
      # atomically published; Swift never needs to parse the shared Wine log.
      detached_session_id="${session_id:-}"
      (
        cyder_sentinel_attach "$prefix" "$exe" || true
        cyder_exec_game_with_launch_log "$log_file" &
        wine_pid=$!
        cyder_sentinel_publish_pid "$wine_pid"
        cyder_sentinel_close_write
        printf '%s\n' "$wine_pid" >"${pid_file}.tmp"
        mv -f "${pid_file}.tmp" "$pid_file"
        if [[ -n "$detached_session_id" ]]; then
          sed -i '' "s/^pid=.*/pid=$wine_pid/" "$detached_session_id" 2>/dev/null || \
            sed -i "s/^pid=.*/pid=$wine_pid/" "$detached_session_id"
        fi
        wine_status=0
        wait "$wine_pid" || wine_status=$?
        if [[ -n "$lifecycle_file" ]]; then
          {
            printf 'schema=1\n'
            printf 'state=background\n'
            printf 'exit_status=%s\n' "$wine_status"
          } >"${lifecycle_file}.tmp"
          mv -f "${lifecycle_file}.tmp" "$lifecycle_file"
        fi
        if [[ -n "$result_file" ]]; then
          {
            printf 'schema=1\n'
            printf 'pid=%s\n' "$wine_pid"
            printf 'exit_status=%s\n' "$wine_status"
          } >"${result_file}.tmp"
          mv -f "${result_file}.tmp" "$result_file"
          # Successful launches stop being observed after activation. Consume
          # their sidecars here; briefly cover the exit/activation race.
          if [[ -n "$activated_file" ]]; then
            for _ in {1..10}; do
              if [[ -e "$activated_file" ]]; then
                rm -f "$result_file" "$activated_file"
                break
              fi
              sleep 0.1
            done
          fi
        fi
        if [[ -n "$detached_session_id" ]]; then
          # The primary client returning does not imply that the bottle is
          # finished. Anti-cheat, Steam helpers, and services can keep the
          # wineserver alive while they wind down. wineserver -w distinguishes
          # a live server from a stale socket left by an abnormal exit.
          cyder_session_mark_background "$detached_session_id"
        fi
        lifecycle_state=stopped
        if [[ -n "$detached_session_id" || -n "$lifecycle_file" ]]; then
          WINEPREFIX="$prefix" arch -x86_64 "$wineserver" -w >/dev/null 2>&1 || lifecycle_state=attention
        fi
        if [[ -n "$lifecycle_file" ]]; then
          {
            printf 'schema=1\n'
            printf 'state=%s\n' "$lifecycle_state"
            printf 'exit_status=%s\n' "$wine_status"
          } >"${lifecycle_file}.tmp"
          mv -f "${lifecycle_file}.tmp" "$lifecycle_file"
        fi
        if [[ -n "$detached_session_id" ]]; then
          cyder_session_release "$prefix" "$detached_session_id"
          detached_session_id=""
          session_id=""
        fi
        if [[ -n "${CYDER_SENTINEL_WATCH_FILE:-}" ]]; then
          rm -rf "$(dirname "$CYDER_SENTINEL_WATCH_FILE")"
        fi
      ) &
      # The supervisor now owns both the Wine child and runtime session.
      session_id=""
      # Keep the launcher handshake synchronous: Swift reads the PID as soon
      # as this function returns, while the later exit result stays async.
      for _ in {1..250}; do
        [[ -s "$pid_file" ]] && break
        sleep 0.01
      done
      if [[ ! -s "$pid_file" ]]; then
        echo "Detached Wine supervisor did not publish its PID." >&2
        return 1
      fi
    else
      # CLI launches keep Wine in the foreground so the caller owns the game
      # lifetime. Finder's native entry point opts into the detached branch.
      cyder_exec_game_with_launch_log "$log_file"
    fi
  )
}

# Execute Wine with the requested power policy.  `normal` intentionally does
# not invoke taskpolicy; background is applied to arch, the process which
# creates wineserver, so the policy is inherited by the Wine session.
cyder_exec_wine() {
  local wine_bin="$1"
  shift
  local frontend_args_text
  frontend_args_text="$(cyder_wine_frontend_args "$wine_bin")"
  local -a frontend_args=()
  [[ -z "$frontend_args_text" ]] || read -r -a frontend_args <<<"$frontend_args_text"
  local mode="${CYDER_POWER_MODE:-normal}"
  local taskpolicy_bin=""
  taskpolicy_bin="$(cyder_find_taskpolicy || true)"
  if [[ "$mode" == background && -n "$taskpolicy_bin" ]]; then
    if (( ${#frontend_args[@]} > 0 )); then
      "$taskpolicy_bin" -c background /usr/bin/arch -x86_64 "$wine_bin" "${frontend_args[@]}" "$@"
    else
      "$taskpolicy_bin" -c background /usr/bin/arch -x86_64 "$wine_bin" "$@"
    fi
  else
    if [[ "$mode" != normal && -z "$taskpolicy_bin" ]]; then
      echo "error: taskpolicy is unavailable; select Standard energy mode" >&2
      return 127
    fi
    if (( ${#frontend_args[@]} > 0 )); then
      /usr/bin/arch -x86_64 "$wine_bin" "${frontend_args[@]}" "$@"
    else
      /usr/bin/arch -x86_64 "$wine_bin" "$@"
    fi
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
  local dir lock file pid existing mode state attempts=0 max_attempts="${CYDER_SESSION_LOCK_ATTEMPTS:-250}" owner
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
    state="$(sed -n 's/^state=//p' "$file" | head -1)"
    if { [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; } \
       && { [[ "$state" != background ]] || ! cyder_has_running_prefix "$prefix"; }; then
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
  if ! printf 'schema=2\npid=%s\nsync=msync=%s;esync=%s;power=%s\nmode=%s\nstate=running\nstarted_at=%s\n' \
      "$$" "$msync" "$esync" "$power" "$power" "$(date +%s)" >"$file"; then
    rm -rf "$lock"
    echo "failed to write Cyder session state" >&2
    return 1
  fi
  rm -rf "$lock"
  CYDER_SESSION_FILE="$file"
  export CYDER_SESSION_FILE
}

cyder_session_mark_background() {
  local session="$1" tmp
  [[ -f "$session" && ! -L "$session" ]] || return 1
  tmp="${session}.tmp.$$"
  if grep -q '^state=' "$session"; then
    sed 's/^state=.*/state=background/' "$session" >"$tmp" || { rm -f "$tmp"; return 1; }
  else
    { cat "$session"; printf 'state=background\n'; } >"$tmp" || { rm -f "$tmp"; return 1; }
  fi
  printf 'primary_exited_at=%s\n' "$(date +%s)" >>"$tmp"
  mv -f "$tmp" "$session"
}

# Publish all active Cyder bottles as an XML property list. A bottle remains
# active while either its wineserver socket exists or it has a live launch
# reservation. Dead primary PIDs in a background session are intentional.
cyder_write_active_bottles_plist() {
  local output="$1" tmp prefix file pid sync mode state started primary_exited
  tmp="${output}.tmp.$$"
  local bottle_index=0 session_index socket_live session_live bottle_live bottle_state
  rm -f "$tmp"
  /usr/bin/plutil -create xml1 "$tmp"
  /usr/bin/plutil -insert schemaVersion -integer 1 "$tmp"
  /usr/bin/plutil -insert bottles -array "$tmp"
  for prefix in "$CYDER_SUPPORT/bottles"/* "$CYDER_LEGACY_SHARED_PREFIX"; do
    [[ -d "$prefix" && ! -L "$prefix" ]] || continue
    socket_live=false
    cyder_has_running_prefix "$prefix" && socket_live=true
    session_live=false
    bottle_state=background
    for file in "$(cyder_session_dir "$prefix")"/*.session; do
      [[ -f "$file" && ! -L "$file" ]] || continue
      pid="$(sed -n 's/^pid=//p' "$file" | head -1)"
      state="$(sed -n 's/^state=//p' "$file" | head -1)"
      [[ -n "$state" ]] || state=running
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
        session_live=true
        [[ "$state" == running ]] && bottle_state=running
      elif [[ "$state" == background && "$socket_live" == true ]]; then
        session_live=true
      fi
    done
    bottle_live=false
    [[ "$socket_live" == true || "$session_live" == true ]] && bottle_live=true
    [[ "$bottle_live" == true ]] || continue
    /usr/bin/plutil -insert "bottles.$bottle_index" -dictionary "$tmp"
    /usr/bin/plutil -insert "bottles.$bottle_index.name" -string "$(basename "$prefix")" "$tmp"
    /usr/bin/plutil -insert "bottles.$bottle_index.prefix" -string "$(cd "$prefix" && pwd -P)" "$tmp"
    /usr/bin/plutil -insert "bottles.$bottle_index.running" -bool "$socket_live" "$tmp"
    /usr/bin/plutil -insert "bottles.$bottle_index.state" -string "$bottle_state" "$tmp"
    /usr/bin/plutil -insert "bottles.$bottle_index.sessions" -array "$tmp"
    session_index=0
    for file in "$(cyder_session_dir "$prefix")"/*.session; do
      [[ -f "$file" && ! -L "$file" ]] || continue
      pid="$(sed -n 's/^pid=//p' "$file" | head -1)"
      state="$(sed -n 's/^state=//p' "$file" | head -1)"; [[ -n "$state" ]] || state=running
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
        :
      elif [[ "$state" == background && "$socket_live" == true ]]; then
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || pid=0
      else
        continue
      fi
      sync="$(sed -n 's/^sync=//p' "$file" | head -1)"
      mode="$(sed -n 's/^mode=//p' "$file" | head -1)"
      started="$(sed -n 's/^started_at=//p' "$file" | head -1)"; [[ "$started" =~ ^[0-9]+$ ]] || started=0
      primary_exited="$(sed -n 's/^primary_exited_at=//p' "$file" | head -1)"; [[ "$primary_exited" =~ ^[0-9]+$ ]] || primary_exited=0
      /usr/bin/plutil -insert "bottles.$bottle_index.sessions.$session_index" -dictionary "$tmp"
      /usr/bin/plutil -insert "bottles.$bottle_index.sessions.$session_index.id" -string "$(basename "$file" .session)" "$tmp"
      /usr/bin/plutil -insert "bottles.$bottle_index.sessions.$session_index.pid" -integer "$pid" "$tmp"
      /usr/bin/plutil -insert "bottles.$bottle_index.sessions.$session_index.sync" -string "$sync" "$tmp"
      /usr/bin/plutil -insert "bottles.$bottle_index.sessions.$session_index.mode" -string "$mode" "$tmp"
      /usr/bin/plutil -insert "bottles.$bottle_index.sessions.$session_index.state" -string "$state" "$tmp"
      /usr/bin/plutil -insert "bottles.$bottle_index.sessions.$session_index.startedAt" -integer "$started" "$tmp"
      /usr/bin/plutil -insert "bottles.$bottle_index.sessions.$session_index.primaryExitedAt" -integer "$primary_exited" "$tmp"
      session_index=$((session_index + 1))
    done
    bottle_index=$((bottle_index + 1))
  done
  mv -f "$tmp" "$output"
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

# --- URI handler registry scanner (gamaniagames://) ---

cyder_json_escape_string() {
  local s=$1 c out='"'
  local i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      \\) out+='\\' ;;
      \") out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *) out+="$c" ;;
    esac
  done
  out+='"'
  printf '%s' "$out"
}

cyder_reg_unquote_value() {
  local raw=$1 val
  if [[ "$raw" == @=* ]]; then
    val="${raw#@=}"
  elif [[ "$raw" == \"*\"=\"* ]]; then
    val="${raw#*\"=\"}"
  else
    val="${raw#*=}"
  fi
  val="${val#\"}"
  val="${val%\"}"
  val="${val//\\\"/\"}"
  val="${val//\\\\/\\}"
  printf '%s' "$val"
}

cyder_resolve_windows_exe_path() {
  local prefix="$1" winpath="$2"
  local rest mac
  [[ "$winpath" =~ ^\"(.*)\"$ ]] && winpath="${BASH_REMATCH[1]}"
  [[ "$winpath" =~ ^[Cc]: ]] || return 1
  rest="${winpath:2}"
  rest="${rest//\\//}"
  [[ "$rest" != /* ]] && rest="/$rest"
  if [[ "$rest" == *".."* ]]; then
    return 1
  fi
  mac="$prefix/drive_c$rest"
  mac="$(cd "$(dirname "$mac")" 2>/dev/null && pwd -P)/$(basename "$mac")"
  [[ -f "$mac" && ! -L "$mac" ]] || return 1
  case "$(basename "$mac")" in
    *.exe | *.EXE) ;;
    *) return 1 ;;
  esac
  printf '%s' "$mac"
}

cyder_validate_uri_command() {
  local cmd="$1" exe_win
  [[ "$cmd" == \"*\"[[:space:]]*\"%1\" ]] || return 1
  if [[ "$cmd" =~ ^\"(.+)\"[[:space:]]+\"%1\"$ ]]; then
    exe_win="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  shopt -s nocasematch
  [[ "$exe_win" == *.exe ]] || { shopt -u nocasematch; return 1; }
  [[ "$exe_win" != *cmd.exe* && "$exe_win" != *powershell* && "$exe_win" != *.bat \
    && "$exe_win" != *.cmd ]] || { shopt -u nocasematch; return 1; }
  shopt -u nocasematch
  printf '%s' "$exe_win"
}

cyder_reg_extract_uri_snippet() {
  local regfile="$1" scheme="$2"
  local n1 n2 n3
  n1="[Software\\\\Classes\\\\${scheme}]"
  n2="[Software\\\\Classes\\\\${scheme}\\\\shell\\\\open\\\\command]"
  n3="[Software\\\\gamaniaGamesManager]"
  if command -v rg >/dev/null 2>&1; then
    rg -F --no-heading -A 40 -e "$n1" -e "$n2" -e "$n3" "$regfile" 2>/dev/null || true
  else
    grep -F -A 40 -e "$n1" -e "$n2" -e "$n3" "$regfile" 2>/dev/null || true
  fi
}

cyder_reg_read_uri_scheme() {
  local regfile="$1" scheme="$2"
  ROOT_TS=0 ROOT_URL_PROTOCOL=0 COMMAND="" COMMAND_TS=0 INSTALL_PATH="" VERSION=""
  [[ -f "$regfile" && ! -L "$regfile" ]] || return 1

  local root="Software\\\\Classes\\\\${scheme}"
  local cmd="${root}\\\\shell\\\\open\\\\command"
  local meta="Software\\\\gamaniaGamesManager"
  local sect="" line ts in_root=0 in_cmd=0 in_meta=0 has_proto=0 root_ts=0 cmd_ts=0
  local snippet
  snippet="$(cyder_reg_extract_uri_snippet "$regfile" "$scheme")"
  [[ -n "$snippet" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == \[* ]]; then
      in_root=0
      in_cmd=0
      in_meta=0
      ts=0
      if [[ "$line" =~ ^\[([^]]+)\][[:space:]]*([0-9]+)?[[:space:]]*$ ]]; then
        sect="${BASH_REMATCH[1]}"
        ts="${BASH_REMATCH[2]:-0}"
      else
        continue
      fi
      if [[ "$sect" == "$root" ]]; then
        in_root=1
        root_ts=$ts
      elif [[ "$sect" == "$cmd" ]]; then
        in_cmd=1
        cmd_ts=$ts
      elif [[ "$sect" == "$meta" ]]; then
        in_meta=1
      fi
      continue
    fi
    if (( in_root )) && [[ "$line" == '"URL Protocol"'* ]]; then
      has_proto=1
      continue
    fi
    if (( in_cmd )) && [[ "$line" == @=* ]]; then
      COMMAND="$(cyder_reg_unquote_value "$line")"
      continue
    fi
    if (( in_meta )) && [[ "$line" == '"InstallPath"'* ]]; then
      INSTALL_PATH="$(cyder_reg_unquote_value "$line")"
      continue
    fi
    if (( in_meta )) && [[ "$line" == '"Version"'* ]]; then
      VERSION="$(cyder_reg_unquote_value "$line")"
      continue
    fi
  done <<<"$snippet"

  [[ "$has_proto" -eq 1 && -n "$COMMAND" ]] || return 1
  COMMAND_TS=$(( cmd_ts > root_ts ? cmd_ts : root_ts ))
  ROOT_TS="$COMMAND_TS"
  return 0
}

cyder_scan_uri_handlers() {
  local prefix="$1" scheme="${2:-gamaniagames}"
  local system_reg="$prefix/system.reg" user_reg="$prefix/user.reg"
  local merged_cmd="" merged_ts=0 install_path="" version="" source=""
  local system_cmd="" user_cmd="" system_ts=0 user_ts=0

  if cyder_reg_read_uri_scheme "$user_reg" "$scheme"; then
    user_cmd="$COMMAND"
    user_ts="$COMMAND_TS"
    merged_cmd="$user_cmd"
    merged_ts="$user_ts"
    install_path="$INSTALL_PATH"
    version="$VERSION"
    source="user"
  fi
  if cyder_reg_read_uri_scheme "$system_reg" "$scheme"; then
    system_cmd="$COMMAND"
    system_ts="$COMMAND_TS"
    if [[ -z "$merged_cmd" ]]; then
      merged_cmd="$system_cmd"
      merged_ts="$system_ts"
      install_path="$INSTALL_PATH"
      version="$VERSION"
      source="system"
    fi
  fi

  local status="missing" windows_command="" resolved="" exe_win
  if [[ -n "$merged_cmd" ]]; then
    windows_command="$merged_cmd"
    if exe_win="$(cyder_validate_uri_command "$merged_cmd")"; then
      if resolved="$(cyder_resolve_windows_exe_path "$prefix" "$exe_win")"; then
        status="valid"
      else
        status="stale"
      fi
    else
      status="unsupported"
    fi
  fi

  if [[ -z "$install_path" && -n "$exe_win" ]]; then
    install_path="$exe_win"
    install_path="${install_path%\\*}"
  fi

  printf '[{"scheme":%s,"sectionTimestamp":%s,"windowsCommand":%s,"resolvedExecutable":%s,"installPath":%s,"version":%s,"status":%s,"source":%s}]' \
    "$(cyder_json_escape_string "$scheme")" \
    "${merged_ts:-0}" \
    "$(cyder_json_escape_string "$windows_command")" \
    "$(cyder_json_escape_string "$resolved")" \
    "$(cyder_json_escape_string "$install_path")" \
    "$(cyder_json_escape_string "$version")" \
    "$(cyder_json_escape_string "$status")" \
    "$(cyder_json_escape_string "$source")"
}
