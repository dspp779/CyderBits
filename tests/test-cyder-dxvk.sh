#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-dxvk.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ENGINE="$TMP/engine"
PREFIX="$TMP/prefix"

mkdir -p \
  "$ENGINE/lib/dxvk/x86_64-windows" \
  "$ENGINE/lib/dxvk/i386-windows" \
  "$ENGINE/lib/wine/x86_64-unix" \
  "$PREFIX/drive_c/windows/system32" \
  "$PREFIX/drive_c/windows/syswow64"
printf 'moltenvk\n' >"$ENGINE/lib/wine/x86_64-unix/libMoltenVK.dylib"
for machine in x86_64-windows i386-windows; do
  printf '%s-d3d11\n' "$machine" >"$ENGINE/lib/dxvk/$machine/d3d11.dll"
  printf '%s-dxgi\n' "$machine" >"$ENGINE/lib/dxvk/$machine/dxgi.dll"
done
ln -s "$TMP/do-not-modify" "$PREFIX/drive_c/windows/system32/d3d11.dll"
printf 'sentinel\n' >"$TMP/do-not-modify"

bash "$ROOT/scripts/install-dxvk-prefix.sh" --prefix "$PREFIX" --engine "$ENGINE"

assert_eq "$(cat "$PREFIX/drive_c/windows/system32/d3d11.dll")" \
  "x86_64-windows-d3d11" "win64 DXVK should replace the bottle entry"
assert_eq "$(cat "$TMP/do-not-modify")" "sentinel" \
  "atomic provisioning must not follow a bottle symlink"
assert_eq "$(cat "$PREFIX/drive_c/windows/syswow64/dxgi.dll")" \
  "i386-windows-dxgi" "win32 DXVK should be provisioned"
assert test -f "$PREFIX/.cyder-runtime/dxvk-payload"

patch_text="$(cat "$ROOT/patches/cyder-compatdb-runtime.patch")"
assert_contains "$patch_text" '!strcmp( backend, "dxvk" ) ? "n,b" : "b"' \
  "DXVK rules must select native DLLs while builtin stacks remain builtin"
assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" \
  'cp "$SCRIPT_DIR/install-dxvk-prefix.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the DXVK prefix provisioner"

echo "PASS test-cyder-dxvk"
