#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-instance.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT/tests/fixtures/cyder_instance_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_request_journal.swift" "$ROOT/scripts/cyder_request_channel.swift" "$ROOT/scripts/cyder_sentinel.swift" "$ROOT/scripts/cyder_instance.swift" "$ROOT/scripts/cyder_execution_owner.swift" "$ROOT/scripts/cyder_launch_observer.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$TEST_DIR/state"
