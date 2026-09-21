#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-icons.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 "$ROOT/tests/fixtures/cyder_pe_icon_fixtures.py" "$TEST_DIR/fixtures"
cp "$ROOT/tests/fixtures/cyder_game_icon_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_paths.swift" "$ROOT/scripts/cyder_profiles.swift" "$ROOT/scripts/cyder_bottle_shortcuts.swift" "$ROOT/scripts/cyder_game_library.swift" "$ROOT/scripts/cyder_launch_preparation.swift" "$ROOT/scripts/cyder_pe_icon.swift" "$ROOT/scripts/cyder_game_icon.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
CYDER_SUPPORT="$TEST_DIR/support" CYDER_RUNTIME_ROOT="$TEST_DIR/runtime" "$TEST_DIR/test" "$TEST_DIR/fixtures" "$@"
test -f "$TEST_DIR/fixtures/completed"
