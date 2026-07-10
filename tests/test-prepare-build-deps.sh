#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

output="$(bash "$ROOT/scripts/prepare-build-deps.sh" --cx 26 --dry-run 2>&1 || true)"
assert_contains "$output" "llvm-mingw-20260616-ucrt-macos-universal.tar.xz" "prepare dry-run should extract llvm-mingw"
assert_contains "$output" "crossover-sources-26.2.0.tar.gz" "prepare dry-run should extract CX26 sources"
assert_contains "$output" "build/cx26" "prepare dry-run should target build/cx26"

output_all="$(bash "$ROOT/scripts/prepare-build-deps.sh" --all --dry-run 2>&1 || true)"
assert_contains "$output_all" "crossover-sources-25.1.1.tar.gz" "prepare --all should include CX25"
assert_contains "$output_all" "crossover-sources-26.2.0.tar.gz" "prepare --all should include CX26"

echo "PASS test-prepare-build-deps"
