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
assert_contains "$wrapper" 'cyder_exec_cyder_swift "$SELF/CyderSwift" "$exe" "${game_args[@]}"' \
  "explicit EXE arguments on macOS 11+ must enter the native lifecycle agent"
assert_contains "$wrapper" 'cyder_exec_cyder_swift "$SELF/CyderSwift" "$@"' \
  "no-argument macOS 11+ launches must exec native CyderSwift"
assert_contains "$wrapper" 'exec "$SCRIPTS/cyder_launcher.sh" --engine-src "$ENGINE_SRC" --launch-exe "$exe"' \
  "Catalina explicit EXE arguments must retain the Bash fallback"
assert_contains "$wrapper" 'exec "$SCRIPTS/cyder_launcher.sh" --engine-src "$ENGINE_SRC" --launch-msi "$exe"' \
  "explicit MSI arguments must route through the Bash MSI launcher"
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
assert_contains "$wrapper" 'catalina-pending-launch' \
  "Catalina must preserve the original first-run EXE request"
assert_contains "$catalina_bootstrap" 'pending_args' \
  "Catalina bootstrap must resume the pending EXE after setup"
assert_contains "$catalina_bootstrap" '/usr/bin/open "$APP" --args' \
  "Catalina bootstrap must pass the pending EXE back to the Bash wrapper"

compat="$(cat "$ROOT/scripts/cyder-macos-compat.sh")"
assert_contains "$compat" 'cyder_host_is_apple_silicon' \
  "Apple Silicon detection must not trust uname -m under Rosetta"
assert_contains "$compat" 'hw.optional.arm64' \
  "Apple Silicon detection must use hw.optional.arm64 so it works inside Rosetta"
assert_contains "$compat" 'cyder_exec_cyder_swift' \
  "the wrapper must exec CyderSwift through an architecture-forcing helper"
assert_contains "$compat" 'cyder_spawn_cyder_swift' \
  "sentinel helpers must spawn CyderSwift through the same architecture helper"
assert_contains "$compat" '/usr/bin/arch -arm64' \
  "Apple Silicon must force the arm64 CyderSwift slice"
if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
  assert cyder_host_is_apple_silicon
fi

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
