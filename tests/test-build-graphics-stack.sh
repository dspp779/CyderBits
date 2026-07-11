#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

output="$(bash "$ROOT/scripts/build-graphics-stack.sh" --cx 26 --dry-run 2>&1 || true)"

if [[ "$output" != *"Prepare complete"* && "$output" != *"CX26 sources already present"* ]]; then
  echo "ASSERT failed: dry-run should prepare CX sources" >&2
  exit 1
fi
assert_contains "$output" "fetchDependencies" "dry-run should fetch MoltenVK deps"
assert_contains "$output" "xcodebuild build" "dry-run should build MoltenVK via xcodebuild"
assert_contains "$output" "ARCHS=x86_64" "dry-run should target x86_64 MoltenVK"
assert_contains "$output" "install/graphics-cx26-x86_64" "dry-run should install to graphics prefix"

output_deps="$(bash "$ROOT/scripts/build-graphics-stack.sh" --cx 26 --install-deps --dry-run 2>&1 || true)"
assert_contains "$output_deps" "brew_x86 install" "install-deps should use project brew"
assert_contains "$output_deps" "cmake" "install-deps should install cmake for MoltenVK"

echo "PASS test-build-graphics-stack"
