#!/usr/bin/env bash
# Copy prebuilt engine artifact into app Resources (shared by Cyder / CyderBits).
set -euo pipefail

copy_engine_artifact_into_app() {
  local script_dir="$1"
  local res_dir="$2"
  local ogom="$3"

  export OGOM="$ogom"
  # shellcheck source=cyder-common.sh
  source "$script_dir/cyder-common.sh"

  local artifacts version archive
  artifacts="$(cyder_engine_artifacts_dir)"
  if [[ ! -f "$artifacts/engine-version.txt" ]] || [[ "${CYDER_PACK_ENGINE:-0}" == 1 ]]; then
    bash "$script_dir/pack-engine-artifact.sh"
  fi
  [[ -f "$artifacts/engine-version.txt" ]] || {
    echo "Missing $artifacts/engine-version.txt — run pack-engine-artifact.sh first." >&2
    exit 1
  }
  version="$(tr -d '[:space:]' < "$artifacts/engine-version.txt")"
  archive="$(cyder_engine_archive_path "$version" "$artifacts")"
  [[ -f "$archive" ]] || {
    echo "Missing engine archive: $archive" >&2
    exit 1
  }

  cp "$archive" "$res_dir/"
  cp "$artifacts/engine-version.txt" "$res_dir/engine-version.txt"
  echo "==> Bundled engine artifact: $(basename "$archive") ($(du -sh "$archive" | awk '{print $1}'))"
}
