#!/usr/bin/env bash
# While a launch is starting, look for its first window every 0.5 s.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT/tests/fixtures/cyder_window_starting_scan_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_lifecycle.swift" "$ROOT/scripts/cyder_process_evidence.swift" \
  "$ROOT/scripts/cyder_window_access.swift" "$ROOT/scripts/cyder_diagnostics.swift" "$ROOT/scripts/cyder_independent_processes.swift" "$ROOT/scripts/cyder_process_table.swift" "$ROOT/scripts/cyder_environment_probe.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
