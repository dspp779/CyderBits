#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/cyder-ensure-rosetta.sh"

if cyder_is_apple_silicon; then
  if ! cyder_rosetta_is_installed; then
    echo "SKIP: Rosetta 2 not installed (cannot test install prompt non-interactively)"
    exit 0
  fi
  cyder_ensure_rosetta
  echo "Rosetta check OK on Apple Silicon"
else
  cyder_ensure_rosetta
  echo "Rosetta check skipped on $(uname -m)"
fi

set +e
status="$(
  CYDER_GUI=1 bash "$ROOT/scripts/cyder_launcher.sh" --ensure-rosetta-only >/dev/null 2>&1
  echo $?
)"
set -e
assert_eq "$status" "0" "--ensure-rosetta-only should succeed when Rosetta is available"

echo "PASS test-cyder-rosetta"
