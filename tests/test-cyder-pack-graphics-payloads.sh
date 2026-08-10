#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

help="$(bash "$ROOT/scripts/pack-graphics-payloads.sh" --help)"
assert_contains "$help" "dxvk" "graphics pack help must list DXVK"
assert_contains "$help" "dxmt" "graphics pack help must list DXMT"

pack="$(<"$ROOT/scripts/pack-graphics-payloads.sh")"
assert_contains "$pack" "stamp-wine-builtin-pe.py" \
  "graphics pack must stamp staged DXVK DLLs as Wine builtins"
assert_contains "$pack" 'artifact-sha256.txt' \
  "graphics pack must write artifact checksum sidecars"

echo "PASS test-cyder-pack-graphics-payloads"
