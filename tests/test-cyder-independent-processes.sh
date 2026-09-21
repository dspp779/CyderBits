#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-independent.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/engine/lib/wine/x86_64-unix" "$TEST_DIR/engine/bin" "$TEST_DIR/prefix" "$TEST_DIR/other-prefix"
clang "$ROOT/tests/fixtures/cyder_independent_helper.c" -o "$TEST_DIR/engine/lib/wine/x86_64-unix/wine"
cp "$TEST_DIR/engine/lib/wine/x86_64-unix/wine" "$TEST_DIR/engine/bin/wineserver"
cp "$ROOT/tests/fixtures/cyder_independent_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_lifecycle.swift" "$ROOT/scripts/cyder_process_evidence.swift" "$ROOT/scripts/cyder_environment_probe.swift" "$ROOT/scripts/cyder_launch_observer.swift" "$ROOT/scripts/cyder_recovery_observer.swift" "$ROOT/scripts/cyder_independent_processes.swift" "$ROOT/scripts/cyder_window_access.swift" "$ROOT/scripts/cyder_status_item.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$TEST_DIR"
test "$(cat "$TEST_DIR/passed")" = passed
