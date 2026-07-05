#!/usr/bin/env bash
# Smoke test for cyder-exe-association Swift helper.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

SWIFT="$ROOT/scripts/cyder-exe-association.swift"
[[ -f "$SWIFT" ]] || {
  echo "SKIP: no swift helper"
  exit 0
}

output="$(swift "$SWIFT" status local.cyder.app 2>&1 || true)"
last="$(printf '%s\n' "$output" | tail -1)"
if [[ "$last" == "associated" ]]; then
  echo "status: associated"
elif [[ "$last" == "not_associated" ]]; then
  echo "status: not_associated"
else
  echo "unexpected status output: $output" >&2
  exit 1
fi

echo "PASS test-cyder-exe-association"
