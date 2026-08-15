#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

status_source="$(cat "$ROOT/scripts/cyder_status_item.swift")"
app_source="$(cat "$ROOT/scripts/cyder_app_main.swift")"
build_source="$(cat "$ROOT/scripts/create-cyder-app.sh")"

assert_contains "$build_source" 'cyder_status_item.swift' \
  "native Cyder build must include menu-bar lifecycle source"
assert_contains "$status_source" 'NSStatusBar.system.statusItem' \
  "active Wine sessions must create a menu-bar item"
assert_contains "$status_source" 'func setUIVisible(_ visible: Bool)' \
  "preferences and game-library windows must keep the menu-bar item visible"
assert_contains "$status_source" 'var onOpenGameLibrary' \
  "the status menu must expose a game-library callback"
assert_contains "$status_source" 'withTitle: "遊戲庫…"' \
  "the status menu must expose the game library"
assert_contains "$status_source" 'lifecycleState(at:' \
  "menu-bar lifecycle must consume the supervisor state contract"
assert_contains "$status_source" 'lifecycleState == "background"' \
  "the primary exit must transition into background cleanup"
assert_contains "$status_source" 'lifecycleState != "stopped"' \
  "the icon must remain until wineserver wait completes"
assert_contains "$status_source" '正在等待背景程序結束' \
  "the menu must distinguish Wine background cleanup"
assert_contains "$status_source" '正在結束 Windows 程序' \
  "the menu must expose an in-progress managed shutdown"
assert_contains "$status_source" '工作管理員…' \
  "the menu must expose Wine task manager"
assert_contains "$status_source" '結束所有 Cyder 程序…' \
  "the menu must expose an explicit whole-environment stop"
assert_contains "$status_source" 'cyderBottleImage(' \
  "the menu bar must use Cyder's bottle silhouette"
assert_not_contains "$status_source" 'windowCount:' \
  "the pure decanter icon must not retain the removed window-pane state"
assert_contains "$status_source" 'liquidLevel:' \
  "managed shutdown must animate the bottle liquid level"
assert_contains "$status_source" 'forcedStopLiquidLevel' \
  "managed shutdown must use the forced-stop liquid drain animation"
assert_contains "$status_source" 'if clampedLiquidLevel >= 0.999' \
  "a full Cyder bottle must fill through the neck and shoulders"
assert_contains "$status_source" 'smooth arced bottom' \
  "the menu-bar decanter must use a smooth arced bottom"
assert_contains "$status_source" 'bottle.curve(to: NSPoint(x: 6.0, y: 1.25)' \
  "the menu-bar decanter must avoid a flat base"
assert_not_contains "$status_source" 'let paneSize' \
  "the menu-bar decanter must not draw Windows panes"
assert_not_contains "$status_source" 'destinationOut' \
  "the menu-bar decanter must not cut Windows panes from the silhouette"
assert_contains "$status_source" 'accessibilityDisplayShouldReduceMotion' \
  "menu-bar animations must respect Reduce Motion"
assert_contains "$status_source" '正在等待背景程序結束 ·' \
  "background cleanup must expose elapsed time"
assert_contains "$status_source" 'quit.isEnabled = !prefixes.isEmpty && !sessions.values.contains' \
  "managed shutdown must reject duplicate stop requests"
assert_not_contains "$status_source" 'gamecontroller.fill' \
  "the menu bar must not use the generic game-controller symbol"
assert_contains "$app_source" '#selector(quitFromMenu), keyEquivalent: ""' \
  "the application quit item must not advertise Command-Q"
assert_contains "$app_source" '"--taskmgr-prefix"' \
  "task manager must be routed to the selected prefix"
assert_contains "$app_source" '"--stop-prefix"' \
  "stop must be routed to the selected prefix"
assert_contains "$app_source" 'statusItemController.markActivated' \
  "the status item must transition out of its launch animation"
assert_contains "$app_source" 'controller.onOpenGameLibrary' \
  "the app delegate must route the status-menu game library action"
assert_contains "$app_source" 'statusItemController.setUIVisible(true)' \
  "opening preferences or the game library must install the menu-bar item"
assert_contains "$app_source" 'statusItemController.setUIVisible(false)' \
  "closing both Cyder windows must release the UI-only menu-bar item"
assert_contains "$app_source" '!self.statusItemController.hasActiveSessions' \
  "successful launches must keep native Cyder alive while Wine is active"
assert_contains "$app_source" 'quitWhenSessionsEnd' \
  "closing native windows must not abandon an active menu-bar session"
assert_contains "$app_source" '#selector(quitFromMenu)' \
  "the application quit command must use the managed Wine shutdown path"
assert_contains "$app_source" 'func applicationShouldTerminate' \
  "Dock and system quit requests must use the managed Wine shutdown path"
assert_contains "$app_source" 'if didRunLauncher {' \
  "a resident Cyder process must accept later Finder EXE requests"

wrapper_source="$(cat "$ROOT/scripts/cyder-macos-wrapper.sh")"
assert_contains "$wrapper_source" 'exec "$SELF/CyderSwift" "$exe" "${game_args[@]}"' \
  "macOS 11 explicit EXE launches must enter the native lifecycle agent"
assert_contains "$wrapper_source" 'Catalina deliberately retains the shell-only fallback' \
  "Catalina must keep the existing Bash-only behavior"

echo "PASS test-cyder-status-item"
