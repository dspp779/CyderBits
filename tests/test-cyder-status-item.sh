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
assert_contains "$status_source" 'cyderBottleImage()' \
  "the menu bar must use Cyder's bottle silhouette"
assert_not_contains "$status_source" 'gamecontroller.fill' \
  "the menu bar must not use the generic game-controller symbol"
assert_contains "$app_source" '#selector(quitFromMenu), keyEquivalent: ""' \
  "the application quit item must not advertise Command-Q"
assert_contains "$app_source" '"--taskmgr-prefix"' \
  "task manager must be routed to the selected prefix"
assert_contains "$app_source" '"--stop-prefix"' \
  "stop must be routed to the selected prefix"
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
