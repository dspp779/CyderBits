#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

output="$(bash "$ROOT/scripts/verify-bluecg.sh" --dry-run --with-gui 2>&1 || true)"

assert_contains "$output" "wine --version" "verification should include G1"
assert_contains "$output" "winecfg" "verification should include G2 when --with-gui is set"
assert_contains "$output" "run-bluecg.sh" "verification should delegate launcher startup"
assert_contains "$output" "Manual checks:" "verification should print the G3/G4 checklist"
assert_contains "$output" "AMFI" "verification should mention AMFI failure playbook"
assert_contains "$output" "workarounds" "playbook should mention optional source workarounds"

echo "PASS test-verify-bluecg"
