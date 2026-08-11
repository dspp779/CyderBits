#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/assert.sh"

for patch in \
  "$ROOT/patches/cyder-compatdb-runtime.patch" \
  "$ROOT/patches/cyder-compatdb-runtime-oem25.patch"
do
  if grep -n 'dxvk.*n,b\|!strcmp( backend, "dxvk" ) ? "n,b"' "$patch"; then
    echo "FAIL: dxvk still uses n,b native-first override in $patch" >&2
    exit 1
  fi
  grep -q 'prepend_dll_path' "$patch"
  assert_contains "$(cat "$patch")" 'slice->size == 5 && !memcmp( slice->data, "dxvk2", 5 )' \
    "$patch must accept graphics_backend dxvk2"
  assert_contains "$(cat "$patch")" '!strcmp( backend, "dxvk2" )' \
    "$patch must treat dxvk2 like dxvk for MoltenVK"
done

echo "PASS test-cyder-graphics-prepend-patch"
