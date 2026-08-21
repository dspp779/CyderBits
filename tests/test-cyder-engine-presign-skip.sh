#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

common="$(cat "$ROOT/scripts/cyder-common.sh")"
pack="$(cat "$ROOT/scripts/pack-engine-artifact.sh")"
graphics="$(cat "$ROOT/scripts/cyder-ensure-graphics.sh")"

assert_contains "$common" "cyder_engine_signature_intact" \
  "install must detect intact packed engine signatures"
assert_contains "$common" "skipping resign" \
  "install must skip sign-wine when signatures verify"
assert_contains "$pack" ".cyder-engine-signed" \
  "pack must write .cyder-engine-signed into the staged engine tree"
assert_contains "$graphics" "cyder_graphics_link_engine_and_winemetal" \
  "graphics helper must expose link+winemetal separate from payload unpack"

# Live smoke: current shared engine should verify and take the skip path.
ENGINE="${CYDER_ENGINES:-$HOME/.cyder/runtime/Engines}/wine-x86_64"
if [[ -x "$ENGINE/bin/wine" ]] || [[ -x "$ENGINE/bin/wineloader" ]]; then
  # shellcheck source=../scripts/cyder-common.sh
  source "$ROOT/scripts/cyder-common.sh"
  cyder_init_paths "$ROOT/scripts"
  out="$(cyder_sign_installed_engine "$ENGINE" 2>&1)"
  assert_contains "$out" "skipping resign" \
    "installed engine with valid signatures must skip resign"
fi

echo "PASS test-cyder-engine-presign-skip"
