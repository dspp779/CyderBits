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

retired_msg='CX25 support was retired; this tree only builds CrossOver 26.'
if output_prep25="$(bash "$ROOT/scripts/prepare-build-deps.sh" --cx 25 --dry-run 2>&1)"; then
  echo "ASSERT failed: prepare-build-deps --cx 25 must fail" >&2
  exit 1
fi
assert_contains "$output_prep25" "$retired_msg" "prepare --cx 25 must print the retired message"

output_all="$(bash "$ROOT/scripts/prepare-build-deps.sh" --all --dry-run 2>&1 || true)"
if [[ "$output_all" == *"crossover-sources-25.1.1.tar.gz"* || "$output_all" == *"build/cx25"* ]]; then
  echo "ASSERT failed: prepare --all must not mention CX25" >&2
  exit 1
fi
if [[ "$output_all" != *"crossover-sources-26.3.0.tar.gz"* && "$output_all" != *"CX26 sources already present"* ]]; then
  echo "ASSERT failed: prepare --all should still prepare CX26" >&2
  exit 1
fi

echo "PASS test-prepare-build-deps"
