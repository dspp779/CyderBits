#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
ui="$(cat "$ROOT/scripts/cyder_settings_ui.swift")"
library_ui="$(cat "$ROOT/scripts/cyder_game_library_ui.swift")"
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
common="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_contains "$ui" "套用所有設定" "advanced tab should expose full apply button"
assert_contains "$ui" "applyAllSettings" "full apply button should have a dedicated action"
assert_contains "$ui" "Winetricks 元件…" "advanced tab should expose the native Winetricks component picker"
assert_contains "$ui" "cyderWinetricksComponentGroups" "Winetricks picker should use a curated component catalog"
assert_contains "$ui" "onImmediateSave" "controls should expose immediate save"
assert_contains "$ui" "guard saveControls() else" "control changes should save immediately"
assert_contains "$ui" "makeGraphicsTab()" "preferences should provide a graphics tab"
assert_contains "$ui" "圖形轉譯" "graphics tab should expose a backend selector"
assert_contains "$ui" "限制幀率" "graphics tab should expose DXVK frame-rate choices"
assert_contains "$ui" "CyderGptk.scanEvaluationVolumes()" "graphics tab should scan mounted GPTK evaluation volumes"
assert_contains "$ui" "CyderGptk.removeRuntimeInstall()" "graphics tab should remove a locally installed GPTK runtime"
assert_contains "$ui" "需要 macOS 14+" "graphics tab should explain the D3DMetal macOS requirement"
assert_contains "$ui" "canSelectD3DMetal" "D3DMetal should stay disabled without GPTK"
assert_contains "$ui" "CyderProduct.isMapleStoryOEM" "OEM prefs should omit CompatDB-follow graphics option"
assert_contains "$ui" 'return ["自動", "D3DMetal", "DXVK", "WineD3D"]' "OEM prefs should use short graphics labels"
assert_contains "$ui" 'return ["預設", "自動", "D3DMetal", "DXVK", "WineD3D"]' "official prefs should use short graphics labels"
assert_contains "$ui" "帶入預載的遊戲專屬設定" "default graphics help should avoid CompatDB jargon"
assert_contains "$ui" "顯示畫面流暢度" "prefs should expose a smoothness HUD selector"
assert_contains "$ui" "顯示 frametimes" "prefs should expose a DXVK frametimes toggle"
assert_contains "$ui" "makeDiagnosticsTab()" "preferences should provide a dedicated diagnostics tab"
assert_contains "$ui" "除錯" "diagnostics tab should be visibly labeled"
assert_contains "$ui" "Wine 診斷記錄" "diagnostics tab should expose Wine diagnostics"
assert_contains "$ui" "安靜（預設）" "Wine diagnostics should default to quiet"
assert_contains "$ui" "啟動失敗仍會由程序退出碼判斷" \
  "quiet diagnostics should explain that launch failure detection does not need Wine tracing"
