#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -parse-as-library -sdk "$SDK" \
  -module-cache-path "$TMP/module-cache" \
  -o "$TMP/compressed-log-harness" \
  "$ROOT/scripts/cyder_launch_support.swift" \
  "$ROOT/tests/fixtures/cyder_compressed_log_harness.swift"

"$TMP/compressed-log-harness" "$TMP/launch.log.gz"
gzip -cd "$TMP/launch.log.gz" >"$TMP/launch.log"
size="$(wc -c <"$TMP/launch.log" | tr -d ' ')"
assert_size="$((256 * 1024))"
if [[ "$size" != "$assert_size" ]]; then
  echo "ASSERT failed: decompressed log size was $size, expected $assert_size" >&2
  exit 1
fi
if [[ "$(wc -c <"$TMP/launch.log.gz" | tr -d ' ')" -ge "$size" ]]; then
  echo "ASSERT failed: gzip log should be smaller than repetitive source" >&2
  exit 1
fi

echo "PASS test-cyder-compressed-logs"
