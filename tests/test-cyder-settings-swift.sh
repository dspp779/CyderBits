#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/module-cache"
BIN="$TMP/cyder-settings-harness"
export CYDER_SUPPORT="$TMP/support"
mkdir -p "$CYDER_SUPPORT"

swiftc -O -module-cache-path "$CACHE" \
  "$ROOT/scripts/cyder_paths.swift" \
  "$ROOT/scripts/cyder_settings.swift" \
  "$ROOT/tests/fixtures/cyder_settings_diagnostics_stub.swift" \
  "$ROOT/tests/fixtures/cyder_settings_harness.swift" \
  -o "$BIN"

cat >"$TMP/settings.json" <<'JSON'
{
  "schemaVersion": 3,
  "dpi": 999,
  "perExecutable": {
    "game.exe": {
      "arguments": ["--legacy"],
      "environment": {"LEGACY_VALUE": "yes", "BAD-KEY": "ignored"}
    }
  },
  "perProfile": {
    "profile-0123456789abcdef01234567": {
      "arguments": ["--profile"],
      "environment": {"PROFILE_VALUE": "yes", "UNICODE_QUOTE": "中文 \"測試\"", "CONTROL": "bad\u0001value", "BAD-KEY": "ignored"},
      "powerMode": "turbo"
    },
    "not-a-profile": {"arguments": ["--must-ignore"]}
  }
}
JSON

"$BIN" "$TMP/settings.json"
echo "PASS test-cyder-settings-swift"
