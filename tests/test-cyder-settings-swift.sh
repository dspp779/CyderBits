#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! swiftc -O \
  -module-cache-path "$TMP/module-cache" \
  "$ROOT/scripts/cyder_diagnostics.swift" \
  "$ROOT/scripts/cyder_paths.swift" \
  "$ROOT/scripts/cyder_settings.swift" \
  "$ROOT/tests/cyder-settings-harness.swift" \
  -o "$TMP/cyder-settings-harness" 2>"$TMP/swiftc.err"; then
  if grep -q "SDK is not supported by the compiler" "$TMP/swiftc.err"; then
    echo "SKIP cyder-settings-harness (Swift compiler and SDK versions differ)"
    exit 0
  fi
  cat "$TMP/swiftc.err" >&2
  exit 1
fi
CYDER_SUPPORT="$TMP/support" "$TMP/cyder-settings-harness"
echo "PASS test-cyder-settings-swift"
