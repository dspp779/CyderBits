#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-migrate-graphics-prefix.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Keep the migration fixture from discovering and mutating a developer's
# real runtime graphics payload when testing the active-prefix deferral path.
export CYDER_GRAPHICS_SRC="$TMP/no-graphics"
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
assert_eq "$(cat "$PREFIX/drive_c/windows/system32/winemetal.dll")" \
  "old winemetal" \
  "migration must leave winemetal for ensure-graphics to refresh"
assert_eq "$(cat "$PREFIX/drive_c/windows/syswow64/winemetal.dll")" \
  "old winemetal" \
  "migration must leave 32-bit winemetal for ensure-graphics to refresh"

ACTIVE_PREFIX="$TMP/active-prefix"
mkdir -p \
  "$ACTIVE_PREFIX/drive_c/windows/system32" \
  "$ACTIVE_PREFIX/drive_c/windows/syswow64" \
  "$ACTIVE_PREFIX/.cyder-runtime"
printf 'old dxvk d3d11\n' >"$ACTIVE_PREFIX/drive_c/windows/system32/d3d11.dll"
printf 'old dxvk d3d11\n' >"$ACTIVE_PREFIX/drive_c/windows/syswow64/d3d11.dll"
printf 'old winemetal\n' >"$ACTIVE_PREFIX/drive_c/windows/system32/winemetal.dll"
printf 'old winemetal\n' >"$ACTIVE_PREFIX/drive_c/windows/syswow64/winemetal.dll"
: >"$ACTIVE_PREFIX/.cyder-runtime/dxvk-payload"

cyder_has_running_prefix() { return 0; }
active_output="$(
  cyder_prepare_graphics_prefix "$ENGINE/bin/wine" "$ENGINE" "$ACTIVE_PREFIX"
)"
assert_contains "$active_output" "Deferred graphics DLL migration: prefix is in use" \
  "active prefix migration must be clearly deferred"
assert_eq "$(cat "$ACTIVE_PREFIX/drive_c/windows/system32/d3d11.dll")" "old dxvk d3d11" \
  "active prefix system32 DLL must remain untouched"
assert_eq "$(cat "$ACTIVE_PREFIX/drive_c/windows/syswow64/d3d11.dll")" "old dxvk d3d11" \
  "active prefix syswow64 DLL must remain untouched"
assert test -e "$ACTIVE_PREFIX/.cyder-runtime/dxvk-payload"
assert test -e "$ACTIVE_PREFIX/drive_c/windows/system32/winemetal.dll"
assert test -e "$ACTIVE_PREFIX/drive_c/windows/syswow64/winemetal.dll"

# Missing Wine built-ins should be skipped (not abort migration).
MISSING_ENGINE="$TMP/missing-module-engine"
MISSING_PREFIX="$TMP/missing-module-prefix"
mkdir -p \
  "$MISSING_ENGINE/bin" \
  "$MISSING_ENGINE/lib/wine/x86_64-windows" \
  "$MISSING_ENGINE/lib/wine/i386-windows" \
  "$MISSING_PREFIX/drive_c/windows/system32" \
  "$MISSING_PREFIX/drive_c/windows/syswow64" \
  "$MISSING_PREFIX/.cyder-runtime"
printf 'wine-x86_64-d3d11\n' >"$MISSING_ENGINE/lib/wine/x86_64-windows/d3d11.dll"
printf 'wine-i386-d3d11\n' >"$MISSING_ENGINE/lib/wine/i386-windows/d3d11.dll"
printf 'old\n' >"$MISSING_PREFIX/drive_c/windows/system32/d3d11.dll"
: >"$MISSING_PREFIX/.cyder-runtime/dxvk-payload"
skip_out="$(
  cyder_migrate_graphics_prefix "$MISSING_ENGINE/bin/wine" "$MISSING_ENGINE" "$MISSING_PREFIX" 2>&1
)"
assert_contains "$skip_out" "Skipping missing Wine built-in graphics module" \
  "migrate must skip modules absent from the engine tree"
assert_eq "$(cat "$MISSING_PREFIX/drive_c/windows/system32/d3d11.dll")" "wine-x86_64-d3d11" \
  "present modules must still be restored when others are missing"
assert test ! -e "$MISSING_PREFIX/.cyder-runtime/dxvk-payload"

echo "PASS test-cyder-migrate-graphics-prefix"
