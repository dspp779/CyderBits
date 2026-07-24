#!/usr/bin/env bash
# Extract llvm-mingw and CrossOver source archives from tools/archives/ into build/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${OGOM:-}" ]]; then
  export OGOM="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

ARCHIVES_DIR="${OGOM_ARCHIVES_DIR:-$OGOM/tools/archives}"
BUILD_DIR="${OGOM_BUILD_DIR:-$OGOM/build}"
LLVM_MINGW_NAME="llvm-mingw-20260616-ucrt-macos-universal"
LLVM_MINGW_ARCHIVE="$ARCHIVES_DIR/${LLVM_MINGW_NAME}.tar.xz"
LLVM_MINGW_DIR="$BUILD_DIR/$LLVM_MINGW_NAME"

DRY_RUN=0
FORCE=0
CX_VERSIONS=()

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Extract build inputs from $ARCHIVES_DIR into $BUILD_DIR.

Options:
  --cx 25|26       Prepare CrossOver sources for CX25 or CX26 (repeatable)
  --all            Prepare CX25 and CX26 sources
  --dry-run        Print commands without extracting
  --force          Re-extract even when markers already exist
  -h, --help       Show this help
EOF
}

cx_archive_for() {
  case "$1" in
    25) printf '%s\n' "$ARCHIVES_DIR/crossover-sources-25.1.1.tar.gz" ;;
    26) printf '%s\n' "$ARCHIVES_DIR/crossover-sources-26.3.0.tar.gz" ;;
    *)
      echo "Unknown CX version: $1 (expected 25 or 26)" >&2
      return 1
      ;;
  esac
}

cx_wine_src_for() {
  printf '%s/cx%s/sources/wine\n' "$BUILD_DIR" "$1"
}

ensure_llvm_mingw() {
  local marker="$LLVM_MINGW_DIR/bin/x86_64-w64-mingw32-clang"
  if [[ -x "$marker" && "$FORCE" -eq 0 ]]; then
    echo "llvm-mingw already present at $LLVM_MINGW_DIR"
    return 0
  fi
  [[ -f "$LLVM_MINGW_ARCHIVE" ]] || {
    echo "Missing archive: $LLVM_MINGW_ARCHIVE" >&2
    exit 1
  }
  if [[ "$FORCE" -eq 1 && -d "$LLVM_MINGW_DIR" ]]; then
    echo "Removing existing $LLVM_MINGW_DIR (--force)"
    run rm -rf "$LLVM_MINGW_DIR"
  fi
  echo "Extracting llvm-mingw to $BUILD_DIR"
  run mkdir -p "$BUILD_DIR"
  run tar -xJf "$LLVM_MINGW_ARCHIVE" -C "$BUILD_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  [[ -x "$marker" ]] || {
    echo "llvm-mingw extract failed: missing $marker" >&2
    exit 1
  }
}

ensure_cx_sources() {
  local ver="$1"
  local archive dest marker
  archive="$(cx_archive_for "$ver")"
  dest="$BUILD_DIR/cx$ver"
  marker="$(cx_wine_src_for "$ver")/configure"

  if [[ -f "$marker" && "$FORCE" -eq 0 ]]; then
    echo "CX$ver sources already present at $(cx_wine_src_for "$ver")"
    return 0
  fi
  [[ -f "$archive" ]] || {
    echo "Missing archive: $archive" >&2
    exit 1
  }
  if [[ "$FORCE" -eq 1 && -d "$dest" ]]; then
    echo "Removing existing $dest (--force)"
    run rm -rf "$dest"
  fi
  echo "Extracting CX$ver sources to $dest"
  run mkdir -p "$dest"
  run tar -xzf "$archive" -C "$dest"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  [[ -f "$marker" ]] || {
    echo "CX$ver extract failed: missing $marker" >&2
    exit 1
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cx)
      [[ $# -ge 2 ]] || { echo "Missing value for --cx" >&2; exit 1; }
      CX_VERSIONS+=("$2")
      shift 2
      ;;
    --all)
      CX_VERSIONS+=(25 26)
      shift
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ${#CX_VERSIONS[@]} -eq 0 ]]; then
  CX_VERSIONS=(25 26)
fi

ensure_llvm_mingw
for ver in "${CX_VERSIONS[@]}"; do
  case "$ver" in
    25 | 26) ensure_cx_sources "$ver" ;;
    *)
      echo "Unknown CX version: $ver (expected 25 or 26)" >&2
      exit 1
      ;;
  esac
done

echo "Prepare complete."
