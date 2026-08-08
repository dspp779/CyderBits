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
    {
      printf '+'
      printf ' %q' "$@"
      printf '\n'
    } >&2
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

payload_complete() {
  local dir="$1"
  [[ -f "$dir/x86_64-windows/d3d11.dll" ]] || return 1
  [[ -f "$dir/x86_64-windows/dxgi.dll" ]] || return 1
  [[ -f "$dir/i386-windows/d3d11.dll" ]] || return 1
  [[ -f "$dir/i386-windows/dxgi.dll" ]] || return 1
  [[ -f "$dir/x86_64-unix/winemetal.so" ]] || return 1
  return 0
}

payload_incomplete_error() {
  local dir="$1"
  local rel
  for rel in \
    x86_64-windows/d3d11.dll \
    x86_64-windows/dxgi.dll \
    i386-windows/d3d11.dll \
    i386-windows/dxgi.dll \
    x86_64-unix/winemetal.so
  do
    if [[ ! -f "$dir/$rel" ]]; then
      echo "DXMT payload missing required $rel (product needs both i386 and x86_64)" >&2
      return 0
    fi
  done
}

find_payload_root() {
  local extract_dir="$1"
  local winemetal parent

  while IFS= read -r -d '' winemetal; do
    parent="$(cd "$(dirname "$winemetal")/.." && pwd -P)"
    if payload_complete "$parent"; then
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

    if payload_complete "$stage"; then
      printf '%s\n' "$stage"
      return 0
    fi
    payload_incomplete_error "$stage" || true
    return 1
  fi

  echo "Could not locate DXMT payload under $extract_dir" >&2
  echo "Found paths:" >&2
  find "$extract_dir" -type f 2>/dev/null | sed 's/^/  /' >&2 || true
  return 1
}

# DXMT v0.80 (the last release before upstream 3Shain/dxmt relicensed to
# LGPL) ships under the MIT License. Cyder pins v0.80, so this text is
# hard-coded rather than trusted to whatever (if anything) the upstream
# tarball happens to contain — the upstream archive under test/CI use does
# not always include a LICENSE file.
read -r -d '' DXMT_MIT_LICENSE <<'EOF' || true
MIT License

Copyright (c) 2023 Feifan He

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

write_dxmt_license() {
  local dest="$1"
  if (( DRY_RUN )); then
    run bash -c "cat >\"$dest/LICENSE\" <<'LICEOF'
$DXMT_MIT_LICENSE
LICEOF"
  else
    printf '%s\n' "$DXMT_MIT_LICENSE" >"$dest/LICENSE"
  fi
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
  if ! payload_complete "$payload"; then
    payload_incomplete_error "$payload" || true
    return 1
  fi
  run mkdir -p "$dest/lib/dxmt"
  run rm -rf "$dest/lib/dxmt"
  run mkdir -p "$dest/lib/dxmt"
  run cp -R "$payload/." "$dest/lib/dxmt/"
  ensure_winemetal_layout "$dest/lib/dxmt" || true
  # Always write our own pinned MIT LICENSE text, regardless of whether the
  # upstream tarball happened to include one, so a redistributed engine
  # artifact never ships lib/dxmt/ without a license file.
  write_dxmt_license "$dest/lib/dxmt"
  if (( ! DRY_RUN )); then
    cat >"$dest/lib/dxmt/version" <<EOF
dxmt ${DXMT_VERSION}
source ${DXMT_URL}
sha256 ${DXMT_SHA256}
license MIT (see LICENSE)
EOF
  else
    run bash -c "cat >\"$dest/lib/dxmt/version\" <<EOF
dxmt ${DXMT_VERSION}
source ${DXMT_URL}
sha256 ${DXMT_SHA256}
license MIT (see LICENSE)
EOF"
  fi
  if (( ! DRY_RUN )); then
    payload_complete "$dest/lib/dxmt" || return 1
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
  # `set -e` treats a false `[[ ... ]] && cmd` as the trap's own failure and
  # would overwrite an already-decided exit code (e.g. a clean `exit 0`) with
  # 1; use `if` so an unset/absent TMP_DIR always leaves the trap at status 0.
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

archive="$(resolve_tarball)"
if (( DRY_RUN )) && [[ -z "$TARBALL" ]] && [[ ! -f "$archive" ]]; then
  # Dry run with no local --tarball and nothing cached yet: the download
  # itself was only echoed above (see `run curl`/`run mv`), so there is no
  # file to checksum or extract. Report the plan and stop cleanly instead of
  # letting verify_sha256 fail on a missing file.
  echo "Dry run: would download ${DXMT_URL} to ${archive}, verify sha256 ${DXMT_SHA256}," \
    "then install into: ${ENGINE}${ALSO_ENGINES[*]:+ ${ALSO_ENGINES[*]}}" >&2
  echo "Dry run complete for DXMT ${DXMT_VERSION} (no cached/local tarball; download skipped)" >&2
  exit 0
fi
verify_sha256 "$archive" "$DXMT_SHA256"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cyder-dxmt-extract.XXXXXX")"
extract_dir="$TMP_DIR/extract"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir"

payload_root="$(find_payload_root "$extract_dir")"

targets=("$ENGINE")
if ((${#ALSO_ENGINES[@]} > 0)); then
  targets+=("${ALSO_ENGINES[@]}")
fi

for target in "${targets[@]}"; do
  install_dxmt_into_engine "$target" "$payload_root"
done

if (( DRY_RUN )); then
  echo "Dry run complete for DXMT ${DXMT_VERSION}" >&2
else
  echo "Installed DXMT ${DXMT_VERSION} into ${#targets[@]} engine(s)"
fi
