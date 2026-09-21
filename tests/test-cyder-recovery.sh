#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-recovery.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT/tests/fixtures/cyder_recovery_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_lifecycle.swift" "$ROOT/scripts/cyder_request_journal.swift" "$ROOT/scripts/cyder_environment_probe.swift" "$ROOT/scripts/cyder_environment_monitor.swift" "$ROOT/scripts/cyder_process_evidence.swift" "$ROOT/scripts/cyder_launch_observer.swift" "$ROOT/scripts/cyder_recovery_observer.swift" "$ROOT/scripts/cyder_independent_processes.swift" "$ROOT/scripts/cyder_recovery_records.swift" "$ROOT/scripts/cyder_window_access.swift" "$ROOT/scripts/cyder_status_item.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$TEST_DIR/state"
