#!/usr/bin/env bash
# Schema 4 coverage (see cyder_settings_harness.swift):
# - decode schema 3 without graphics fields → defaults default/60
# - resolve: global dxvk + profile nil → dxvk/60
# - resolve: global dxvk + profile unlimited → dxvk/unlimited
# - resolve: global wined3d + profile default → default (explicit profile default wins)
# - environment(): dxvk+60 sets CYDER_GRAPHICS_BACKEND=dxvk and DXVK_FRAME_RATE=60
# - environment(): default sets neither CYDER_GRAPHICS_BACKEND nor DXVK_FRAME_RATE
# - MapleStory default policy: DXMT on macOS 15+, DXVK below macOS 15
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/module-cache"
BIN="$TMP/cyder-settings-harness"
export CYDER_SUPPORT="$TMP/support"
mkdir -p "$CYDER_SUPPORT"
unset CYDER_ENGINE_NAME CYDER_BOTTLE_NAME

swiftc -O -module-cache-path "$CACHE" \
  "$ROOT/scripts/cyder_paths.swift" \
  "$ROOT/scripts/cyder_gptk.swift" \
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
