#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT/tests/fixtures/cyder_lifecycle_isolation_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_lifecycle.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
