#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-probe.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT/tests/fixtures/cyder_environment_probe_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_lifecycle.swift" "$ROOT/scripts/cyder_environment_probe.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$TEST_DIR/prefix"