assert_contains "$ui" "完整堆疊追蹤" "Wine diagnostics should expose the unwind profile"
assert_contains "$ui" "等待與凍結追蹤" "Wine diagnostics should expose the sync profile for freezes"
assert_contains "$ui" "diagnosticsWarning.isHidden = value.wineDiagnostics == .quiet" "diagnostics warning should hide in quiet mode"
assert_contains "$ui" "let syncMode = NSPopUpButton()" "global settings should use one synchronization selector"
assert_contains "$ui" 'row("同步機制", syncMode)' "global settings should label the combined synchronization selector"
assert_contains "$ui" "CyderSyncMode.allCases.map" "sync selector should expose off/MSync/ESync choices"
assert_contains "$ui" "匯出上次遊戲記錄…" "diagnostics tab should expose last-game export"
assert_contains "$ui" "清理除錯記錄…" "diagnostics tab should expose debug-log cleanup"
assert_contains "$ui" "⚠ 除錯記錄可能快速佔用大量磁碟空間" "diagnostics tab should show a high-visibility storage warning"
assert_contains "$ui" "打開遊戲庫" "general settings should expose the game library at the top"
assert_contains "$ui" "關閉所有 Wine 程序" "general settings should expose stop-all Wine"
assert_contains "$ui" "打開下載頁面" "missing GPTK install should offer Apple download page"
assert_contains "$ui" 'installGptkButton.title = "安裝 GPTK…"' "GPTK install button should use a short label"
assert_contains "$ui" "chooseGptkCandidate" "GPTK install should let the user pick among mounted volumes"
assert_contains "$ui" "CyderGptk.activeInfo()" "graphics tab should show the active GPTK source and version"
assert_contains "$ui" "CyderGptk.syncEngineLink()" "graphics tab should refresh engine GPTK symlink"
assert_contains "$(cat "$ROOT/scripts/cyder_gptk.swift")" "Cyder 已安裝" "installed GPTK should win and show version in status"
assert_contains "$ui" "let showFrameRate = backend == .dxvk" "frame-rate limiter only for manual DXVK"
assert_contains "$ui" "let showDxvkFrametimes = backend == .dxvk" "frametimes toggle should only appear for manual DXVK"
assert_contains "$ui" "let enableDxvkFrametimes = graphicsHudValue == .dxvk" "frametimes toggle should only enable for DXVK HUD"
assert_contains "$ui" "dxvkHudFrametimes.isEnabled = enableDxvkFrametimes" "frametimes toggle should disable outside DXVK HUD"
assert_contains "$ui" "let showGptkControls = backend != .dxvk && backend != .wined3d" "global GPTK controls should hide for non-GPTK backends"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'cascadePreferredBackend' "settings should resolve auto cascade before Wine"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'graphicsHud' "settings schema should persist HUD preference"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'dxvkHudFrametimes' "settings schema should persist DXVK frametimes preference"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'wineDiagnostics' "settings schema should persist Wine diagnostics"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'provisionDxvkIntoPrefix' "OEM DXVK should provision prefix DLLs"
assert_contains "$common" 'export CX_GRAPHICS_BACKEND=' "CrossOver OEM needs CX_GRAPHICS_BACKEND"
assert_contains "$common" 'cyder_oem_dxvk_dll_overrides' "shell launcher should expose OEM DXVK dll overrides helper"
assert_contains "$common" 'args=(--dll "$dll_overrides" "${args[@]}")' "shell frontend args must prepend --dll overrides"
assert_contains "$common" 'd3d11,dxgi=n,b' "OEM DXVK overrides should prefer native with builtin fallback"
assert_contains "$app" 'onStopAllWine' "settings stop-all Wine should wire to app delegate"
assert_contains "$(cat "$ROOT/scripts/cyder_gptk.swift")" 'ensureEngineAppleGptkLink' "GPTK should link into engine lib64 for cxcompatdb"
assert_contains "$common" 'unset DXVK_FRAME_RATE' "launch env should clear an unlimited DXVK frame rate"
assert_contains "$common" 'DXVK frame rate: ${DXVK_FRAME_RATE:-<unset>}' \
  "wine-launch log should record DXVK frame rate"
assert_contains "$common" 'DXVK HUD: ${DXVK_HUD:-<unset>}' \
  "wine-launch log should record DXVK HUD"
assert_contains "$common" 'DXVK_FRAME_RATE=${DXVK_FRAME_RATE:-<unset>}' \
  "effective Wine env block should include DXVK_FRAME_RATE"
assert_contains "$common" 'DXVK_HUD=${DXVK_HUD:-<unset>}' \
  "effective Wine env block should include DXVK_HUD"
assert_contains "$(cat "$ROOT/scripts/cyder_gptk.swift")" 'CYDER_ALLOW_TEST_HOOKS' "GPTK test override must require an allow flag"
assert_contains "$(cat "$ROOT/scripts/pack-engine-artifact.sh")" 'apple_gptk' "engine pack must exclude/assert no apple_gptk"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'defaultGraphicsBackend' "OEM/default graphics backend should be product-aware"
assert_contains "$ui" 'saveImmediately(registrySetting: "dpi")' "DPI changes should invoke only the DPI sed path"
assert_contains "$ui" 'saveImmediately(registrySetting: "display")' "Retina changes should invoke Retina and linked DPI paths"
assert_contains "$ui" 'saveImmediately(registrySetting: "smoothing")' "smoothing changes should invoke the smoothing sed path"
assert_contains "$ui" '細明體取代' "global UI should label MingLiU replacement"
assert_contains "$ui" '宋體取代' "global UI should label Songti replacement"
settings_swift="$(cat "$ROOT/scripts/cyder_settings.swift")"
assert_contains "$settings_swift" '蘋方' "settings should offer PingFang title"
assert_contains "$settings_swift" '"pingfang"' "settings should list pingfang id"
assert_not_contains "$settings_swift" '微軟正黑體' "settings should not offer retired JhengHei title"
assert_not_contains "$settings_swift" '"heiti"' "settings should not list retired heiti id"
assert_contains "$ui" 'cyderFontTargetTitles' "UI should use shared font target titles"
assert_contains "$library_ui" 'cyderFontTargetTitles' "game UI should use shared font target titles"
assert_contains "$ui" 'rebuildGraphicsHudMenu(selecting: value.graphicsHud)' \
  "reset-all should restore graphics HUD from defaults (off)"
