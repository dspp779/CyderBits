#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK="$(cd "$SDK" && pwd -P)"
MODULE_CACHE="${CYDER_TEST_SWIFT_MODULE_CACHE:-$TMP/module-cache}"
swiftc -Onone \
  -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -o "$TMP/diagnostics-harness" \
  "$ROOT/scripts/cyder_diagnostics.swift" \
  "$ROOT/tests/fixtures/cyder_diagnostics_harness.swift"

CYDER_SUPPORT="$TMP/timing-support" "$TMP/diagnostics-harness" timing
timing_log="$(ls "$TMP/timing-support/Logs/sessions/"*.log | head -n 1)"
assert_contains "$(cat "$timing_log")" "previous_ms=" "stage transitions should record previous_ms"
assert_contains "$(cat "$timing_log")" "elapsed_ms=12" "operation timing should record elapsed_ms"
assert_contains "$(cat "$timing_log")" "session_ms=" "session finish should record session_ms"

CYDER_SUPPORT="$TMP/support" "$TMP/diagnostics-harness" leave-running
state="$(cat "$TMP/support/Logs/session-state.json")"
assert_contains "$state" '"state" : "running"' "unfinished session should remain marked running"
assert_contains "$state" '"stage" : "wine-spawn"' "session marker should retain the last stage"

CYDER_SUPPORT="$TMP/support" "$TMP/diagnostics-harness" recover
recovered="$(cat "$TMP/support/Logs/session-state.json")"
assert_contains "$recovered" '"state" : "completed"' "recovered session should finish normally"
assert_contains "$recovered" '"outcome" : "recovered"' "completion outcome should be recorded"

CYDER_SUPPORT="$TMP/support" "$TMP/diagnostics-harness" record-failure
failure="$(cat "$TMP/support/Logs/last-error.json")"
assert_contains "$failure" '"code" : "CYD-TEST-001"' "structured error code should be persisted"
if [[ "$failure" == *"$HOME/secret"* ]]; then
  echo "ASSERT failed: diagnostic JSON should redact the home directory" >&2
  exit 1
fi

CYDER_SUPPORT="$TMP/export-support" "$TMP/diagnostics-harness" export
assert_contains "$(cat "$TMP/export-support/exported-game.log")" "Wine diagnostics: errors" \
  "export should copy only the most recent game launch log"
assert test ! -e "$TMP/export-support/export.zip"

CYDER_SUPPORT="$TMP/cleanup-support" "$TMP/diagnostics-harness" cleanup
assert test ! -e "$TMP/cleanup-support/Logs/sessions/22222222-2222-2222-2222-222222222222-001-wine-launch.log"
assert test ! -e "$TMP/cleanup-support/Logs/last-launch.log"
assert test ! -e "$TMP/cleanup-support/Logs/sessions/old-session.log"
assert test ! -e "$TMP/cleanup-support/Logs/operations/old-operation.log"

CYDER_SUPPORT="$TMP/rolling-support" "$TMP/diagnostics-harness" rolling
assert test -f "$TMP/rolling-support/Logs/operations/settings-apply.log"
assert_contains "$(cat "$TMP/rolling-support/Logs/operations/settings-apply.log")" "new settings output" \
  "settings apply should reuse one rolling log"

echo "PASS test-cyder-diagnostics"
