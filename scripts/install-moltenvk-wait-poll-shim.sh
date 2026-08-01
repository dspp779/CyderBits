#!/usr/bin/env bash
# Install the prebuilt Cyder MoltenVK timeline-wait poll shim into an
# extracted engine tree. This is a runtime helper: it must never compile code
# or require Xcode / Command Line Tools on an end-user machine.
# See docs/maplestory-classic-dxvk-ports-leak.md and
# cyder-wine-engine/docs/moltenvk-timeline-wait-poll-app-overlay.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLED_SHIM=""
ENGINE=""
UNDO=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --engine ENGINE_ROOT [options]

Options:
  --engine PATH         Extracted Wine engine root (…/wine-x86_64)
  --bundled-shim PATH   Required prebuilt x86_64 shim dylib
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
  grep -a -q 'cyder-moltenvk-timeline-wait-poll' "$1" 2>/dev/null
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

  bundled="$BUNDLED_SHIM"
  if [[ -z "$bundled" && -n "${CYDER_MVK_WAIT_POLL_BUNDLED:-}" ]]; then
    bundled="$CYDER_MVK_WAIT_POLL_BUNDLED"
  fi
  if [[ -z "$bundled" && -n "${CYDER_SCRIPTS:-}" ]]; then
    local cand="$CYDER_SCRIPTS/../tools/moltenvk-wait-poll/libMoltenVK.dylib"
    [[ -f "$cand" ]] && bundled="$cand"
  fi
  if [[ -z "$bundled" || ! -f "$bundled" ]]; then
    echo "moltenvk-wait-poll: skipped (prebuilt shim missing; runtime build disabled)" >&2
    return 0
  fi
  if ! is_wait_poll_shim "$bundled"; then
    echo "moltenvk-wait-poll: skipped (bundled shim marker missing): $bundled" >&2
    return 0
  fi

  if [[ ! -f "$real" ]]; then
    if is_wait_poll_shim "$shim"; then
      echo "moltenvk-wait-poll: abort (shim without .real) engine=$tree" >&2
      return 1
    fi
    cp -p "$shim" "$real"
    codesign --force -s - "$real" >/dev/null 2>&1 || true
  fi

  if is_wait_poll_shim "$shim"; then
    echo "moltenvk-wait-poll: skipped engine=$tree"
    return 0
  fi

  # The packaged shim is built with the loader-relative re-export target
  # libMoltenVK.real.dylib. Runtime only copies it; it never rewrites Mach-O
  # Mach-O load commands with a developer-only tool.
  cp -p "$bundled" "$shim"
  chmod 755 "$shim" "$real"
  codesign --force -s - "$shim" >/dev/null 2>&1 || true
  echo "moltenvk-wait-poll: applied engine=$tree"
}

if (( UNDO )); then
  undo_tree "$ENGINE"
  exit 0
fi

install_tree "$ENGINE"
