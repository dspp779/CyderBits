#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-supervisor-owner.XXXXXX)"
cleanup() {
  local status=$?
  for case_name in delayed quitting; do
    if [[ -f "$TEST_DIR/state/$case_name/entered" ]]; then
      touch "$TEST_DIR/state/$case_name/release"
      for _ in {1..100}; do
        [[ -f "$TEST_DIR/state/$case_name/result" ]] && break
        sleep 0.1
      done
    fi
  done
  if [[ -n "${CYDER_TEST_EVIDENCE:-}" && -d "$TEST_DIR/state" ]]; then
    mkdir -p "$CYDER_TEST_EVIDENCE"
    cp -R "$TEST_DIR/state" "$CYDER_TEST_EVIDENCE/"
  fi
  rm -rf "$TEST_DIR"
  exit "$status"
}
trap cleanup EXIT
cp "$ROOT/tests/fixtures/cyder_supervisor_owner_harness.swift" "$TEST_DIR/main.swift"
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_operation_gate.swift" "$ROOT/scripts/cyder_process_runner.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$TEST_DIR/state" "$ROOT/scripts"
