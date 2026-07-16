#!/usr/bin/env bash
# Copy prebuilt engine artifact into app Resources (shared by Cyder / CyderBits).
set -euo pipefail

cyder_write_app_engine_metadata() {
  local res_dir="$1"
  local archive_path="$2"
  local version_label="$3"
  printf '%s\n' "$version_label" >"$res_dir/engine-version.txt"
  printf '%s\n' "$(basename "$archive_path")" >"$res_dir/engine-archive.txt"
}

copy_engine_artifact_into_app() {
  local script_dir="$1"
  local res_dir="$2"
  local ogom="$3"

  export OGOM="$ogom"
  # shellcheck source=cyder-common.sh
  source "$script_dir/cyder-common.sh"

  local artifacts version archive format
  local override override_ver dest_archive

  override="${CYDER_BUNDLED_ENGINE_ARCHIVE:-}"
  override_ver="${CYDER_BUNDLED_ENGINE_VERSION:-}"
  if [[ -n "$override" ]]; then
    override="$(cyder_abs_path "$override")"
    [[ -f "$override" ]] || {
      echo "Missing CYDER_BUNDLED_ENGINE_ARCHIVE: $override" >&2
      exit 1
    }
    if [[ -z "$override_ver" ]]; then
      override_ver="$(cyder_engine_version_from_tarball "$override" 2>/dev/null || true)"
    fi
    if [[ -z "$override_ver" ]]; then
      override_ver="$(cyder_engine_version_from_archive "$override")"
    fi
    dest_archive="$res_dir/$(basename "$override")"
    cp "$override" "$dest_archive"
    xattr -c "$dest_archive" 2>/dev/null || true
    cyder_write_app_engine_metadata "$res_dir" "$dest_archive" "$override_ver"
    echo "==> Bundled engine archive: $(basename "$dest_archive") ($(du -sh "$override" | awk '{print $1}'))"
    echo "==> Engine version: $override_ver"
    return 0
  fi

  format="${CYDER_ENGINE_FORMAT:-xz}"
  if [[ "$format" == "zstd" ]]; then
    format="zst"
  fi
  artifacts="$(cyder_engine_artifacts_dir)"
  if [[ ! -f "$artifacts/engine-version.txt" ]] || [[ "${CYDER_PACK_ENGINE:-0}" == 1 ]]; then
    bash "$script_dir/pack-engine-artifact.sh" --format "$format"
  fi
  [[ -f "$artifacts/engine-version.txt" ]] || {
    echo "Missing $artifacts/engine-version.txt — run pack-engine-artifact.sh first." >&2
    exit 1
  }
  version="$(cyder_engine_version_label_trim "$(cat "$artifacts/engine-version.txt")")"
  archive="$(cyder_engine_archive_path_for_format "$(cyder_engine_version_slug_from_label "$version")" "$artifacts" "$format")"
  if [[ ! -f "$archive" ]]; then
    archive="$(cyder_engine_archive_path_for_format "$version" "$artifacts" "$format")"
  fi
  [[ -f "$archive" ]] || {
    echo "Missing engine archive: $archive" >&2
    exit 1
  }

  dest_archive="$res_dir/$(basename "$archive")"
  cp "$archive" "$dest_archive"
  xattr -c "$dest_archive" 2>/dev/null || true
  cyder_write_app_engine_metadata "$res_dir" "$dest_archive" "$version"
  echo "==> Bundled engine artifact: $(basename "$archive") ($(du -sh "$archive" | awk '{print $1}'))"
  echo "==> Engine version: $version"
}
