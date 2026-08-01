#!/usr/bin/env bash
# Install Cyder MoltenVK timeline-wait poll shim into an extracted engine tree.
# See docs/maplestory-classic-dxvk-ports-leak.md and
# cyder-wine-engine/docs/moltenvk-timeline-wait-poll-app-overlay.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${CYDER_MVK_WAIT_POLL_SRC:-$ROOT/tools/cyder-mvk-timeline-wait-poll/cyder_mvk_timeline_wait_poll.m}"
STAGE="${CYDER_MVK_WAIT_POLL_STAGE:-$ROOT/build/cyder-mvk-timeline-wait-poll}"
BUNDLED_SHIM=""
ENGINE=""
UNDO=0
MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-10.15}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --engine ENGINE_ROOT [options]

Options:
  --engine PATH         Extracted Wine engine root (…/wine-x86_64)
  --bundled-shim PATH   Prebuilt x86_64 shim dylib (skip clang)
  --undo                Restore libMoltenVK.real.dylib → libMoltenVK.dylib
  -h, --help            Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      ENGINE="${2:-}"
      shift 2
      ;;
    --bundled-shim)
      BUNDLED_SHIM="${2:-}"
      shift 2
      ;;
    --undo) UNDO=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$ENGINE" ]] || {
  echo "--engine is required" >&2
  usage >&2
  exit 1
}

unix_lib() {
  printf '%s/lib/wine/x86_64-unix\n' "$1"
}

is_wait_poll_shim() {
  strings -a "$1" 2>/dev/null | grep -q 'cyder-moltenvk-timeline-wait-poll'
}

is_any_shim() {
  # Skip the install-name line (otool -L line 2); only dependency lines count.
  otool -L "$1" 2>/dev/null | tail -n +3 | grep -q 'libMoltenVK.real.dylib' ||
    strings -a "$1" 2>/dev/null | grep -Eq 'cyder-mvk-(wait-poll|autorelease):|cyder-moltenvk-timeline-wait-poll'
}

undo_tree() {
  local tree="$1"
  local dir real shim
  dir="$(unix_lib "$tree")"
  real="$dir/libMoltenVK.real.dylib"
  shim="$dir/libMoltenVK.dylib"
  [[ -d "$dir" ]] || return 0
  if [[ -f "$real" ]]; then
    mv -f "$real" "$shim"
    codesign --force -s - "$shim" >/dev/null 2>&1 || true
    echo "moltenvk-wait-poll: removed engine=$tree"
  else
    echo "moltenvk-wait-poll: skipped (no .real) engine=$tree" >&2
  fi
}

build_shim_against_real() {
  local real="$1"
  local out="$2"
  local sdk
  [[ -f "$SRC" ]] || {
    echo "Missing shim source: $SRC" >&2
    return 1
  }
  mkdir -p "$(dirname "$out")"
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  arch -x86_64 clang -arch x86_64 \
    -mmacosx-version-min="$MIN_OS" \
    -isysroot "$sdk" \
    -dynamiclib \
    -o "$out" \
    "$SRC" \
    -Wl,-reexport_library,"$real" \
    -install_name '@loader_path/libMoltenVK.dylib'
  install_name_tool -change "$real" '@loader_path/libMoltenVK.real.dylib' "$out"
  codesign --force -s - "$out" >/dev/null 2>&1 || true
}

install_tree() {
  local tree="$1"
  local dir real shim bundled
  dir="$(unix_lib "$tree")"
  [[ -d "$dir" ]] || {
    echo "moltenvk-wait-poll: skipped (no unix lib) engine=$tree" >&2
    return 0
  }
  shim="$dir/libMoltenVK.dylib"
  real="$dir/libMoltenVK.real.dylib"
  [[ -f "$shim" || -f "$real" ]] || {
    echo "moltenvk-wait-poll: skipped (no MoltenVK) engine=$tree"
    return 0
  }

  if [[ ! -f "$real" ]]; then
    if is_any_shim "$shim"; then
      echo "moltenvk-wait-poll: abort (shim without .real) engine=$tree" >&2
      return 1
    fi
    cp -p "$shim" "$real"
    install_name_tool -id '@loader_path/libMoltenVK.real.dylib' "$real"
    codesign --force -s - "$real" >/dev/null 2>&1 || true
  fi

  if is_wait_poll_shim "$shim"; then
    echo "moltenvk-wait-poll: skipped engine=$tree"
    return 0
  fi

  bundled="$BUNDLED_SHIM"
  if [[ -z "$bundled" && -n "${CYDER_MVK_WAIT_POLL_BUNDLED:-}" ]]; then
    bundled="$CYDER_MVK_WAIT_POLL_BUNDLED"
  fi
  if [[ -z "$bundled" && -n "${CYDER_SCRIPTS:-}" ]]; then
    local cand="$CYDER_SCRIPTS/../tools/moltenvk-wait-poll/libMoltenVK.dylib"
    [[ -f "$cand" ]] && bundled="$cand"
  fi
  if [[ -z "$bundled" && -f "$ROOT/tools/cyder-mvk-timeline-wait-poll/libMoltenVK.dylib" ]]; then
    bundled="$ROOT/tools/cyder-mvk-timeline-wait-poll/libMoltenVK.dylib"
  fi

  mkdir -p "$STAGE"
  local local_shim="$STAGE/libMoltenVK-install.dylib"
  if [[ -n "$bundled" && -f "$bundled" ]]; then
    cp -p "$bundled" "$local_shim"
    # Ensure reexport path is loader-relative even if build used an abs path.
    if otool -L "$local_shim" | grep -q '/libMoltenVK.real.dylib'; then
      local old
      old="$(otool -L "$local_shim" | awk '/libMoltenVK\.real\.dylib/{print $1; exit}')"
      if [[ -n "$old" && "$old" != '@loader_path/libMoltenVK.real.dylib' ]]; then
        install_name_tool -change "$old" '@loader_path/libMoltenVK.real.dylib' "$local_shim"
      fi
    fi
    codesign --force -s - "$local_shim" >/dev/null 2>&1 || true
  else
    build_shim_against_real "$real" "$local_shim"
  fi

  if ! is_wait_poll_shim "$local_shim"; then
    echo "moltenvk-wait-poll: abort (built/copied shim missing marker)" >&2
    return 1
  fi

  cp -p "$local_shim" "$shim"
  chmod 755 "$shim" "$real"
  codesign --force -s - "$shim" >/dev/null 2>&1 || true
  echo "moltenvk-wait-poll: applied engine=$tree"
}

if (( UNDO )); then
  undo_tree "$ENGINE"
  exit 0
fi

install_tree "$ENGINE"
