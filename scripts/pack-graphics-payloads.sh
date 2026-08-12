#!/usr/bin/env bash
# Pack DXVK and DXMT independently from the Wine engine archive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cyder-common.sh"
source "$SCRIPT_DIR/env-x86_64.sh"

ENGINE="${WINE_INSTALL:-}"
OUTPUT_DIR=""
FORCE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--engine PATH] [--output-dir PATH] [--force]

Package ENGINE/lib/dxvk and lib/dxmt as independent zstd graphics
payloads. Archives and version/checksum sidecars are written to
dist/artifacts/graphics by default.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="${2:?Missing value for --engine}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:?Missing value for --output-dir}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -d "$ENGINE/lib/dxvk" ]] || { echo "Missing DXVK payload: $ENGINE/lib/dxvk" >&2; exit 1; }
[[ -d "$ENGINE/lib/dxmt" ]] || { echo "Missing DXMT payload: $ENGINE/lib/dxmt" >&2; exit 1; }
ZSTD_BIN="$(cyder_find_zstd 2>/dev/null || true)"
[[ -x "$ZSTD_BIN" ]] || { echo "Missing bundled zstd" >&2; exit 1; }
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$(cyder_engine_artifacts_dir)/graphics"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

payload_version() {
  local name="$1" dir="$2" version_file version="" env_name name_upper
  version_file="$dir/version"
  name_upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
  env_name="CYDER_${name_upper}_VERSION"
  if [[ -n "${!env_name:-}" ]]; then
    version="${!env_name}"
  elif [[ -f "$version_file" ]]; then
    version="$(awk 'NR == 1 { print $2; exit }' "$version_file")"
    [[ -n "$version" ]] || version="$(head -n 1 "$version_file")"
  fi
  version="${version#v}"
  version="${version//[^A-Za-z0-9._-]/-}"
  printf '%s\n' "${version:-unknown}"
}

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/cyder-graphics-pack.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

pack_payload() {
  local name="$1" source="$2" version archive version_file checksum_file staged
  version="$(payload_version "$name" "$source")"
  archive="$OUTPUT_DIR/$name-$version.tar.zst"
  version_file="$OUTPUT_DIR/$name-version.txt"
  checksum_file="$OUTPUT_DIR/$name-artifact-sha256.txt"
  staged="$STAGING/$name"
  if [[ -f "$archive" && "$FORCE" -ne 1 ]]; then
    echo "Graphics artifact present: $archive"
  else
    rm -rf "$staged"
    cp -R "$source" "$staged"
    if [[ "$name" == dxvk ]]; then
      python3 "$SCRIPT_DIR/stamp-wine-builtin-pe.py" "$staged"
    fi
    (
      cd "$STAGING"
      tar -cf - "$name" | "$ZSTD_BIN" -22 --ultra -T0 -o "$archive"
    )
  fi
  printf '%s\n' "$version" >"$version_file"
  printf '%s  %s\n' "$(shasum -a 256 "$archive" | awk '{print $1}')" "$(basename "$archive")" >"$checksum_file"
  echo "Created graphics artifact: $archive"
}

pack_payload dxvk "$ENGINE/lib/dxvk"
pack_payload dxmt "$ENGINE/lib/dxmt"
