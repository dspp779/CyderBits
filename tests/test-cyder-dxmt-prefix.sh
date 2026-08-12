#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

# Prepend model: DXMT is shipped as a runtime graphics payload and loaded via
# CompatDB builtin prepend. Only the required winemetal PE gate is maintained
# in each prefix; the launch path does not copy the DXMT stack.
common_script="$(cat "$ROOT/scripts/cyder-common.sh")"
build_script="$(cat "$ROOT/scripts/create-cyder-app.sh")"

assert_contains "$build_script" 'cyder-ensure-graphics.sh' \
  "Cyder.app must bundle the graphics payload ensurer"
assert_contains "$build_script" 'cyder-migrate-graphics-prefix.sh' \
  "Cyder.app must bundle the legacy prefix migration helper"
assert_not_contains "$common_script" 'install-dxmt-prefix.sh' \
  "Launch path must not copy DXMT PE into prefixes"
assert_not_contains "$(cat "$ROOT/scripts/build-wine.sh")" 'cyder-compatdb-runtime.patch' \
  "DXMT prepend must not require an ntdll patch"
assert_contains "$common_script" 'cyder_engine_has_dxmt_payload' \
  "Launch path must probe DXMT payload availability instead of provisioning PE"
assert_contains "$common_script" 'cyder_ensure_graphics "$bottle"' \
  "Profile creation must install DXMT winemetal into the new prefix"
assert_contains "$(cat "$ROOT/scripts/cyder_launcher.sh")" 'cyder_prepare_graphics_prefix "$wine" "$engine" "$prefix"' \
  "Profile launch must refresh DXMT winemetal before Wine starts"

# Keep the provisioner script available for offline/migration tooling, but do
# not require it in the app bundle for the prepend production path.
assert test -f "$ROOT/scripts/install-dxmt-prefix.sh"

echo "PASS test-cyder-dxmt-prefix"
