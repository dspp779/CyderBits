#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/cyder-migrate-graphics-prefix.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-migrate-graphics-prefix.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ENGINE="$TMP/engine"
PREFIX="$TMP/prefix"

mkdir -p \
  "$ENGINE/bin" \
  "$ENGINE/lib/wine/x86_64-windows" \
  "$ENGINE/lib/wine/i386-windows" \
  "$PREFIX/drive_c/windows/system32" \
  "$PREFIX/drive_c/windows/syswow64" \
  "$PREFIX/.cyder-runtime"

for arch in x86_64 i386; do
  for module in d3d9 d3d10 d3d10_1 d3d10core d3d11 dxgi; do
    printf 'wine-%s-%s\n' "$arch" "$module" \
      >"$ENGINE/lib/wine/$arch-windows/$module.dll"
  done
done

printf 'old dxvk d3d11\n' >"$PREFIX/drive_c/windows/system32/d3d11.dll"
printf 'old dxvk d3d11\n' >"$PREFIX/drive_c/windows/syswow64/d3d11.dll"
printf 'old winemetal\n' >"$PREFIX/drive_c/windows/system32/winemetal.dll"
printf 'old winemetal\n' >"$PREFIX/drive_c/windows/syswow64/winemetal.dll"
: >"$PREFIX/.cyder-runtime/dxvk-payload"

cyder_migrate_graphics_prefix "$ENGINE/bin/wine" "$ENGINE" "$PREFIX"

assert_eq \
  "$(shasum -a 256 "$PREFIX/drive_c/windows/system32/d3d11.dll" | awk '{print $1}')" \
  "$(shasum -a 256 "$ENGINE/lib/wine/x86_64-windows/d3d11.dll" | awk '{print $1}')" \
  "system32 d3d11 must be restored from Wine built-ins"
assert_eq \
  "$(shasum -a 256 "$PREFIX/drive_c/windows/syswow64/d3d11.dll" | awk '{print $1}')" \
  "$(shasum -a 256 "$ENGINE/lib/wine/i386-windows/d3d11.dll" | awk '{print $1}')" \
  "syswow64 d3d11 must be restored from Wine built-ins"
assert test ! -e "$PREFIX/.cyder-runtime/dxvk-payload"
assert test ! -e "$PREFIX/drive_c/windows/system32/winemetal.dll"
assert test ! -e "$PREFIX/drive_c/windows/syswow64/winemetal.dll"

echo "PASS test-cyder-migrate-graphics-prefix"
