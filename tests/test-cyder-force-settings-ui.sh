#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
ui="$(cat "$ROOT/scripts/cyder_settings_ui.swift")"
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$ui" "套用所有設定" "advanced tab should expose full apply button"
assert_contains "$ui" "applyAllSettings" "full apply button should have a dedicated action"
assert_contains "$ui" "onImmediateSave" "controls should expose immediate save"
assert_contains "$ui" "guard saveControls() else" "control changes should save immediately"
assert_contains "$ui" 'saveImmediately(registrySetting: "dpi")' "DPI changes should invoke only the DPI sed path"
assert_contains "$ui" 'saveImmediately(registrySetting: "display")' "Retina changes should invoke Retina and linked DPI paths"
assert_contains "$ui" 'saveImmediately(registrySetting: "smoothing")' "smoothing changes should invoke the smoothing sed path"
assert_contains "$ui" 'saveImmediately(registrySetting: "font")' "font changes should invoke the section rename sed path"
if [[ "$ui" == *'NSButton(title: "確認"'* ]]; then
  echo "ASSERT failed: settings UI should not have a confirm button" >&2
  exit 1
fi
assert_contains "$app" "onApplyAll" "app delegate should receive full apply requests"
assert_contains "$app" "CYDER_FORCE_SETTINGS" "apply-settings launcher should receive force environment"
assert_contains "$app" "extraEnvironment: [\"CYDER_FORCE_SETTINGS\": \"1\"]" "full apply should force Wine registry writes"
assert_contains "$ui" "private func retinaChanged()" "Retina toggle should have a dedicated DPI synchronization handler"
assert_contains "$ui" "let targetDPI = retina.state == .on ? 192 : 96" "global Retina toggle should suggest 192 or 96 DPI"
assert_contains "$ui" "private func executableRetinaChanged()" "per-game Retina toggle should have a dedicated DPI synchronization handler"
assert_contains "$ui" "let targetDPI = executableRetina.state == .on ? 192 : 96" "per-game Retina toggle should suggest 192 or 96 DPI"
assert_contains "$ui" "retina.action = #selector(retinaChanged)" "global Retina control should use the synchronization handler"
assert_contains "$ui" "executableRetina.action = #selector(executableRetinaChanged)" "per-game Retina control should use the synchronization handler"
echo "PASS test-cyder-force-settings-ui"
