#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
ui="$(cat "$ROOT/scripts/cyder_settings_ui.swift")"
library_ui="$(cat "$ROOT/scripts/cyder_game_library_ui.swift")"
library="$(cat "$ROOT/scripts/cyder_game_library.swift")"
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
common="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_not_contains "$ui" "套用所有設定" "advanced tab should not expose legacy apply-all"
assert_not_contains "$ui" "applyAllSettings" "legacy apply-all action should be removed"
assert_contains "$ui" "套用設定" "footer should expose apply while Wine is running"
assert_contains "$ui" "applyRunningSettings" "apply button should have a dedicated action"
assert_contains "$ui" "待套用：同步機制、高解析度、字體設定" \
  "running status should highlight deferred session settings"
assert_not_contains "$ui" "presentRunningWineAlertIfNeeded" \
  "opening preferences should not show a running-Wine alert"
assert_not_contains "$ui" "didShowRunningAlert" \
  "opening preferences should not track a one-time running-Wine alert"
assert_contains "$ui" "wineIsRunning" "prefs should branch idle vs running Wine"
assert_contains "$ui" "onApplyWhileRunning" "prefs should request live apply before saving JSON"
assert_contains "$ui" "persistDeferredSettings" \
  "running preferences should save immediate settings without committing deferred fields"
assert_contains "$ui" "deferredChange" \
  "preferences should distinguish deferred session settings from immediate settings"
assert_contains "$ui" "Winetricks 元件…" "advanced tab should expose the native Winetricks component picker"
assert_contains "$ui" "MapleStory WZ 快取" "advanced tab should expose the MapleStory WZ cache switch"
assert_contains "$ui" "maplestoryWZCacheChanged" "WZ cache switch should save immediately"
assert_contains "$ui" "cyderWinetricksComponentGroups" "Winetricks picker should use a curated component catalog"
assert_not_contains "$ui" 'CyderWinetricksComponent(title: "Steam"' \
  "Steam should not be offered by the built-in Winetricks picker"
assert_not_contains "$ui" 'CyderWinetricksComponent(title: "Visual C++' \
  "VC++ Redistributables should be installed from official installers"
assert_not_contains "$ui" 'CyderWinetricksComponent(title: ".NET Desktop Runtime' \
  ".NET Desktop Runtime should be installed from official installers"
assert_contains "$ui" 'CyderWinetricksComponent(title: ".NET Framework 4.8"' \
  ".NET Framework should remain available through Winetricks"
assert_contains "$ui" 'CyderWinetricksComponent(title: "Visual Basic 6 Runtime"' \
  "VB6 runtime should remain available through Winetricks"
assert_contains "$ui" "onImmediateSave" "controls should expose immediate save"
assert_contains "$ui" "guard saveControls(persistDeferredSettings: !running) else" \
  "control changes should save immediate fields while preserving deferred settings"
assert_contains "$ui" "makeGraphicsTab()" "preferences should provide a graphics tab"
assert_contains "$ui" "圖形轉譯" "graphics tab should expose a backend selector"
assert_contains "$ui" "限制幀率" "graphics tab should expose DXVK frame-rate choices"
assert_contains "$ui" "CyderGptk.scanEvaluationVolumes()" "graphics tab should scan mounted GPTK evaluation volumes"
assert_contains "$ui" "CyderGptk.removeRuntimeInstall()" "graphics tab should remove a locally installed GPTK runtime"
assert_contains "$ui" "需要 macOS 14+" "graphics tab should explain the D3DMetal macOS requirement"
assert_contains "$ui" "canSelectD3DMetal" "D3DMetal should stay disabled without GPTK"
assert_contains "$ui" 'return ["預設", "D3DMetal", "DXMT", "DXVK", "WineD3D"]' \
  "prefs graphics labels include only supported backends"
assert_not_contains "$ui" 'DXVK 2' \
  "prefs should hide the deferred DXVK 2 backend"
assert_not_contains "$ui" '"自動"' "graphics menus must not offer auto"
assert_contains "$ui" "canSelectDxmt" "DXMT should gate on OS + payload"
assert_contains "$ui" "canSelectDxvk" "DXVK should gate on payload availability"
assert_contains "$ui" "updateDxvkMenuItemAvailability" "DXVK menu should expose availability tooltip"
assert_contains "$ui" "supportsD3DMetalOS" \
  "GPTK install controls should be gated on macOS 14+"
