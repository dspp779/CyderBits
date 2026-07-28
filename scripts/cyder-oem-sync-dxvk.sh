#!/usr/bin/env bash
# Repair an existing OEM sidecar engine with bundled DXVK payload.
set -euo pipefail

ENGINE=""
ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2 ;;
    --archive) ARCHIVE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $(basename "$0") --engine PATH --archive PATH"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ "$ENGINE" == /* && -d "$ENGINE/bin" ]] || exit 0
[[ "$ARCHIVE" == /* && -f "$ARCHIVE" ]] || exit 0

modules=(d3d9 d3d10 d3d10_1 d3d10core d3d11 dxgi)
arches=(x86_64-windows i386-windows)
complete=1
for machine in "${arches[@]}"; do
  for module in "${modules[@]}"; do
    if [[ ! -f "$ENGINE/lib/dxvk/$machine/$module.dll" ]]; then
      complete=0
      break 2
    fi
  done
done
(( complete )) && exit 0

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-oem-dxvk.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/lib"
tar -xJf "$ARCHIVE" -C "$tmp" wine-x86_64/lib/dxvk
[[ -d "$tmp/wine-x86_64/lib/dxvk" ]] || exit 0
mkdir -p "$ENGINE/lib"
rm -rf "$ENGINE/lib/dxvk"
cp -R "$tmp/wine-x86_64/lib/dxvk" "$ENGINE/lib/dxvk"
