#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-macos-compat.sh
source "$ROOT/scripts/cyder-macos-compat.sh"

wrapper="$(cat "$ROOT/scripts/cyder-macos-wrapper.sh")"
catalina_bootstrap="$(cat "$ROOT/scripts/cyder-catalina-bootstrap.command")"
assert test -x "$ROOT/scripts/cyder-catalina-bootstrap.command"
assert_contains "$wrapper" 'cyder_macos_at_least 11 0' \
  "wrapper must route no-argument macOS 11+ launches to CyderSwift"
swift_gate_line="$(printf '%s\n' "$wrapper" | grep -n 'cyder_macos_at_least 11 0' | head -n 1 | cut -d: -f1)"
bash_launch_line="$(printf '%s\n' "$wrapper" | grep -n 'An explicit EXE is a launch request' | head -n 1 | cut -d: -f1)"
[[ "$bash_launch_line" =~ ^[0-9]+$ && "$swift_gate_line" =~ ^[0-9]+$ && "$bash_launch_line" -lt "$swift_gate_line" ]] || {
  echo "ASSERT failed: explicit EXE routing must occur before the Swift UI gate" >&2
  exit 1
}
assert_contains "$wrapper" 'exec "$SCRIPTS/cyder_launcher.sh" --engine-src "$ENGINE_SRC" --launch-exe "$exe"' \
  "explicit EXE arguments must go directly to the Bash launcher"
assert_not_contains "$wrapper" 'CyderLegacyUI.app' \
  "wrapper must not retain the removed Catalina applet"
assert_contains "$wrapper" 'cyder_catalina_environment_ready' \
  "Catalina must check readiness before selecting or launching an EXE"
assert_contains "$wrapper" '/usr/bin/open -a Terminal "$bootstrap"' \
  "Catalina first run must open the visible Terminal bootstrap"
assert_contains "$catalina_bootstrap" '--bootstrap-only' \
  "Catalina Terminal bootstrap must use the supported launcher action"
assert_contains "$catalina_bootstrap" 'CYDER_PROGRESS_FILE' \
  "Catalina Terminal bootstrap must display staged setup messages"
assert_contains "$catalina_bootstrap" 'catalina-bootstrap.lock' \
  "Catalina Terminal bootstrap must reject concurrent initialization"
assert_contains "$catalina_bootstrap" '/usr/bin/open "$APP"' \
  "successful Catalina bootstrap must reopen Cyder"

assert cyder_macos_at_least 10 15
assert cyder_macos_at_least 10 0
if cyder_macos_at_least 99 0; then
  echo "ASSERT failed: host should not claim macOS 99+" >&2
  exit 1
fi

unset CYDER_DISABLE_MOLTENVK WINEDLLOVERRIDES || true
cyder_apply_moltenvk_os_floor
if [[ -n "${CYDER_DISABLE_MOLTENVK:-}" ]]; then
  echo "ASSERT failed: MoltenVK should stay enabled on macOS $(cyder_macos_product_version)" >&2
  exit 1
fi

cyder_macos_product_version() { echo "10.14.6"; }
unset CYDER_DISABLE_MOLTENVK WINEDLLOVERRIDES || true
cyder_apply_moltenvk_os_floor
assert_eq "${CYDER_DISABLE_MOLTENVK:-}" "1" "pre-10.15 must set CYDER_DISABLE_MOLTENVK"
assert_contains "${WINEDLLOVERRIDES:-}" "winevulkan=d" "pre-10.15 must disable winevulkan"

echo "PASS test-cyder-macos-compat"
