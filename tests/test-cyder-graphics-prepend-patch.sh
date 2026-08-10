#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
patch="$ROOT/patches/cyder-compatdb-runtime.patch"

# DXVK must not get a special native-first override.
if grep -n 'dxvk.*n,b\|!strcmp( backend, "dxvk" ) ? "n,b"' "$patch"; then
  echo "FAIL: dxvk still uses n,b native-first override" >&2
  exit 1
fi
grep -q 'prepend_dll_path' "$patch"
echo "PASS test-cyder-graphics-prepend-patch"
