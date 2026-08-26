#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
common="$(cat "$ROOT/scripts/cyder-common.sh")"

assert_contains "$common" 'wineboot_flag="-i"' "default create flag is -i"
assert_contains "$common" 'wineboot_flag="-u"' "existing prefix uses -u"
assert_contains "$common" 'wineboot "$wineboot_flag"' "wineboot invocation uses flag variable"
assert_contains "$common" 'wineboot_reason=' "logs must record wineboot_reason"
assert_contains "$common" 'wineboot_reason="create"' "create reason for new bottles"
assert_contains "$common" 'wineboot_reason="update"' "update reason for existing bottles"
assert_contains "$common" 'cyder_invalidate_shared_bootstrap_for_engine_upgrade' \
  "engine upgrade may still drop stale templates"
assert_contains "$common" 'cyder_write_bootstrap_marker' \
  "bootstrap marker must record engine label"
assert_contains "$common" 'Updating shared bottle for engine' \
  "engine mismatch updates shared bottle in place"

upgrade_block="$(awk '/Upgrading shared engine/,/Installing shared engine/' <<<"$common")"
assert_contains "$upgrade_block" "cyder_invalidate_shared_bootstrap_for_engine_upgrade" \
  "version bump may clean templates"
assert_not_contains "$upgrade_block" "cyder_reset_shared_prefix" \
  "version bump must not wipe SharedPrefix"
assert_not_contains "$common" 'rm -f "$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1"' \
  "engine upgrade must not delete bootstrap marker"
assert_not_contains "$common" 'rm -f "${CYDER_SHARED_PREFIX:-}/.cyder-bootstrap-v1"' \
  "invalidate must not delete bootstrap marker"

rebuild="$(awk '/^cyder_rebuild_shared_prefix\(\)/,/^cyder_ensure_shared_prefix\(\)/' <<<"$common")"
assert_contains "$rebuild" "cyder_remove_path" "rebuild deletes bottle before provision"
assert_contains "$rebuild" "cyder_provision_prefix_baseline" "rebuild re-provisions after wipe"

echo "PASS test-cyder-wineboot-flag"