assert_contains "$settings_swift" 'var retinaMode = true' "Retina default on in settings model"
assert_contains "$ui" 'saveImmediately(registrySetting: "font-mingliu")' \
  "MingLiU popup should fast-apply mingliu family"
assert_contains "$ui" 'saveImmediately(registrySetting: "font-songti")' \
  "Songti popup should fast-apply songti family"
assert_contains "$library_ui" '細明體取代' "game settings should label MingLiU replacement"
assert_contains "$library_ui" '宋體取代' "game settings should label Songti replacement"
if [[ "$ui" == *'NSButton(title: "確認"'* ]]; then
  echo "ASSERT failed: settings UI should not have a confirm button" >&2
  exit 1
fi
assert_contains "$app" "onApplyAll" "app delegate should receive full apply requests"
assert_contains "$app" "CYDER_FORCE_SETTINGS" "apply-settings launcher should receive force environment"
assert_contains "$app" "extraEnvironment: [\"CYDER_FORCE_SETTINGS\": \"1\"]" "full apply should force Wine registry writes"
assert_contains "$app" "--install-winetricks" "Winetricks installs should use the unattended launcher path"
assert_contains "$ui" "private func retinaChanged()" "Retina toggle should have a dedicated DPI synchronization handler"
assert_contains "$ui" "let targetDPI = retina.state == .on ? 192 : 96" "global Retina toggle should suggest 192 or 96 DPI"
assert_contains "$library_ui" "private final class CyderGameSettingsWindowController" "game-specific options should open in a dedicated settings window"
assert_contains "$library_ui" 'return ["跟隨全域", "自動", "D3DMetal", "DXVK", "WineD3D"]' "OEM game graphics overrides should use short labels"
assert_contains "$library_ui" 'return ["跟隨全域", "預設", "自動", "D3DMetal", "DXVK", "WineD3D"]' "official game graphics overrides should use short labels"
assert_contains "$library_ui" "private var graphicsBackendOverride: CyderGraphicsBackend?" "follow-global backend should use an optional profile override"
assert_contains "$library_ui" "private var dxvkFrameRateOverride: CyderDxvkFrameRate?" "follow-global frame rate should use an optional profile override"
assert_contains "$library_ui" "限制幀率" "game graphics overrides should expose DXVK frame-rate choices"
assert_contains "$library_ui" 'row("同步機制", syncMode)' "game settings should use one synchronization selector"
assert_contains "$library_ui" "updateSyncModeDescription" "game sync selector should update its prompt"
if [[ "$library_ui" == *"顯示 frametimes"* ]]; then
  echo "ASSERT failed: game settings should not expose a frametimes override" >&2
  exit 1
fi
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
assert_contains "$library_ui" "confirmButton.title = \"套用\"" "game settings should provide an apply action"
assert_contains "$library_ui" 'title: "\(game.displayName) 的啟動選項"' "game settings title should identify the selected game"
assert_contains "$library_ui" "使用目前選項啟動" "test action should explain that it launches with the current draft"
assert_contains "$library_ui" "last-launch.log" "test action should mention where launch logs are written"
assert_not_contains "$library_ui" "last-launch.log.gz" "uncompressed launch logs must not be labeled as gzip"
test_launch_region="$(sed -n '/@objc private func launchGame()/,/^    }/p' "$ROOT/scripts/cyder_game_library_ui.swift")"
if [[ "$test_launch_region" == *"stopModal"* ]]; then
  echo "ASSERT failed: testing a game should keep its launch-options window open" >&2
  exit 1
fi
assert_contains "$library_ui" "parseEnvironment" "environment field should tokenize KEY=value pairs"
assert_contains "$library_ui" "private final class CyderInformationButton: NSButton" "information icons should use a dedicated interactive control"
assert_contains "$library_ui" "override func mouseEntered(with event: NSEvent)" "information buttons should handle hover"
assert_contains "$library_ui" "action = #selector(buttonPressed)" "information buttons should handle clicks"
assert_contains "$library_ui" "private let arguments = CyderPlaceholderTextView()" "command line parameters should use a multiline field"
assert_contains "$library_ui" "直接接在遊戲執行指令後" "command line parameters should follow the executable command"
assert_contains "$library_ui" "private func parseArguments(_ text: String)" "command line parameters should be tokenized without a separator"
assert_contains "$library_ui" 'placeholderString = "KEY=value' "environment field should show an input placeholder"
if [[ "$ui" == *"ClearType BGR"* || "$library_ui" == *"ClearType BGR"* ]]; then
  echo "ASSERT failed: BGR font smoothing should not be exposed in settings UI" >&2
  exit 1
