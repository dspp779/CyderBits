#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

script="$(<"$ROOT/scripts/bundle-wine-dylibs.sh")"

assert_contains "$script" 'VULKAN_SOURCE="${VULKAN_SOURCE:-existing}"' \
  "repacking should preserve an engine's existing MoltenVK by default"
assert_contains "$script" '"crossover": (' \
  "bundler should have an explicit CrossOver MoltenVK selection path"
assert_contains "$script" '"homebrew": (' \
  "bundler should keep Homebrew as an explicit alternative"

crossover_block="$(sed -n '/"crossover": (/,/),/p' "$ROOT/scripts/bundle-wine-dylibs.sh")"
first_candidate="$(printf '%s\n' "$crossover_block" | rg 'libMoltenVK\.dylib' | head -1)"
assert_contains "$first_candidate" 'graphics_lib' \
  "CrossOver mode must prefer the CrossOver graphics artifact over Homebrew"

existing_block="$(sed -n '/"existing": (/,/),/p' "$ROOT/scripts/bundle-wine-dylibs.sh")"
first_existing="$(printf '%s\n' "$existing_block" | rg 'libMoltenVK\.dylib' | head -1)"
assert_contains "$first_existing" 'unix_lib' \
  "artifact repacking must preserve the already-tested engine renderer"

echo "PASS test-bundle-wine-dylibs-source"
