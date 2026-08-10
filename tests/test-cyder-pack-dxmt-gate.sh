#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

graphics_pack="$(cat "$ROOT/scripts/pack-graphics-payloads.sh")"
engine_pack="$(cat "$ROOT/scripts/pack-engine-artifact.sh")"
assert_contains "$graphics_pack" 'lib/dxmt' \
  "graphics pack must require the DXMT payload"
assert_contains "$engine_pack" "pack-graphics-payloads.sh" \
  "engine pack must create graphics payloads before stripping the engine"
assert_contains "$engine_pack" "--exclude 'lib/dxmt'" \
  "engine archive must exclude DXMT"
assert_contains "$engine_pack" "--exclude 'lib/dxvk'" \
  "engine archive must exclude DXVK"
echo "PASS test-cyder-pack-dxmt-gate"
