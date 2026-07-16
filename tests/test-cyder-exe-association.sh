#!/usr/bin/env bash
# Smoke test for cyder-exe-association Swift helper.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

SWIFT="$ROOT/scripts/cyder-exe-association.swift"
[[ -f "$SWIFT" ]] || {
  echo "SKIP: no swift helper"
  exit 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SDK="$(cd "$(xcrun --sdk macosx --show-sdk-path)" && pwd -P)"
SWIFT_RUN=(swift -sdk "$SDK" -module-cache-path "$TMP/module-cache")
output="$("${SWIFT_RUN[@]}" "$SWIFT" status local.cyder.app 2>&1 || true)"
assert_contains "$output" "com.microsoft.windows-executable" "status should list exe UTI handlers"
last="$(printf '%s\n' "$output" | tail -1)"
if [[ "$last" == "associated" ]]; then
  echo "status: associated"
elif [[ "$last" == "not_associated" ]]; then
  echo "status: not_associated"
else
  echo "unexpected status output: $output" >&2
  exit 1
fi

handlers="$("${SWIFT_RUN[@]}" "$SWIFT" handlers 2>&1)"
assert_contains "$handlers" "default_for_exe_url" "handlers should include URL-based default"

echo "PASS test-cyder-exe-association"
