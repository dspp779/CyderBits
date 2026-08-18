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
assert_contains "$status_source" 'func isMonitoring(prefix: String) -> Bool' \
  "the app must expose monitored-prefix routing for later Wine activation"
assert_contains "$status_source" 'var onOpenGameLibrary' \
  "the status menu must expose a game-library callback"
assert_contains "$status_source" 'withTitle: "遊戲庫…"' \
  "the status menu must expose the game library"
assert_contains "$status_source" 'func beginLaunch(' \
  "menu-bar lifecycle must consume sentinel launch callbacks"
assert_contains "$status_source" '已結束，等待背景程序退出' \
  "the primary window exit must transition into leftover-process cleanup"
assert_contains "$status_source" 'func adoptWindowedProcess(pid:' \
  "GGM-style handoff must attach the later windowed process to the same launch"
assert_contains "$status_source" 'rootDisplayName' \
  "the launcher EXE name must yield to a later windowed process after it exits"
assert_contains "$app_source" 'statusItemController.adoptWindowedProcess' \
  "Wine activation must attach MapleStory-style handoff PIDs to the monitored launch"
assert_contains "$status_source" '正在啟動' \
  "the menu must distinguish a launch that has not shown a window yet"
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
assert_contains "$status_source" '等待 ' \
  "named leftover processes must appear in the waiting label"
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
assert_contains "$status_source" 'func markLaunchStarted()' \
  "external launches must install the menu-bar item before Wine has a PID"
assert_contains "$app_source" 'presentExternalLaunchStarting()' \
  "URI and Finder EXE launches must show starting UI immediately"
assert_contains "$app_source" 'showSetup("正在啟動程式…")' \
  "program launches must show a starting progress panel"
assert_not_contains "$app_source" 'setActivationPolicy(.regular)' \
  "native Cyder must never promote itself into the Dock"
assert_not_contains "$(cat "$ROOT/scripts/cyder_launch_support.swift")" 'setActivationPolicy(dockVisible ? .regular' \
  "activateCyderUI must not promote Cyder to a Dock app"
assert_contains "$app_source" 'statusItemController.setUIVisible(true)' \
  "opening preferences or the game library must install the menu-bar item"
assert_contains "$app_source" 'statusItemController.setUIVisible(false)' \
  "closing both Cyder windows must release the UI-only menu-bar item"
assert_contains "$app_source" '!self.statusItemController.hasActiveSessions' \
  "successful launches must keep native Cyder alive while Wine is active"
assert_contains "$app_source" 'hasActiveSessions || self.libraryLaunchInProgress' \
  "closing Cyder windows must not drop the menu bar during an in-flight library launch"
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

assert_contains "$app_source" 'attachRootPID(id: launchID' \
  "library and Finder launches must attach the pid file to the LaunchGroup created for that relay"
assert_contains "$status_source" 'func attachRootPID(id: String, pid: Int32)' \
  "status item must expose id-keyed root PID attach"
assert_contains "$status_source" 'cancelOrphanedProcessSources' \
  "endLaunch must cancel process sources for PIDs no remaining group watches"

echo "PASS test-cyder-status-item"