assert_contains "$ui" "showGptkControls = supportsD3DMetalOS" \
  "GPTK install UI must stay hidden below macOS 14"
assert_contains "$ui" "CyderGraphicsCapabilities.current(engineRoot: CyderPaths.engine)" \
  "prefs DXMT gating should probe the installed engine"
assert_contains "$library_ui" "CyderGraphicsCapabilities.current(engineRoot: CyderPaths.engine)" \
  "game DXMT gating should probe the installed engine"
assert_contains "$ui" "supportsDxmtOS" "DXMT should have its own OS gate distinct from D3DMetal"
assert_contains "$ui" "ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15" \
  "DXMT OS gate must require macOS 15+, not D3DMetal's 14+"
assert_contains "$ui" "需要 macOS 15+" "DXMT should explain macOS 15+ (higher than D3DMetal's 14+)"
assert_contains "$library_ui" "supportsDxmtOS" "game DXMT gating should have its own OS gate distinct from D3DMetal"
assert_contains "$library_ui" "需要 macOS 15+" "game DXMT gating should explain macOS 15+"
assert_contains "$ui" 'case .dxmt:' "help text must cover DXMT"
assert_contains "$ui" "使用 DXMT 將 Direct3D 直接轉為 Metal；需要 macOS 15+" \
  "DXMT help text must reflect the macOS 15+ requirement"
assert_contains "$ui" "MapleStory 會依 macOS 版本自動選 DXMT 或 DXVK" \
  "default graphics help should explain MapleStory platform selection"
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
assert_contains "$ui" 'row("Windows 語系", wineLocale)' "general settings should expose the Windows locale selector"
assert_contains "$ui" 'CyderWineLocale.menuCases.map' "locale menu should expose 系統/中文/日文/英文"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'case .system: return "系統"' "locale menu should label follow-system as 系統"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'detectedSystemLabel' "系統 should annotate the detected macOS language"
assert_contains "$ui" "系統目前偵測為" "locale help should show the currently detected language"
assert_contains "$ui" "該 bottle 的 wineserver 結束" \
  "locale help must say an already-running wineserver keeps the previous code page"
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
assert_contains "$ui" '["60", "120", "144", "不限制"]' \
  "frame-rate menu should offer 60/120/144 and unlimited"
assert_contains "$ui" 'let showFrameRate = backend.usesFrameLimiter' \
  "frame-rate limiter for DXVK families and DXMT"
assert_contains "$ui" 'labelWithString: "引擎版本"' "general tab should show the installed engine version"
assert_contains "$ui" 'engineVersion.textColor = .secondaryLabelColor' \
  "the engine version value should be gray"
assert_contains "$ui" 'engineVersion.font = .systemFont(ofSize: 11)' \
  "the engine version value should use a smaller compact font"
assert_contains "$ui" 'engineVersion.alignment = .left' \
  "the engine version value should align to the left"
assert_contains "$ui" 'private func engineVersionFooter()' \
  "the engine version should be laid out as a general-tab footer"
assert_contains "$ui" 'stack.spacing = 8' \
  "the engine version footer should use a compact title/value gap"
assert_contains "$ui" 'engineFooterGap.heightAnchor.constraint(equalToConstant: 16)' \
  "the engine version footer should sit below the regular settings rows"
assert_not_contains "$ui" "目前已安裝的 Wine engine；開啟 Cyder.app 時會依打包版本升級。" \
  "general tab should not add explanatory text below the engine version"
assert_contains "$ui" 'let showDxvkFrametimes = backend.usesDxvkTranslation' \
  "frametimes toggle for both DXVK families"
assert_contains "$ui" 'backend.usesDxvkTranslation' \
  "HUD/limiter gating uses usesDxvkTranslation"
assert_contains "$ui" "let enableDxvkFrametimes = graphicsHudValue == .dxvk" "frametimes toggle should only enable for DXVK HUD"
assert_contains "$ui" "dxvkHudFrametimes.isEnabled = enableDxvkFrametimes" "frametimes toggle should disable outside DXVK HUD"
assert_contains "$ui" 'backend != .dxvk && backend != .wined3d && backend != .dxmt' \
  "GPTK controls hide for DXVK/WineD3D/DXMT"
