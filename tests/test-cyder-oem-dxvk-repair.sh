#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-oem-dxvk-repair.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ENGINE_STAGE="$TMP/archive-root/wine-x86_64"
SIDECAR="$TMP/runtime/Engines/maplestory-oem25"
APP="$TMP/Cyder-maplestory-oem25.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

mkdir -p \
  "$ENGINE_STAGE/lib/dxvk/x86_64-windows" \
  "$ENGINE_STAGE/lib/dxvk/i386-windows" \
  "$SIDECAR/bin" \
  "$MACOS" \
  "$RES"

for machine in x86_64-windows i386-windows; do
  for module in d3d9 d3d10 d3d10_1 d3d10core d3d11 dxgi; do
    printf 'bundled-%s-%s\n' "$machine" "$module" \
      >"$ENGINE_STAGE/lib/dxvk/$machine/$module.dll"
  done
done

ARCHIVE="$RES/engine-maplestory-oem25-test.tar.xz"
(
  cd "$TMP/archive-root"
  tar -cJf "$ARCHIVE" wine-x86_64
)
printf '%s\n' "$(basename "$ARCHIVE")" >"$RES/engine-archive.txt"

bash "$ROOT/scripts/cyder-oem-sync-dxvk.sh" \
  --engine "$SIDECAR" \
  --archive "$ARCHIVE"

for machine in x86_64-windows i386-windows; do
  for module in d3d9 d3d10 d3d10_1 d3d10core d3d11 dxgi; do
    assert test -f "$SIDECAR/lib/dxvk/$machine/$module.dll"
    assert_eq \
      "$(cat "$SIDECAR/lib/dxvk/$machine/$module.dll")" \
      "bundled-$machine-$module" \
      "OEM DXVK repair should restore $machine/$module.dll from bundled archive"
  done
done

echo "PASS test-cyder-oem-dxvk-repair"
