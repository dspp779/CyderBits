#!/usr/bin/env bash
# Fail-closed acceptance checks for Cyder.app / Cyder.app.zip release artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OGOM_ROOT="$(cd "$SKILL_ROOT/../../.." && pwd)"

APP=""
ZIP=""
BASELINE=""
SKIP_NOTARIZATION=0

DXVK_MIN_BYTES="${CYDER_VERIFY_DXVK_MIN_BYTES:-2097152}"
DXMT_MIN_BYTES="${CYDER_VERIFY_DXMT_MIN_BYTES:-8388608}"
ZIP_SIZE_SLACK_BYTES=1048576

usage() {
  cat <<EOF
Usage: $(basename "$0") --app PATH --zip PATH [--baseline PATH] [--skip-notarization-checks]

Require at least one of --app / --zip. Exit 0 on pass; non-zero on failure.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

file_size() {
  local path="$1"
  if stat -f%z "$path" >/dev/null 2>&1; then
    stat -f%z "$path"
  else
    stat -c%s "$path"
  fi
}

resolve_zstd() {
  local -a candidates=("${CYDER_ZSTD:-}")
  candidates+=("$OGOM_ROOT/tools/zstd/zstd")
  if command -v zstd >/dev/null 2>&1; then
    candidates+=("$(command -v zstd)")
  fi
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:?Missing value for --app}"; shift 2 ;;
    --zip) ZIP="${2:?Missing value for --zip}"; shift 2 ;;
    --baseline) BASELINE="${2:?Missing value for --baseline}"; shift 2 ;;
    --skip-notarization-checks) SKIP_NOTARIZATION=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$APP" || -n "$ZIP" ]] || {
  usage >&2
  die "Require at least one of --app / --zip"
}

ZSTD="$(resolve_zstd)" || die "Missing zstd (set CYDER_ZSTD or build tools/zstd/zstd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyder-release-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

RESOURCES=""
if [[ -n "$APP" ]]; then
  [[ -d "$APP" ]] || die "Missing --app: $APP"
  RESOURCES="$APP/Contents/Resources"
  [[ -d "$RESOURCES" ]] || die "Missing Resources: $RESOURCES"
elif [[ -n "$ZIP" ]]; then
  [[ -f "$ZIP" ]] || die "Missing --zip: $ZIP"
  mkdir -p "$WORK/extracted"
  unzip -q "$ZIP" "Cyder.app/Contents/Resources/graphics/*" \
    "Cyder.app/Contents/Resources/engine-version.txt" \
    "Cyder.app/Contents/Resources/engine-*.tar.zst" \
    -d "$WORK/extracted" 2>/dev/null || true
  RESOURCES="$WORK/extracted/Cyder.app/Contents/Resources"
  [[ -d "$RESOURCES" ]] || die "Could not extract Resources from zip: $ZIP"
fi

GRAPHICS="$RESOURCES/graphics"
[[ -d "$GRAPHICS" ]] || die "Missing graphics dir: $GRAPHICS"