assert_not_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'cascadePreferredBackend' \
  "auto cascade helper must be removed"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'graphicsHud' "settings schema should persist HUD preference"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'dxvkHudFrametimes' "settings schema should persist DXVK frametimes preference"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'wineDiagnostics' "settings schema should persist Wine diagnostics"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'maplestoryWZCache' "settings schema should persist the MapleStory WZ cache preference"
assert_contains "$common" 'CX_GRAPHICS_BACKEND=' "CrossOver OEM needs CX_GRAPHICS_BACKEND"
assert_contains "$common" 'args=(--dll "$dll_overrides" "${args[@]}")' "shell frontend args must prepend --dll overrides"
assert_not_contains "$common" 'd3d11,dxgi=n,b' "prepend graphics must not retain the old native-first DXVK override"
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
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'isSelectableGraphicsBackend' \
  "graphics backend availability should be centralized"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'sanitizeGraphicsPreferences' \
  "stored graphics preferences should reconcile against current capabilities"
assert_contains "$(cat "$ROOT/scripts/cyder_settings.swift")" 'reconcileGraphicsPreferences' \
  "settings store should expose post-ensure graphics reconciliation"
assert_contains "$ui" 'saveImmediately(registrySetting: "dpi", deferredChange: true)' \
  "DPI changes should invoke only the DPI sed path"
assert_contains "$ui" 'saveImmediately(registrySetting: "display", deferredChange: true)' \
  "Retina changes should invoke Retina and linked DPI paths"
assert_contains "$ui" 'saveImmediately(registrySetting: "smoothing", deferredChange: true)' \
  "smoothing changes should invoke the smoothing sed path"
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
assert_contains "$ui" 'saveImmediately(registrySetting: "font-mingliu", deferredChange: true)' \
  "MingLiU popup should fast-apply mingliu family"
assert_contains "$ui" 'saveImmediately(registrySetting: "font-songti", deferredChange: true)' \
  "Songti popup should fast-apply songti family"
assert_contains "$library_ui" '細明體取代' "game settings should label MingLiU replacement"
assert_contains "$library_ui" '宋體取代' "game settings should label Songti replacement"
assert_contains "$library_ui" "private final class CyderGameSettingsWindowController" "game-specific options should open in a dedicated settings window"
assert_not_contains "$library_ui" 'row("同步機制", syncMode)' "game options should not expose synchronization"
assert_not_contains "$library_ui" 'row("能源模式"' "game options should not expose power mode"
assert_contains "$library_ui" '"高解析度"' "game options should expose a high-resolution switch"
assert_contains "$library_ui" "rule.retinaMode = true" "high-resolution on should force Retina"
assert_contains "$library_ui" "rule.dpi = 192" "high-resolution on should force 192 DPI"
assert_not_contains "$library_ui" "private let dpi = NSPopUpButton()" "game options should not expose a DPI control"
assert_contains "$library_ui" 'withTitle: "選項"' "game library context menu should open Options"
assert_not_contains "$library_ui" 'withTitle: "移除"' "game library must not offer remove (shortcuts re-import)"
assert_contains "$library_ui" "顯示於 Finder" "game library should reveal the EXE in Finder"
assert_contains "$library_ui" "revealSelectedGameInFinder" "Finder reveal should have a dedicated action"
assert_contains "$library" "removeMissingExecutables" "library should prune missing EXE paths on refresh"
assert_not_contains "$library_ui" "customizeDisplay" "display override is a direct high-resolution switch"
assert_contains "$library_ui" "customizeFonts" "options should gate font overrides behind a switch"
assert_not_contains "$library_ui" "customizeGraphics" "graphics override is a direct backend selector"
assert_contains "$library_ui" '"啟動選項"' "general options tab should label launch arguments as 啟動選項"
assert_contains "$library_ui" 'title: "\(game.displayName) 的選項"' "options window title should identify the selected game"
if [[ "$ui" == *'NSButton(title: "確認"'* ]]; then
  echo "ASSERT failed: settings UI should not have a confirm button" >&2
  exit 1
