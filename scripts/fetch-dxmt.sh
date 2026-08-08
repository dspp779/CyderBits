#!/usr/bin/env bash
# Fetch pinned upstream DXMT and install into Wine engine lib/dxmt/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DXMT_VERSION="${CYDER_DXMT_VERSION:-v0.80}"
DXMT_URL="${CYDER_DXMT_URL:-https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz}"
DXMT_SHA256="${CYDER_DXMT_SHA256:-8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d}"
CACHE_DIR="${CYDER_DXMT_CACHE:-$ROOT/tools/caches/dxmt}"
ENGINE=""
ALSO_ENGINES=()
TARBALL=""
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --engine /abs/path [options]

Download (or reuse) pinned upstream DXMT and install into Wine engine lib/dxmt/.

Options:
  --engine PATH         Primary engine install root (required, absolute path)
  --also-engine PATH    Additional engine install root (repeatable)
  --cache-dir PATH      Download cache directory (default: tools/caches/dxmt)
  --tarball PATH        Use a local tarball instead of downloading
  --dry-run             Print commands without executing
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      [[ $# -ge 2 ]] || { echo "Missing value for --engine" >&2; exit 1; }
      ENGINE="$2"
      shift 2
      ;;
    --also-engine)
      [[ $# -ge 2 ]] || { echo "Missing value for --also-engine" >&2; exit 1; }
      ALSO_ENGINES+=("$2")
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for --cache-dir" >&2; exit 1; }
      CACHE_DIR="$2"
      shift 2
      ;;
    --tarball)
      [[ $# -ge 2 ]] || { echo "Missing value for --tarball" >&2; exit 1; }
      TARBALL="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$ENGINE" ]] || { echo "Missing required --engine" >&2; usage >&2; exit 1; }

run() {
  if (( DRY_RUN )); then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

verify_sha256() {
  local file="$1" expect="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expect" ]]; then
    echo "DXMT checksum mismatch for $file" >&2
    echo "  expected: $expect" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}

find_payload_root() {
  local extract_dir="$1"
  local winemetal parent

  while IFS= read -r -d '' winemetal; do
    parent="$(cd "$(dirname "$winemetal")/.." && pwd -P)"
    if [[ -f "$parent/x86_64-windows/d3d11.dll" && -f "$parent/x86_64-windows/dxgi.dll" ]]; then
      printf '%s\n' "$parent"
      return 0
    fi
  done < <(find "$extract_dir" -path '*/x86_64-unix/winemetal.so' -print0 2>/dev/null)

  local winemetal_path d3d11_path unix_src windows_src stage
  winemetal_path="$(find "$extract_dir" -path '*/x86_64-unix/winemetal.so' -print -quit 2>/dev/null || true)"
  d3d11_path="$(find "$extract_dir" -path '*/x86_64-windows/d3d11.dll' -print -quit 2>/dev/null || true)"

  if [[ -n "$winemetal_path" && -n "$d3d11_path" ]]; then
    unix_src="$(cd "$(dirname "$winemetal_path")" && pwd -P)"
    windows_src="$(cd "$(dirname "$d3d11_path")" && pwd -P)"
    stage="$extract_dir/_assembled"
    rm -rf "$stage"
    mkdir -p "$stage/x86_64-unix" "$stage/x86_64-windows"
    cp -R "$unix_src/." "$stage/x86_64-unix/"
    cp -R "$windows_src/." "$stage/x86_64-windows/"

    local d3d11_32_path i386_src
    d3d11_32_path="$(find "$extract_dir" -path '*/i386-windows/d3d11.dll' -print -quit 2>/dev/null || true)"
    if [[ -n "$d3d11_32_path" ]]; then
      i386_src="$(cd "$(dirname "$d3d11_32_path")" && pwd -P)"
      mkdir -p "$stage/i386-windows"
      cp -R "$i386_src/." "$stage/i386-windows/"
    fi

    local license_path
    while IFS= read -r -d '' license_path; do
      cp "$license_path" "$stage/LICENSE"
      break
    done < <(find "$extract_dir" \( -iname 'LICENSE' -o -iname 'LICENSE.*' \) -type f -print0 2>/dev/null)

    printf '%s\n' "$stage"
    return 0
  fi

  echo "Could not locate DXMT payload under $extract_dir" >&2
  echo "Found paths:" >&2
  find "$extract_dir" -type f 2>/dev/null | sed 's/^/  /' >&2 || true
  return 1
}

ensure_winemetal_layout() {
  local dest="$1"
  if [[ -f "$dest/x86_64-unix/winemetal.so" ]]; then
    return 0
  fi

  local winemetal_path
  winemetal_path="$(find "$dest" -name 'winemetal.so' -print -quit 2>/dev/null || true)"
  [[ -n "$winemetal_path" ]] || return 1
  run mkdir -p "$dest/x86_64-unix"
  run cp -f "$winemetal_path" "$dest/x86_64-unix/winemetal.so"
}

install_dxmt_into_engine() {
  local dest="$1" payload="$2"
  [[ "$dest" == /* ]] || { echo "Engine path must be absolute: $dest" >&2; return 1; }
  run mkdir -p "$dest/lib/dxmt"
  run rm -rf "$dest/lib/dxmt"
  run mkdir -p "$dest/lib/dxmt"
  run cp -R "$payload/." "$dest/lib/dxmt/"
  ensure_winemetal_layout "$dest/lib/dxmt" || true
  if (( ! DRY_RUN )); then
    cat >"$dest/lib/dxmt/version" <<EOF
dxmt ${DXMT_VERSION}
source ${DXMT_URL}
sha256 ${DXMT_SHA256}
EOF
  else
    run bash -c "cat >\"$dest/lib/dxmt/version\" <<EOF
dxmt ${DXMT_VERSION}
source ${DXMT_URL}
sha256 ${DXMT_SHA256}
EOF"
  fi
  if (( ! DRY_RUN )); then
    [[ -f "$dest/lib/dxmt/x86_64-windows/d3d11.dll" ]] || return 1
    [[ -f "$dest/lib/dxmt/x86_64-windows/dxgi.dll" ]] || return 1
    [[ -f "$dest/lib/dxmt/x86_64-unix/winemetal.so" ]] || return 1
  fi
}

resolve_tarball() {
  if [[ -n "$TARBALL" ]]; then
    [[ -f "$TARBALL" ]] || { echo "Missing tarball: $TARBALL" >&2; exit 1; }
    printf '%s\n' "$TARBALL"
    return 0
  fi

  run mkdir -p "$CACHE_DIR"
  local archive="$CACHE_DIR/$(basename "$DXMT_URL")"
  if [[ ! -f "$archive" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      echo "curl is required to download DXMT" >&2
      exit 1
    fi
    run curl -fsSL -o "$archive.part" "$DXMT_URL"
    run mv -f "$archive.part" "$archive"
  fi
  printf '%s\n' "$archive"
}

TMP_DIR=""
cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

archive="$(resolve_tarball)"
verify_sha256 "$archive" "$DXMT_SHA256"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cyder-dxmt-extract.XXXXXX")"
extract_dir="$TMP_DIR/extract"
run mkdir -p "$extract_dir"
if (( DRY_RUN )); then
  run tar -xzf "$archive" -C "$extract_dir"
else
  tar -xzf "$archive" -C "$extract_dir"
fi

payload_root=""
if (( DRY_RUN )); then
  payload_root="$extract_dir"
else
  payload_root="$(find_payload_root "$extract_dir")"
fi

targets=("$ENGINE")
if ((${#ALSO_ENGINES[@]} > 0)); then
  targets+=("${ALSO_ENGINES[@]}")
fi

for target in "${targets[@]}"; do
  install_dxmt_into_engine "$target" "$payload_root"
done

if (( DRY_RUN )); then
  echo "Dry run complete for DXMT ${DXMT_VERSION}"
else
  echo "Installed DXMT ${DXMT_VERSION} into ${#targets[@]} engine(s)"
fi
