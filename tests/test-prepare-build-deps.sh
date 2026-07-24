#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

output="$(bash "$ROOT/scripts/prepare-build-deps.sh" --cx 26 --dry-run 2>&1 || true)"
if [[ "$output" != *"llvm-mingw-20260616-ucrt-macos-universal.tar.xz"* && "$output" != *"llvm-mingw already present"* ]]; then
  echo "ASSERT failed: prepare dry-run should extract or detect llvm-mingw" >&2
  exit 1
fi
if [[ "$output" != *"crossover-sources-26.3.0.tar.gz"* && "$output" != *"CX26 sources already present"* ]]; then
  echo "ASSERT failed: prepare dry-run should extract or detect CX26 sources" >&2
  exit 1
fi
assert_contains "$output" "build/cx26" "prepare dry-run should target build/cx26"

output_all="$(bash "$ROOT/scripts/prepare-build-deps.sh" --all --dry-run 2>&1 || true)"
if [[ "$output_all" != *"crossover-sources-25.1.1.tar.gz"* && "$output_all" != *"CX25 sources already present"* ]]; then
  echo "ASSERT failed: prepare --all should include or detect CX25" >&2
  exit 1
fi
if [[ "$output_all" != *"crossover-sources-26.3.0.tar.gz"* && "$output_all" != *"CX26 sources already present"* ]]; then
  echo "ASSERT failed: prepare --all should include or detect CX26" >&2
  exit 1
fi

echo "PASS test-prepare-build-deps"