fi
assert_not_contains "$app" "onApplyAll" "app delegate should not wire legacy apply-all"
assert_contains "$app" "onApplyWhileRunning" "app delegate should receive running-apply requests"
assert_contains "$app" 'env["CYDER_FORCE_SETTINGS"] = "1"' \
  "running apply should force live Wine registry writes"
assert_contains "$ui" '"CYDER_RETINA_MODE"' \
  "running apply draft should include Retina env before settings.json"
assert_contains "$app" "--install-winetricks" "Winetricks installs should use the unattended launcher path"
assert_contains "$ui" "private func retinaChanged()" "Retina toggle should have a dedicated DPI synchronization handler"
assert_contains "$ui" "let targetDPI = retina.state == .on ? 192 : 96" "global Retina toggle should suggest 192 or 96 DPI"
assert_contains "$library_ui" "private final class CyderGameSettingsWindowController" "game-specific options should open in a dedicated settings window"
assert_contains "$library_ui" 'return ["跟隨全域", "預設", "D3DMetal", "DXMT", "DXVK", "WineD3D"]' \
  "game override menus include only supported backends"
assert_not_contains "$library_ui" 'DXVK 2' \
  "game options should hide the deferred DXVK 2 backend"
assert_not_contains "$library_ui" '"自動"' "game graphics menus must not offer auto"
assert_contains "$library_ui" "canSelectDxvk" "game library DXVK should gate on payload availability"
assert_contains "$library_ui" "updateDxvkMenuItemAvailability" "game library should expose DXVK availability tooltip"
assert_contains "$library_ui" "private var graphicsBackendOverride: CyderGraphicsBackend?" "follow-global backend should use an optional profile override"
assert_not_contains "$library_ui" "private var dxvkFrameRateOverride" "game options should not expose a frame-rate override"
assert_not_contains "$library_ui" "限制幀率" "game options should not expose DXVK frame-rate choices"
assert_not_contains "$library_ui" 'row("同步機制", syncMode)' "game options should not expose synchronization"
assert_not_contains "$library_ui" "updateSyncModeDescription" "game options should not update a sync prompt"
if [[ "$library_ui" == *"顯示 frametimes"* ]]; then
  echo "ASSERT failed: game settings should not expose a frametimes override" >&2
  exit 1
fi
assert_contains "$library_ui" "rule.dpi = 192" "game high-resolution switch should force 192 DPI"
assert_not_contains "$library_ui" "retina.action = #selector(retinaChanged)" "game options should not wire a separate Retina/DPI sync handler"
assert_contains "$ui" "retina.action = #selector(retinaChanged)" "global Retina control should use the synchronization handler"
assert_contains "$library_ui" "選項" "game library should expose Options in the context menu"
assert_contains "$library_ui" "onContextMenu" "game tiles should provide a contextual menu"
assert_contains "$library_ui" "addCyderTitlebarButtons" "game library should place trailing controls in the title bar"
assert_contains "$library_ui" "重新整理遊戲庫" "game library should expose shortcut refresh"
assert_contains "$library_ui" "gearshape" "game library should expose preferences gear"
assert_not_contains "$library_ui" "removeGameFromLibrary" "game library must not keep a remove-from-library action"
assert_contains "$library_ui" "CyderFiveColumnGridLayout" "game library should use five fixed leading-aligned columns"
assert_contains "$library_ui" "nameLabel.maximumNumberOfLines = 2" "game tile titles should wrap to two lines before truncating"
assert_contains "$library_ui" "lineBreakMode = .byCharWrapping" "game tile titles must wrap CJK names that have no spaces"
assert_not_contains "$library_ui" "nameLabel.lineBreakMode = .byTruncatingTail" "truncating-tail on the label would clip the first line instead of wrapping"
assert_contains "$library_ui" "truncatesLastVisibleLine = true" "game tile titles should truncate after the second line"
assert_contains "$library_ui" "preferredMaxLayoutWidth" "multiline NSTextField needs a layout width to wrap"
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
assert_contains "$library_ui" 'title: "\(game.displayName) 的選項"' "game settings title should identify the selected game"
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
  echo "ASSERT failed: game context menu should only contain options and Finder" >&2
  exit 1
fi
assert_contains "$context_block" "選項" "game context menu should expose Options"
assert_contains "$context_block" "顯示於 Finder" "game context menu should expose Reveal in Finder"
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
