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
echo "PASS test-cyder-launcher"