fi
if [[ "$library_ui" == *"多組以 ; 分隔"* || "$library_ui" == *"參數1 | 參數2"* ]]; then
  echo "ASSERT failed: game settings should not require separator characters" >&2
  exit 1
fi
context_block="$(sed -n '/private func contextMenu(for game:/,/^    @objc private func addGame()/p' "$ROOT/scripts/cyder_game_library_ui.swift")"
if [[ "$context_block" == *"開啟遊戲"* || "$context_block" == *"NSMenuItem.separator()"* ]]; then
  echo "ASSERT failed: game context menu should only contain launch options and remove" >&2
  exit 1
fi
assert_contains "$app" "shouldOpenGameLibraryOnLaunch" "app should choose the library as the main entry when games exist"
assert_contains "$app" "gameLibraryController.window?.isVisible != true" "preferences should not terminate while the library remains open"
assert_contains "$app" "launchGameFromLibrary" "the library should launch through the monitored Bash relay"
assert_contains "$app" "libraryLaunchInProgress" "the library should serialize the activation-monitoring window"
assert_not_contains "$app" "createsNewApplicationInstance = true" "library launches should retain UI error reporting"
assert_contains "$app" "gameLibraryController.window?.isVisible == true" "Finder opens should preserve an already visible library"
assert_contains "$app" "if !documentLaunchRequested {" "detached game launches should not show the parent application's active-session warning"
assert_contains "$common" 'cyder_load_game_settings' "Bash should consume the game library's one-shot launch settings"
assert_contains "$app" "開啟相關記錄" "failure dialog should use the specific related-log label"
assert_contains "$app" "exportLastGameLog" "app should handle last-game log export"
assert_contains "$app" 'Cyder-last-game.log"' "exported launch logs should use the uncompressed .log extension"
assert_contains "$app" "exportLastGameLog(to: destination)" "app should copy the selected game log directly"
assert_contains "$app" "cleanDebugLogs" "app should handle debug-log cleanup"
assert_contains "$common" "NTDLL SHA-256:" "launch diagnostics should identify the loaded NTDLL"
assert_contains "$common" "Engine version:" "launch diagnostics should identify the engine build"
assert_contains "$common" "game arguments redacted" "launch diagnostics should not persist login arguments"
assert_contains "$app" 'Public argv contract: `Cyder [game.exe] [game argument ...]`' "native launches should accept an EXE without Cyder-specific options"
assert_contains "$app" 'private func runWineThroughLauncher' "Swift document opens should relay to the Bash launcher"
assert_not_contains "$app" 'private func runDirectWine' "Swift must not retain a direct Wine launch backend"
launch_region="$(sed -n '/private func launchGameFromLibrary/,/@objc private func showSettingsModal/p' "$ROOT/scripts/cyder_app_main.swift")"
if [[ "$launch_region" == *"scheduleRun()"* || "$launch_region" == *"pendingFiles"* || "$launch_region" == *"gameLibraryController.close()"* ]]; then
  echo "ASSERT failed: the library should only delegate a launch request" >&2
  exit 1
fi
if [[ "$library_ui" == *"CYDERBITS // GAME LIBRARY"* || "$library_ui" == *"NSSplitView"* || "$library_ui" == *"gameCountLabel"* || "$library_ui" == *"CyderLibrarySurfaceView"* ]]; then
  echo "ASSERT failed: game library should not retain the branded header or a persistent settings pane" >&2
  exit 1
fi
assert_contains "$common" "EXE launches never run a Wine registry client" "active prefixes should defer launch-time registry settings"
assert_contains "$common" "Wine registry client is reserved" "Wine registry writes should be reserved for the explicit full-apply action"
assert_contains "$common" 'CYDER_SESSION_GUARD:-0' "shell game launches should not enable the optional session guard by default"
apply_prefix_region="$(sed -n '/if [[ -n "$APPLY_SETTINGS_PREFIX" ]]/,/if [[ -n "$SESSION_ACTION" ]]/p' "$ROOT/scripts/cyder_launcher.sh")"
if [[ "$apply_prefix_region" == *"cyder_profile_has_live_sessions"* || "$apply_prefix_region" == *"Cannot apply settings while this bottle is running"* ]]; then
  echo "ASSERT failed: settings-only apply must not block on another running game" >&2
  exit 1
fi
echo "PASS test-cyder-force-settings-ui"
