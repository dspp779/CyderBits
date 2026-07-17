#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
ui="$(cat "$ROOT/scripts/cyder_settings_ui.swift")"
library_ui="$(cat "$ROOT/scripts/cyder_game_library_ui.swift")"
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
assert_contains "$library_ui" "private final class CyderGameSettingsWindowController" "game-specific options should open in a dedicated settings window"
assert_contains "$library_ui" "private func retinaChanged()" "game settings Retina toggle should have a dedicated DPI synchronization handler"
assert_contains "$library_ui" "dpi.selectItem(at: dpiValues.firstIndex(of: retina.state == .on ? 192 : 96)" "game settings Retina toggle should suggest 192 or 96 DPI"
assert_contains "$ui" "retina.action = #selector(retinaChanged)" "global Retina control should use the synchronization handler"
assert_contains "$library_ui" "retina.action = #selector(retinaChanged)" "game settings Retina control should use the synchronization handler"
assert_contains "$library_ui" "啟動選項" "game library should expose custom options in a context menu"
assert_contains "$library_ui" "onContextMenu" "game tiles should provide a contextual menu"
assert_contains "$library_ui" "addCyderTitlebarButton" "game library should place its add button in the title bar"
assert_contains "$library_ui" "removeGameFromLibrary" "game library should expose a confirmed remove action"
assert_contains "$library_ui" "CyderFiveColumnGridLayout" "game library should use five fixed leading-aligned columns"
assert_contains "$library_ui" "styleMask: [.titled, .closable, .fullSizeContentView]" "game library window should not be resizable"
assert_contains "$library_ui" "window.collectionBehavior.insert(.fullScreenNone)" "game library should not enter full screen"
assert_contains "$library_ui" "scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 32)" "game content should begin directly below the title bar"
if [[ "$library_ui" == *'addCyderTitlebarBrand(to: window, title: "遊戲庫"'* || "$library_ui" == *'let divider = NSBox()'* ]]; then
  echo "ASSERT failed: game library should not show a title-bar brand or content divider" >&2
  exit 1
fi
assert_contains "$ui" "width: 560, height: 380" "preferences should use a compact fixed window"
assert_contains "$library_ui" "if event.clickCount >= 2" "double-click should launch before selection updates"
assert_contains "$library_ui" "collectionView.visibleItems()" "selection should update visible tiles without replacing them mid-click"
assert_contains "$library_ui" "toolbarAddButton.isHidden = isEmpty" "top add button should hide for an empty library"
if [[ "$library_ui" == *'toolbarAddButton.title = "加入遊戲"'* ]]; then
  echo "ASSERT failed: top add button should be icon-only" >&2
  exit 1
fi
assert_contains "$library_ui" "NSApp.runModal(for: settingsWindow)" "game settings should be presented as a modal popover"
assert_contains "$library_ui" "cancelButton.title = \"取消\"" "game settings should provide a cancel action"
assert_contains "$library_ui" "confirmButton.title = \"確認\"" "game settings should provide a confirm action"
context_block="$(sed -n '/private func contextMenu(for game:/,/^    @objc private func addGame()/p' "$ROOT/scripts/cyder_game_library_ui.swift")"
if [[ "$context_block" == *"開啟遊戲"* || "$context_block" == *"NSMenuItem.separator()"* ]]; then
  echo "ASSERT failed: game context menu should only contain launch options and remove" >&2
  exit 1
fi
assert_contains "$app" "shouldOpenGameLibraryOnLaunch" "app should choose the library as the main entry when games exist"
assert_contains "$app" "gameLibraryController.window?.isVisible != true" "preferences should not terminate while the library remains open"
assert_contains "$app" "openGameInDetachedCyder" "the library should delegate launches to a detached Cyder instance"
assert_contains "$app" "createsNewApplicationInstance = true" "detached launches should not reuse the library process"
assert_contains "$app" "gameLibraryController.window?.isVisible == true" "Finder opens should preserve an already visible library"
launch_region="$(sed -n '/private func launchGameFromLibrary/,/@objc private func showSettingsModal/p' "$ROOT/scripts/cyder_app_main.swift")"
if [[ "$launch_region" == *"scheduleRun()"* || "$launch_region" == *"pendingFiles"* || "$launch_region" == *"gameLibraryController.close()"* ]]; then
  echo "ASSERT failed: the library should only delegate a launch request" >&2
  exit 1
fi
if [[ "$library_ui" == *"CYDERBITS // GAME LIBRARY"* || "$library_ui" == *"NSSplitView"* || "$library_ui" == *"gameCountLabel"* || "$library_ui" == *"CyderLibrarySurfaceView"* ]]; then
  echo "ASSERT failed: game library should not retain the branded header or a persistent settings pane" >&2
  exit 1
fi
echo "PASS test-cyder-force-settings-ui"
