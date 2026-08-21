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
  "engine upgrade invalidates bootstrap instead of wiping"

upgrade_block="$(awk '/Upgrading shared engine/,/Installing shared engine/' <<<"$common")"
assert_contains "$upgrade_block" "cyder_invalidate_shared_bootstrap_for_engine_upgrade" \
  "version bump must invalidate bootstrap"
assert_not_contains "$upgrade_block" "cyder_reset_shared_prefix" \
  "version bump must not wipe SharedPrefix"

rebuild="$(awk '/^cyder_rebuild_shared_prefix\(\)/,/^cyder_ensure_shared_prefix\(\)/' <<<"$common")"
assert_contains "$rebuild" "cyder_remove_path" "rebuild deletes bottle before provision"
assert_contains "$rebuild" "cyder_provision_prefix_baseline" "rebuild re-provisions after wipe"

echo "PASS test-cyder-wineboot-flag"
