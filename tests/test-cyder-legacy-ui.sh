#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-legacy-ui.sh
source "$ROOT/scripts/cyder-legacy-ui.sh"

assert_contains "$(cat "$ROOT/scripts/cyder-macos-wrapper.sh")" 'cyder_macos_at_least 12 0' \
  "wrapper must route macOS 12+ to CyderSwift"
assert_contains "$(cat "$ROOT/scripts/cyder-macos-wrapper.sh")" 'CYDER_RETINA_MODE=0' \
  "legacy path must force Retina off"
assert_contains "$(cat "$ROOT/scripts/cyder-legacy-ui.applescript")" 'set progress description to "Cyder"' \
  "legacy UI must drive AppleScript progress"
assert_contains "$(cat "$ROOT/scripts/cyder-legacy-ui.applescript")" 'CYDER_PROGRESS_FILE=' \
  "legacy UI must poll bootstrap progress file"

# Version compare unit checks (host is always >= these on modern CI).
assert cyder_macos_at_least 10 15
assert cyder_macos_at_least 10 0
if cyder_macos_at_least 99 0; then
  echo "ASSERT failed: host should not claim macOS 99+" >&2
  exit 1
fi

# MoltenVK floor: on current hosts (>=10.15) the gate is a no-op.
unset CYDER_DISABLE_MOLTENVK WINEDLLOVERRIDES || true
cyder_apply_moltenvk_os_floor
if [[ -n "${CYDER_DISABLE_MOLTENVK:-}" ]]; then
  echo "ASSERT failed: MoltenVK should stay enabled on macOS $(cyder_macos_product_version)" >&2
  exit 1
fi

# Simulate a pre-10.15 host by stubbing the version helper.
cyder_macos_product_version() { echo "10.14.6"; }
unset CYDER_DISABLE_MOLTENVK WINEDLLOVERRIDES || true
cyder_apply_moltenvk_os_floor
assert_eq "${CYDER_DISABLE_MOLTENVK:-}" "1" "pre-10.15 must set CYDER_DISABLE_MOLTENVK"
assert_contains "${WINEDLLOVERRIDES:-}" "winevulkan=d" "pre-10.15 must disable winevulkan"

echo "PASS test-cyder-legacy-ui"
