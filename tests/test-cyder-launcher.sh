#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/game.exe"
touch "$FAKE"
output="$(bash "$ROOT/scripts/cyder_launcher.sh" "$FAKE" --dry-run 2>&1)"
assert_contains "$output" "SharedPrefix" "dry-run should use SharedPrefix"
assert_contains "$output" "game.exe" "dry-run should show exe path"
set +e
launch_out="$(bash "$ROOT/scripts/cyder_launcher.sh" --launch-exe /nonexistent/missing.exe 2>&1)"
launch_status=$?
set -e
assert_eq "$launch_status" 1 "launch-exe with missing file should fail"
assert_contains "$launch_out" "Missing or invalid .exe" "launch-exe should reach launch handler"
echo "PASS test-cyder-launcher"
