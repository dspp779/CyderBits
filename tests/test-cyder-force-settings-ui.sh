#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
ui="$(cat "$ROOT/scripts/cyder_settings_ui.swift")"
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$ui" "重新套用所有設定（疑難排解）" "advanced tab should expose force reapply checkbox"
assert_contains "$ui" "forceReapplyChanged" "force checkbox should mark settings dirty"
assert_contains "$ui" "let force = forceReapply.state == .on" "confirm should capture force checkbox"
assert_contains "$ui" "onCommit?(shouldStopAll, requiresPrefixApply, force)" "commit should propagate force state"
assert_contains "$app" "forceReapply: Bool" "app delegate should receive force state"
assert_contains "$app" "CYDER_FORCE_SETTINGS" "apply-settings launcher should receive force environment"
assert_contains "$app" "forceReapply ? [\"CYDER_FORCE_SETTINGS\": \"1\"]" "force state should set environment only when checked"
echo "PASS test-cyder-force-settings-ui"
