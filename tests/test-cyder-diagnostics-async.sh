#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-diag.XXXXXX)"
printf 'Diagnostic fixture: %s\n' "$TEST_DIR"
cp "$ROOT/tests/fixtures/cyder_diagnostics_async_harness.swift" "$TEST_DIR/main.swift"
swiftc -target arm64-apple-macosx11.0 -module-cache-path "$TEST_DIR/cache" \
  "$ROOT/scripts/cyder_diagnostics.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
mkdir "$TEST_DIR/state"
"$TEST_DIR/test" "$TEST_DIR/state"
test "$(cat "$TEST_DIR/state/complete")" = complete
if [[ -n "${CYDER_DIAGNOSTICS_ARTIFACTS:-}" ]]; then
  mkdir -p "$CYDER_DIAGNOSTICS_ARTIFACTS"
  cp -R "$TEST_DIR/state" "$CYDER_DIAGNOSTICS_ARTIFACTS/"
fi
rm -rf "$TEST_DIR"
