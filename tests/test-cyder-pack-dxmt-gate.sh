#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

pack="$(cat "$ROOT/scripts/pack-engine-artifact.sh")"
assert_contains "$pack" 'lib/dxmt/x86_64-windows/d3d11.dll' \
  "engine pack must require DXMT d3d11.dll"
assert_contains "$pack" 'lib/dxmt/x86_64-windows/dxgi.dll' \
  "engine pack must require DXMT dxgi.dll"
assert_contains "$pack" 'lib/dxmt/i386-windows/d3d11.dll' \
  "engine pack must require DXMT i386 d3d11.dll (parity with DXVK's i386 gate)"
assert_contains "$pack" 'lib/dxmt/i386-windows/dxgi.dll' \
  "engine pack must require DXMT i386 dxgi.dll (parity with DXVK's i386 gate)"
assert_contains "$pack" 'lib/dxmt/x86_64-unix/winemetal.so' \
  "engine pack must require DXMT winemetal.so"
echo "PASS test-cyder-pack-dxmt-gate"
