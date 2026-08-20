#!/usr/bin/env bash
# Download pinned Wine Mono/Gecko MSIs without starting Wine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Downloads the pinned Wine Mono and Gecko MSIs into CYDER_DOWNLOADS.
Safe to run before bootstrap while the engine tarball is extracting.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mono_sh="$SCRIPT_DIR/install-wine-mono.sh"
gecko_sh="$SCRIPT_DIR/install-wine-gecko.sh"
[[ -x "$mono_sh" || -f "$mono_sh" ]] || {
  echo "Missing Wine Mono installer: $mono_sh" >&2
  exit 1
}
[[ -x "$gecko_sh" || -f "$gecko_sh" ]] || {
  echo "Missing Wine Gecko installer: $gecko_sh" >&2
  exit 1
}

bash "$mono_sh" --download-only
bash "$gecko_sh" --download-only
