#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-dxmt-prefix.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ENGINE="$TMP/engine"
PREFIX="$TMP/prefix"

mkdir -p \
  "$ENGINE/lib/dxmt/x86_64-windows" \
  "$ENGINE/lib/dxmt/i386-windows" \
  "$ENGINE/lib/dxmt/x86_64-unix" \
  "$PREFIX/drive_c/windows/system32" \
  "$PREFIX/drive_c/windows/syswow64"
printf 'winemetal-so\n' >"$ENGINE/lib/dxmt/x86_64-unix/winemetal.so"
for machine in x86_64-windows i386-windows; do
  for module in d3d10core d3d11 dxgi winemetal; do
    printf '%s-%s\n' "$machine" "$module" >"$ENGINE/lib/dxmt/$machine/$module.dll"
  done
done
ln -s "$TMP/do-not-modify" "$PREFIX/drive_c/windows/system32/d3d11.dll"
printf 'sentinel\n' >"$TMP/do-not-modify"

bash "$ROOT/scripts/install-dxmt-prefix.sh" --prefix "$PREFIX" --engine "$ENGINE"

assert_eq "$(cat "$PREFIX/drive_c/windows/system32/d3d11.dll")" \
  "x86_64-windows-d3d11" "win64 DXMT should replace the bottle entry"
assert_eq "$(cat "$TMP/do-not-modify")" "sentinel" \
  "atomic provisioning must not follow a bottle symlink"
assert_eq "$(cat "$PREFIX/drive_c/windows/system32/winemetal.dll")" \
  "x86_64-windows-winemetal" "win64 winemetal must be provisioned"
assert_eq "$(cat "$PREFIX/drive_c/windows/syswow64/winemetal.dll")" \
  "i386-windows-winemetal" "win32 winemetal must be provisioned"
assert test -f "$PREFIX/.cyder-runtime/dxmt-payload"

assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" \
  'cp "$SCRIPT_DIR/install-dxmt-prefix.sh" "$RES/ogom-scripts/"' \
  "Cyder.app must bundle the DXMT prefix provisioner"
assert_contains "$(cat "$ROOT/scripts/cyder-common.sh")" \
  'install-dxmt-prefix.sh' \
  "Launch path must provision DXMT into the prefix"

echo "PASS test-cyder-dxmt-prefix"
