#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

script="$(cat "$ROOT/scripts/build-dxvk2.sh")"
assert_contains "$script" 'DEST_NAME="dxvk2"' \
  "DXVK 2.x must install under lib/dxvk2"
assert_contains "$script" 'lib/$DEST_NAME' \
  "install path must use DEST_NAME"
assert_not_contains "$script" 'lib/dxvk/' \
  "build-dxvk2.sh must not write the 1.x lib/dxvk tree"
assert_contains "$script" 'd3d8' \
  "DXVK 2.x payload includes d3d8"
assert_contains "$script" 'stamp-wine-builtin-pe.py' \
  "DXVK 2.x must receive the Wine builtin stamp"
assert_contains "$script" 'pin-dxvk-version.py' \
  "DXVK 2.x must pin version.h from RELEASE"
assert_contains "$script" 'std::tuple(key)' \
  "DXVK 2.x must apply the Clang 22 piecewise_construct workaround"

echo "PASS test-cyder-dxvk2"