pick_one_archive() {
  local prefix="$1"
  local -a matches=()
  local f
  shopt -s nullglob
  for f in "$GRAPHICS/${prefix}"-*.tar.zst; do
    [[ "$(basename "$f")" == ._* ]] && continue
    matches+=("$f")
  done
  shopt -u nullglob
  [[ ${#matches[@]} -ge 1 ]] || return 1
  printf '%s\n' "${matches[0]}"
}

inspect_graphics_archive() {
  local archive="$1" label="$2" min_bytes="$3" marker="$4"
  local sz listing first
  [[ -f "$archive" ]] || die "Missing $label archive"
  sz="$(file_size "$archive")"
  if (( sz < min_bytes )); then
    die "$label archive too small: $archive ($sz bytes < $min_bytes)"
  fi
  listing="$("$ZSTD" -dc "$archive" | tar -tv 2>/dev/null || true)"
  [[ -n "$listing" ]] || die "$label archive is not a readable tar.zst: $archive"
  first="$(printf '%s\n' "$listing" | head -n 1)"
  if [[ "$first" == l* ]]; then
    die "$label archive top entry is a symlink (stub pack): $archive"$'\n'"  $first"
  fi
  # Also fail if any top-level payload path is only a symlink named dxvk/dxmt.
  if printf '%s\n' "$listing" | grep -E '^l' | grep -Eq "(^|[[:space:]])${label}($|[[:space:]]|->)" ; then
    if ! printf '%s\n' "$listing" | grep -q "$marker"; then
      die "$label archive contains symlink payload without $marker: $archive"
    fi
  fi
  printf '%s\n' "$listing" | grep -q "$marker" || \
    die "$label archive missing expected member $marker: $archive"
}

DXVK_ARCHIVE="$(pick_one_archive dxvk)" || die "Missing graphics/dxvk-*.tar.zst under $GRAPHICS"
DXMT_ARCHIVE="$(pick_one_archive dxmt)" || die "Missing graphics/dxmt-*.tar.zst under $GRAPHICS"

inspect_graphics_archive "$DXVK_ARCHIVE" "dxvk" "$DXVK_MIN_BYTES" "d3d11.dll"
inspect_graphics_archive "$DXMT_ARCHIVE" "dxmt" "$DXMT_MIN_BYTES" "winemetal.so"

ENGINE_VERSION_FILE="$RESOURCES/engine-version.txt"
[[ -f "$ENGINE_VERSION_FILE" ]] || die "Missing engine-version.txt"
ENGINE_LABEL="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$ENGINE_VERSION_FILE" | head -n 1 || true)"
[[ -n "$ENGINE_LABEL" ]] || die "engine-version.txt is empty"

shopt -s nullglob
ENGINE_ARCHIVES=()
for f in "$RESOURCES"/engine-*.tar.zst; do
  base="$(basename "$f")"
  [[ "$base" == ._* ]] && continue
  ENGINE_ARCHIVES+=("$f")
done
shopt -u nullglob
[[ ${#ENGINE_ARCHIVES[@]} -ge 1 ]] || die "Missing Resources/engine-*.tar.zst"

PIN_FILE="$OGOM_ROOT/config/cyder-engine-version.txt"
if [[ -f "$PIN_FILE" ]]; then
  PIN_LABEL="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PIN_FILE" | head -n 1 || true)"
  if [[ -n "$PIN_LABEL" && "$PIN_LABEL" != "$ENGINE_LABEL" ]]; then
    # Allow hyphen/dot slug equivalence loosely: compare alnum-only.
    pin_norm="${PIN_LABEL//[^A-Za-z0-9]/}"
    eng_norm="${ENGINE_LABEL//[^A-Za-z0-9]/}"
    if [[ "$pin_norm" != "$eng_norm" ]]; then
      die "engine-version.txt ($ENGINE_LABEL) does not match pin $PIN_FILE ($PIN_LABEL)"
    fi
  fi
fi

if [[ -n "$ZIP" ]]; then
  [[ -f "$ZIP" ]] || die "Missing --zip: $ZIP"
fi

if [[ -n "$BASELINE" ]]; then
  [[ -f "$BASELINE" ]] || die "Missing --baseline: $BASELINE"
  [[ -n "$ZIP" && -f "$ZIP" ]] || die "--baseline requires an existing --zip"
  zip_sz="$(file_size "$ZIP")"
  base_sz="$(file_size "$BASELINE")"
  if (( zip_sz + ZIP_SIZE_SLACK_BYTES < base_sz )); then
    die "Release zip too small vs baseline: $ZIP ($zip_sz) << $BASELINE ($base_sz) (slack ${ZIP_SIZE_SLACK_BYTES})"
  fi
fi

if [[ "$SKIP_NOTARIZATION" -eq 0 ]]; then
  [[ -n "$APP" && -d "$APP" ]] || die "Notarization checks require --app"
  spctl -a -vv --type execute "$APP" >/dev/null || die "spctl rejected $APP"
  xcrun stapler validate "$APP" >/dev/null || die "stapler validate failed for $APP"
fi

echo "PASS cyder-release-verify"
echo "  engine: $ENGINE_LABEL"
echo "  dxvk:   $DXVK_ARCHIVE ($(file_size "$DXVK_ARCHIVE") bytes)"
echo "  dxmt:   $DXMT_ARCHIVE ($(file_size "$DXMT_ARCHIVE") bytes)"
[[ -n "$ZIP" ]] && echo "  zip:    $ZIP ($(file_size "$ZIP") bytes)"
