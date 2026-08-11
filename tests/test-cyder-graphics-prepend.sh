#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/assert.sh"

common="$(cat "$ROOT/scripts/cyder-common.sh")"
build_wine="$(cat "$ROOT/scripts/build-wine.sh")"

assert_contains "$common" 'CYDER_GRAPHICS_BACKEND_PATH=${CYDER_GRAPHICS_BACKEND_PATH:-<derived from engine>}' \
  "launch logs should record a direct graphics backend path override"
assert_contains "$common" 'CYDER_GRAPHICS_BACKENDS_ROOT=' \
  "launches should still provide the engine root for derived backend paths"
assert_not_contains "$build_wine" 'cyder-compatdb-runtime.patch' \
  "graphics prepend should leave the original CrossOver ntdll unchanged"

echo "PASS test-cyder-graphics-prepend"
