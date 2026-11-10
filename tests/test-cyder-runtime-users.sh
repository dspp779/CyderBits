#!/usr/bin/env bash
# Shared-runtime switches are refused while any Wine client of the engine runs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-runtime-users.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/cache"
cp "$ROOT/tests/fixtures/cyder_runtime_users_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_process_table.swift" \
  "$ROOT/scripts/cyder_runtime_users.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$TEST_DIR/state"
